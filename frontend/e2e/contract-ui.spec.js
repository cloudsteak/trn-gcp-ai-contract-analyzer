import { test, expect } from "@playwright/test";
import { choosePdf, openApp, shot } from "./support.js";

function grouped(value) {
  const pattern = String(value).replace(/\B(?=(\d{3})+(?!\d))/g, "[\\s\\u00a0\\u202f]");
  return new RegExp(pattern);
}

test("üres oldalon az elemzés le van tiltva", async ({ page }) => {
  await openApp(page);

  await expect(page.getByText("Húzd ide a PDF-et")).toBeVisible();
  await expect(page.getByText("vagy kattints a fájl kiválasztásához")).toBeVisible();
  await expect(page.getByText("PDF szerződés feltöltése és Gemini-alapú elemzés")).toBeVisible();
  await expect(page.getByRole("button", { name: /Elemzés indítása/ })).toBeDisabled();
  await expect(page.getByRole("checkbox", { name: /Belső szabályzatokkal/ })).toHaveCount(0);
  await expect(page.getByRole("heading", { name: "Összefoglaló" })).toHaveCount(0);

  await shot(page, "01-ures-kepernyo.png");
});

test("a kiválasztott pdf engedélyezi az elemzést", async ({ page }) => {
  await openApp(page);

  await choosePdf(page);

  await expect(page.getByText("Kiválasztva: szerzodes.pdf")).toBeVisible();
  await expect(page.getByRole("button", { name: /Elemzés indítása/ })).toBeEnabled();
  await shot(page, "02-kivalasztott-fajl.png");
});

test("a szöveges fájl nem választható", async ({ page }) => {
  await openApp(page);
  const analyzeRequest = page.waitForRequest(
    (request) => request.method() === "POST" && new URL(request.url()).pathname === "/analyze",
    { timeout: 1500 },
  );

  await page.locator('input[type="file"]').setInputFiles({
    name: "jegyzet.txt",
    mimeType: "text/plain",
    buffer: Buffer.from("nem szerződés"),
  });

  await expect(analyzeRequest).rejects.toThrow();
  await expect(page.getByRole("alert")).toHaveText("Csak PDF fájl tölthető fel.");
  await expect(page.getByText(/Kiválasztva:/)).toHaveCount(0);
  await expect(page.getByRole("button", { name: /Elemzés indítása/ })).toBeDisabled();
});

test("az elemzési hiba megjelenik, eredmény nélkül", async ({ page }) => {
  await openApp(page, { failAnalyze: true });
  await choosePdf(page);

  await page.getByRole("button", { name: /Elemzés indítása/ }).click();

  await expect(page.getByRole("alert")).toHaveText("A szerződés elemzése sikertelen.");
  await expect(page.getByRole("heading", { name: "Összefoglaló" })).toHaveCount(0);
  await expect(page.getByText("Kiválasztva: szerzodes.pdf")).toBeVisible();
  await expect(page.getByRole("button", { name: /Elemzés indítása/ })).toBeEnabled();
});

test("a mockolt eredmény és a folyamatjelző", async ({ page }) => {
  const state = await openApp(page, { holdAnalyze: true });
  await choosePdf(page);

  try {
    await page.getByRole("button", { name: /Elemzés indítása/ }).click();
    await expect(page.getByRole("button", { name: "Elemzés folyamatban..." })).toBeDisabled();
    await expect(page.getByText("A szerződés elemzése folyamatban van, kérjük várj...")).toBeVisible();
    await shot(page, "03-elemzes.png");
  } finally {
    state.releaseAnalyze();
  }

  const quality = page.getByRole("article").filter({
    has: page.getByRole("heading", { name: "Szerződés megfelelősége" }),
  });
  await expect(quality).toContainText("Figyelmet igényel");
  await expect(quality).toContainText("6");
  await expect(quality).toContainText("/ 10");
  await expect(quality).toContainText("60%");
  await expect(quality).toContainText("A fizetési határidő rövid, a kötbér pedig egyoldalú.");

  const usage = page.getByRole("article").filter({
    has: page.getByRole("heading", { name: "Token felhasználás" }),
  });
  await expect(usage).toContainText(grouped(18420));
  await expect(usage).toContainText(grouped(19380));
  await expect(usage.getByText("Gondolkodás")).toBeVisible();

  await expect(page.getByRole("heading", { name: "Összefoglaló" })).toBeVisible();
  await expect(page.getByText("Szolgáltatási szerződés a Minta Kft. és a Vevő Zrt. között, határozott időre.")).toBeVisible();
  await expect(page.getByRole("heading", { name: "Fizetési határidő" })).toBeVisible();
  await expect(page.getByRole("heading", { name: "Felmondás" })).toBeVisible();
  await expect(page.getByText("Késedelem esetén a kötbér a szerződéses díj 20%-a.")).toBeVisible();
  await expect(page.getByRole("heading", { name: "Belső szabályzatokkal való összevetés" })).toHaveCount(0);
  expect(state.fileName).toBe("szerzodes.pdf");
  expect(state.useRag).toBe(false);
  await shot(page, "04-eredmenyek.png");
});

