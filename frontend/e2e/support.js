// Közös mock és képernyőkép a UI tesztekhez. A Gemini és a RAG végpontokat nem hívjuk.
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { expect } from "@playwright/test";

const here = path.dirname(fileURLToPath(import.meta.url));
const shotDir = path.resolve(here, "../test-results/screenshots");

const PDF_BYTES = Buffer.from(
  "%PDF-1.1\n1 0 obj<</Type/Catalog/Pages 2 0 R>>endobj\ntrailer<</Root 1 0 R>>\n%%EOF\n",
);

const ANALYSIS = {
  contract_quality: {
    score: 6,
    level: "yellow",
    label: "Figyelmet igényel",
    explanation: "A fizetési határidő rövid, a kötbér pedig egyoldalú.",
  },
  summary: "Szolgáltatási szerződés a Minta Kft. és a Vevő Zrt. között, határozott időre.",
  key_clauses: [
    {
      title: "Fizetési határidő",
      description: "A számla kézhezvételétől számított 8 nap.",
    },
    {
      title: "Felmondás",
      description: "A megrendelő 30 napos felmondási idővel élhet.",
    },
  ],
  risk_flags: [
    {
      quote: "Késedelem esetén a kötbér a szerződéses díj 20%-a.",
      explanation: "A kötbér mértéke aránytalanul magas.",
    },
  ],
  token_usage: {
    prompt_tokens: 18420,
    response_tokens: 960,
    total_tokens: 19380,
    cached_tokens: 0,
    thoughts_tokens: 120,
  },
};

const POLICY_FINDINGS = [
  {
    policy: "Fizetési feltételek",
    status: "violation",
    quote: "A számla kézhezvételétől számított 8 nap.",
    explanation: "A belső szabályzat legalább 15 napos fizetési határidőt ír elő.",
  },
  {
    policy: "Adatvédelem",
    status: "compliant",
    quote: "",
    explanation: "A szerződés nem tér el az adatkezelési szabályzattól.",
  },
];

export function samplePdf(name = "szerzodes.pdf") {
  return {
    name,
    mimeType: "application/pdf",
    buffer: PDF_BYTES,
  };
}

export async function choosePdf(page, name = "szerzodes.pdf") {
  await page.locator('input[type="file"]').setInputFiles(samplePdf(name));
}

export async function shot(page, name) {
  fs.mkdirSync(shotDir, { recursive: true });
  // A ragadós panel a teljes oldalas képen levágná a lenyitott hívást.
  await page.addStyleTag({
    content: [
      ".trace-panel, .trace-list {",
      "  position: static !important;",
      "  max-height: none !important;",
      "  overflow: visible !important;",
      "}",
    ].join("\n"),
  });
  await page.screenshot({
    path: path.join(shotDir, name),
    fullPage: true,
  });
}

function readForm(request) {
  const contentType = request.headers()["content-type"] || "";
  const boundaryMatch = contentType.match(/boundary=(?:"([^"]+)"|([^;]+))/i);
  if (!boundaryMatch) {
    throw new Error("A feltöltés nem multipart");
  }
  const boundary = boundaryMatch[1] || boundaryMatch[2];
  const raw = request.postDataBuffer().toString("latin1");
  const fields = {};
  let fileName = null;
  for (const part of raw.split(`--${boundary}`)) {
    const headerEnd = part.indexOf("\r\n\r\n");
    if (headerEnd === -1) continue;
    const header = part.slice(0, headerEnd);
    const nameMatch = header.match(/name="([^"]+)"/);
    if (!nameMatch) continue;
    const encoded = header.match(/filename\*=UTF-8''([^\r\n;]+)/i);
    const plain = header.match(/filename="([^"]*)"/);
    if (encoded || plain) {
      fileName = encoded ? decodeURIComponent(encoded[1]) : plain[1];
      continue;
    }
    fields[nameMatch[1]] = part.slice(headerEnd + 4).replace(/\r\n$/, "");
  }
  if (!fileName) throw new Error("A feltöltésben nincs fájlnév");
  return { fileName, fields };
}

function analysisBody(useRag) {
  const at = new Date().toISOString();
  const apiCalls = [];
  if (useRag) {
    apiCalls.push({
      layer: "rag",
      service: "RAG",
      operation: "retrieve",
      status: "ok",
      duration_ms: 15,
      occurred_at: at,
      request: {
        method: "POST",
        endpoint: "https://europe-west4-aiplatform.googleapis.com/v1/projects/demo/locations/europe-west4:retrieveContexts",
      },
      response: { chunk_count: 2 },
      error: null,
    });
  }
  apiCalls.push({
    layer: "ai",
    service: "Gemini",
    operation: "generateContent",
    status: "ok",
    duration_ms: 840,
    occurred_at: at,
    request: { method: "POST", endpoint: "generateContent", model: "gemini-3.5-flash" },
    response: { finish_reason: "STOP" },
    error: null,
  });
  return {
    ...structuredClone(ANALYSIS),
    rag_used: useRag,
    policy_findings: useRag ? structuredClone(POLICY_FINDINGS) : [],
    api_calls: apiCalls,
  };
}

export async function openApp(page, options = {}) {
  const state = {
    fileName: null,
    useRag: null,
    releaseAnalyze() {},
  };
  let release = () => {};
  const gate = new Promise((resolve) => {
    release = resolve;
  });
  state.releaseAnalyze = release;
  let analyzeHeld = false;

  await page.route(
    (url) => url.pathname === "/rag/status" || url.pathname === "/analyze",
    async (route) => {
      const request = route.request();
      const { pathname } = new URL(request.url());
      const method = request.method();

      if (method === "OPTIONS") {
        await route.fulfill({ status: 204, body: "" });
        return;
      }

      if (method === "GET" && pathname === "/rag/status") {
        const available = Boolean(options.ragAvailable);
        await route.fulfill({
          json: {
            enabled: available,
            available,
            policy_count: available ? 2 : 0,
            policy_names: available ? ["fizetesi-feltetelek.md", "adatvedelem.md"] : [],
          },
        });
        return;
      }

      if (method === "POST" && pathname === "/analyze") {
        const form = readForm(request);
        state.fileName = form.fileName;
        state.useRag = form.fields.use_rag === "true";
        if (options.failAnalyze) {
          await route.fulfill({
            status: 500,
            json: { detail: "A szerződés elemzése sikertelen." },
          });
          return;
        }
        if (options.holdAnalyze && !analyzeHeld) {
          analyzeHeld = true;
          await gate;
        }
        await route.fulfill({ json: analysisBody(state.useRag) });
        return;
      }

      const message = `Váratlan API hívás: ${method} ${pathname}`;
      await route.fulfill({ status: 500, contentType: "text/plain", body: message });
      throw new Error(message);
    },
  );

  const status = page.waitForResponse((response) => new URL(response.url()).pathname === "/rag/status");
  await page.goto("/");
  await status;
  await expect(page.getByRole("heading", { level: 1, name: "Szerződéselemző" })).toBeVisible();
  return state;
}
