// CSAK AZ API-NÉZET MIATT – ez az egész fájl.
// Memóriában tartja a négy réteget: FE, BE, RAG, AI model.
// A szerződés elemzésének eredményét nem módosítja.
const listeners = new Set();

let calls = [];
let seq = 0;

function emit() {
  listeners.forEach((listener) => listener());
}

function isRepeatPoll(previous, next) {
  return Boolean(
    previous
    && next
    && previous.layer === next.layer
    && (previous.layer === "fe" || previous.layer === "be")
    && previous.method === "GET"
    && next.method === "GET"
    && previous.path === next.path
    && previous.pollStatus === "processing"
    && next.pollStatus === "processing"
  );
}

function lastOfLayer(layer) {
  for (let i = calls.length - 1; i >= 0; i -= 1) {
    if (calls[i].layer === layer) return i;
  }
  return -1;
}

export function getCalls() {
  return [...calls].sort((a, b) => {
    if (a.at === b.at) return a.seq - b.seq;
    return a.at < b.at ? -1 : 1;
  });
}

export function subscribeCallLog(listener) {
  listeners.add(listener);
  return () => listeners.delete(listener);
}

export function clearCallLog() {
  calls = [];
  emit();
}

export function logCall(entry) {
  const matchIndex = lastOfLayer(entry.layer);
  const previous = matchIndex >= 0 ? calls[matchIndex] : null;
  if (previous && isRepeatPoll(previous, entry)) {
    const updated = [...calls];
    updated[matchIndex] = {
      ...previous,
      pollCount: (previous.pollCount || 1) + 1,
      durationMs: entry.durationMs ?? previous.durationMs,
      requestBody: entry.requestBody ?? previous.requestBody,
      responseBody: entry.responseBody ?? previous.responseBody,
      httpStatus: entry.httpStatus ?? previous.httpStatus,
      status: entry.status,
      error: entry.error,
      pollStatus: entry.pollStatus,
    };
    calls = updated;
  } else {
    calls = [...calls, { pollCount: 1, ...entry, seq: ++seq }];
  }
  emit();
}

function layerOfBackendCall(call) {
  if (call.layer === "rag" || call.layer === "ai") return call.layer;
  return /rag/i.test(call.service || "") ? "rag" : "ai";
}

/**
 * Az elemzés eredményében érkező RAG és AI model hívások beillesztése.
 * Az időbélyeg a szerveré, így a böngésző kérése és a backend válasza közé rendeződnek.
 */
export function logBackendAiCalls(fileName, apiCalls) {
  if (!apiCalls?.length) return;
  apiCalls.forEach((call) => {
    const layer = layerOfBackendCall(call);
    logCall({
      id: crypto.randomUUID(),
      at: call.occurred_at || new Date().toISOString(),
      layer,
      service: call.service,
      operation: call.operation,
      method: call.request?.method || "POST",
      path: call.request?.endpoint || call.operation,
      status: call.status === "ok" ? "ok" : "error",
      httpStatus: null,
      durationMs: call.duration_ms ?? null,
      requestBody: call.request || null,
      responseBody: call.response || null,
      error: call.error || null,
      fileName: fileName || call.request?.file_name || null,
    });
  });
}