test("a rag összevetés a szabályzatokat mutatja", async ({ page }) => {
  const state = await openApp(page, { ragAvailable: true });
  const rag = page.getByRole("checkbox", { name: "Belső szabályzatokkal összevetés (RAG)" });
  await expect(rag).toBeVisible();
  await rag.check();

  await choosePdf(page);
  await page.getByRole("button", { name: /Elemzés indítása/ }).click();

  await expect(page.getByRole("heading", { name: "Belső szabályzatokkal való összevetés" })).toBeVisible();
  await expect(page.getByRole("heading", { name: "Fizetési feltételek" })).toBeVisible();
  await expect(page.getByText("Sértés")).toBeVisible();
  await expect(page.getByText("A belső szabályzat legalább 15 napos fizetési határidőt ír elő.")).toBeVisible();
  await expect(page.getByRole("heading", { name: "Adatvédelem" })).toBeVisible();
  await expect(page.getByText("Megfelel", { exact: true })).toBeVisible();
  expect(state.useRag).toBe(true);
  await shot(page, "05-szabalyzat.png");
});

test("az API panel a böngésző, a backend és a modell hívást mutatja", async ({ page }) => {
  await openApp(page);

  await page.getByRole("button", { name: /API hívások/ }).click();
  await expect(page.getByRole("complementary", { name: "API hívások" })).toBeVisible();
  await expect(page.getByText("GET /rag/status")).toHaveCount(2);
  await expect(page.getByRole("button", { name: /API hívások/ })).toContainText("2");

  await choosePdf(page);
  await page.getByRole("button", { name: /Elemzés indítása/ }).click();
  await expect(page.getByRole("heading", { name: "Összefoglaló" })).toBeVisible();
  await expect(page.getByText("POST /analyze")).toHaveCount(2);
  await expect(page.getByText("Gemini · generateContent")).toBeVisible();
  await expect(page.getByRole("button", { name: /API hívások/ })).toContainText("5");

  const analyzeCall = page.getByRole("article").filter({ hasText: "POST /analyze" }).filter({ hasText: "kérés" });
  await analyzeCall.getByRole("button", { name: "JSON lenyitása" }).click();
  await expect(analyzeCall.getByText("Kérés", { exact: true })).toBeVisible();
  await expect(analyzeCall.getByText('"file_name": "szerzodes.pdf"')).toBeVisible();
  await shot(page, "06-api-hivasok.png");

  await page.getByRole("tab", { name: /^AI model/ }).click();
  await expect(page.getByText("Gemini · generateContent")).toBeVisible();
  await expect(page.getByText("GET /rag/status")).toHaveCount(0);
  await expect(page.getByText("POST /analyze")).toHaveCount(0);

  await page.getByRole("tab", { name: /^RAG/ }).click();
  await expect(page.getByText(/Még nincs rögzített hívás/)).toBeVisible();

  await page.getByRole("tab", { name: /^BE/ }).click();
  await expect(page.getByText("POST /analyze")).toBeVisible();
  await expect(page.getByText("200").first()).toBeVisible();
});
