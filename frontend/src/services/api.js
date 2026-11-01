// Backend API hívások
// CSAK AZ API-NÉZET MIATT – a lenti naplózás az oktatási panelt táplálja.
// A kérést nem írja át, a szerver válaszát a hívó ugyanúgy kapja meg.
import { logBackendAiCalls, logCall } from "./callLog.js";

const API_URL = import.meta.env.VITE_API_URL || "http://localhost:8080";

function requestPath(url) {
  try {
    const parsed = new URL(url, window.location.origin);
    return parsed.pathname + parsed.search;
  } catch {
    return url;
  }
}

function clipValue(value, depth = 0) {
  if (typeof value === "string") {
    if (value.length <= 4000) return value;
    return `${value.slice(0, 4000)}\n… (${value.length} karakterből az első 4000 látható)`;
  }
  if (typeof Blob !== "undefined" && value instanceof Blob) {
    return {
      blob: true,
      size: value.size,
      type: value.type || "application/octet-stream",
    };
  }
  if (depth > 6) return "…";
  if (Array.isArray(value)) {
    const sliced = value.slice(0, 20).map((item) => clipValue(item, depth + 1));
    if (value.length > 20) sliced.push(`… +${value.length - 20} elem`);
    return sliced;
  }
  if (value && typeof value === "object") {
    const copy = {};
    Object.entries(value).forEach(([key, item]) => {
      copy[key] = clipValue(item, depth + 1);
    });
    return copy;
  }
  return value ?? null;
}

function describeRequestBody(data) {
  if (data == null || data === "") return null;
  if (typeof FormData !== "undefined" && data instanceof FormData) {
    const parts = [];
    data.forEach((value, field) => {
      if (typeof File !== "undefined" && value instanceof File) {
        parts.push({
          field,
          file_name: value.name,
          mime_type: value.type,
          size_bytes: value.size,
        });
      } else {
        parts.push({ field, value: clipValue(String(value)) });
      }
    });
    return { multipart: parts };
  }
  return clipValue(data);
}

function fileNameFromBody(data) {
  if (typeof FormData === "undefined" || !(data instanceof FormData)) return null;
  let fileName = null;
  data.forEach((value) => {
    if (!fileName && typeof File !== "undefined" && value instanceof File) {
      fileName = value.name;
    }
  });
  return fileName;
}

function stripAiTraces(data) {
  if (!data || typeof data !== "object" || (typeof Blob !== "undefined" && data instanceof Blob)) {
    return data;
  }
  if (Array.isArray(data)) return data.map(stripAiTraces);
  const copy = { ...data };
  if ("api_calls" in copy) {
    const count = Array.isArray(copy.api_calls) ? copy.api_calls.length : 0;
    delete copy.api_calls;
    copy.api_calls = `(${count} hívás a RAG és az AI model listában)`;
  }
  if (copy.detail && typeof copy.detail === "object") {
    copy.detail = stripAiTraces(copy.detail);
  }
  return copy;
}

function errorMessage(error) {
  if (!error) return null;
  return error.message || "Hálózati hiba";
}

function detailMessage(payload) {
  if (typeof payload?.detail === "string") return payload.detail;
  if (typeof payload?.detail?.message === "string") return payload.detail.message;
  return "Az elemzés kérése sikertelen.";
}

function apiCallsFrom(payload) {
  if (Array.isArray(payload?.api_calls)) return payload.api_calls;
  if (Array.isArray(payload?.detail?.api_calls)) return payload.detail.api_calls;
  return [];
}

function logFromFetch({ method, path, startedAt, startedIso, requestBody, fileName, response, rawBody, error }) {
  const durationMs = Math.max(0, Math.round(performance.now() - startedAt));
  const httpStatus = response?.status ?? 0;
  const responseBody = rawBody === undefined
    ? (error ? { error: errorMessage(error) } : null)
    : clipValue(stripAiTraces(rawBody));
  const operation = `${method} ${path}`;
  const beOk = httpStatus >= 200 && httpStatus < 400;

  logCall({
    id: crypto.randomUUID(),
    at: startedIso,
    layer: "fe",
    service: "Frontend",
    operation,
    method,
    path,
    status: "ok",
    httpStatus: null,
    durationMs: null,
    requestBody,
    responseBody: null,
    error: null,
    fileName,
    pollStatus: null,
  });

  logCall({
    id: crypto.randomUUID(),
    at: new Date().toISOString(),
    layer: "be",
    service: "Backend",
    operation,
    method,
    path,
    status: beOk ? "ok" : "error",
    httpStatus: httpStatus || null,
    durationMs,
    requestBody: null,
    responseBody,
    error: errorMessage(error),
    fileName,
    pollStatus: null,
  });
}

async function loggedFetch(url, options = {}) {
  const startedAt = performance.now();
  const startedIso = new Date().toISOString();
  const method = (options.method || "GET").toUpperCase();
  const path = requestPath(url);
  const requestBody = describeRequestBody(options.body);
  const fileName = fileNameFromBody(options.body);

  try {
    const response = await fetch(url, options);
    const cloned = response.clone();
    let rawBody;
    const contentType = response.headers.get("content-type") || "";
    if (contentType.includes("application/json")) {
      rawBody = await cloned.json().catch(() => null);
    } else {
      const text = await cloned.text().catch(() => "");
      rawBody = text || null;
    }
    logFromFetch({
      method,
      path,
      startedAt,
      startedIso,
      requestBody,
      fileName,
      response,
      rawBody,
      error: null,
    });
    return { response, payload: rawBody };
  } catch (error) {
    logFromFetch({
      method,
      path,
      startedAt,
      startedIso,
      requestBody,
      fileName,
      response: null,
      rawBody: undefined,
      error,
    });
    throw error;
  }
}

export async function getRagStatus() {
  const { response, payload } = await loggedFetch(`${API_URL}/rag/status`);
  if (!response.ok || !payload || typeof payload !== "object") return null;
  return payload;
}

export async function analyzeContract(file, useRag) {
  const formData = new FormData();
  formData.append("file", file);
  formData.append("use_rag", useRag ? "true" : "false");

  const { response, payload } = await loggedFetch(`${API_URL}/analyze`, {
    method: "POST",
    body: formData,
  });
  const body = payload && typeof payload === "object" ? payload : {};
  logBackendAiCalls(file.name, apiCallsFrom(body));

  if (!response.ok) {
    throw new Error(detailMessage(body));
  }

  const analysis = { ...body };
  delete analysis.api_calls;
  return analysis;
}
