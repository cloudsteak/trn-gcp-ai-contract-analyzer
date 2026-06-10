import json
import logging
import os
from contextlib import asynccontextmanager
from typing import Literal

from dotenv import load_dotenv
from fastapi import FastAPI, File, HTTPException, UploadFile
from fastapi.middleware.cors import CORSMiddleware
from google import genai
from google.genai import types
from pydantic import BaseModel, Field

load_dotenv()

logger = logging.getLogger(__name__)

GEMINI_MODEL = os.getenv("GEMINI_MODEL", "gemini-3.1-flash-lite")
GCP_PROJECT_ID = os.getenv("GCP_PROJECT_ID", "")
GEMINI_LOCATION = os.getenv("GEMINI_LOCATION", "global")
CORS_ORIGINS = os.getenv("CORS_ORIGINS", "*")
PORT = int(os.getenv("PORT", "8080"))

ANALYSIS_PROMPT = (
    "Elemezd a csatolt szerződés PDF-et, és adj vissza egy JSON objektumot "
    "pontosan az alábbi mezőkkel:\n\n"
    '- "summary": a teljes szerződés rövid összefoglalója (maximum 5 mondat)\n'
    '- "key_clauses": objektumok listája, mindegyik "title" (cím) és '
    '"description" (rövid leírás) mezőkkel\n'
    '- "risk_flags": objektumok listája, mindegyik "quote" (pontos idézet '
    'a szerződésből) és "explanation" (magyarázat) mezőkkel\n'
    '- "contract_quality": objektum a szerződés általános megfelelőségére:\n'
    '  - "score": egész szám 1 és 10 között (10 = kiegyensúlyozott, korrekt, '
    "átlátható; 1 = súlyosan kockázatos vagy hiányos)\n"
    '  - "level": "green" (7-10), "yellow" (4-6) vagy "red" (1-3)\n'
    '  - "label": rövid magyar minősítés (pl. "Korrekt", "Figyelmet igényel", '
    '"Kockázatos")\n'
    '  - "explanation": 1-2 mondatos indoklás magyarul\n\n'
    "Csak érvényes JSON-t adj vissza. Minden szöveges tartalom legyen magyar nyelvű. "
    "Az idézetek maradhatnak az eredeti szerződés szövegében."
)

genai_client: genai.Client | None = None  # Gemini kliens eletciklus alatt inicializalva


class KeyClause(BaseModel):
    title: str
    description: str


class RiskFlag(BaseModel):
    quote: str
    explanation: str


class ContractQuality(BaseModel):
    score: int = Field(..., ge=1, le=10)
    level: Literal["green", "yellow", "red"]
    label: str = Field(..., max_length=100)
    explanation: str = Field(..., max_length=1000)


class AnalysisResult(BaseModel):
    contract_quality: ContractQuality
    summary: str = Field(..., max_length=4000)
    key_clauses: list[KeyClause]
    risk_flags: list[RiskFlag]


class TokenUsage(BaseModel):
    prompt_tokens: int = 0
    response_tokens: int = 0
    total_tokens: int = 0
    cached_tokens: int | None = None
    thoughts_tokens: int | None = None


class AnalyzeResponse(AnalysisResult):
    token_usage: TokenUsage


def _parse_cors_origins(raw: str) -> list[str]:
    if raw.strip() == "*":
        return ["*"]
    return [origin.strip() for origin in raw.split(",") if origin.strip()]


def _build_genai_client() -> genai.Client:
    # Gemini Enterprise Agent Platform kliens ADC-vel (vertexai=True SDK parameter)
    if not GCP_PROJECT_ID:
        raise RuntimeError("A GCP_PROJECT_ID környezeti változó kötelező")

    # gemini-3.1-flash-lite global endpointot hasznal, nem regionalist
    return genai.Client(
        vertexai=True,
        project=GCP_PROJECT_ID,
        location=GEMINI_LOCATION,
    )


def _parse_analysis_response(raw_text: str) -> AnalysisResult:
    try:
        payload = json.loads(raw_text)
    except json.JSONDecodeError as exc:
        raise ValueError("A Gemini válasz nem érvényes JSON") from exc

    return AnalysisResult.model_validate(payload)


def _extract_token_usage(response: types.GenerateContentResponse) -> TokenUsage:
    usage = response.usage_metadata
    if usage is None:
        return TokenUsage()

    # Az SDK candidates_token_count mezot ad vissza, nem response_token_count-et
    response_tokens = getattr(usage, "candidates_token_count", None) or getattr(
        usage, "response_token_count", None
    ) or 0

    return TokenUsage(
        prompt_tokens=usage.prompt_token_count or 0,
        response_tokens=response_tokens,
        total_tokens=usage.total_token_count or 0,
        cached_tokens=usage.cached_content_token_count,
        thoughts_tokens=usage.thoughts_token_count,
    )


def _get_genai_client() -> genai.Client:
    global genai_client
    if genai_client is None:
        genai_client = _build_genai_client()
    return genai_client


async def _analyze_pdf(pdf_bytes: bytes) -> AnalyzeResponse:
    # A PDF-et nativan adjuk at a Gemini API-nak, szoveg konverzio nelkul
    client = _get_genai_client()

    response = client.models.generate_content(
        model=GEMINI_MODEL,
        contents=[
            types.Part.from_bytes(data=pdf_bytes, mime_type="application/pdf"),
            ANALYSIS_PROMPT,
        ],
        config=types.GenerateContentConfig(
            response_mime_type="application/json",
            temperature=0.2,
        ),
    )

    if not response.text:
        raise ValueError("A Gemini üres választ adott vissza")

    analysis = _parse_analysis_response(response.text)
    return AnalyzeResponse(
        **analysis.model_dump(),
        token_usage=_extract_token_usage(response),
    )


@asynccontextmanager
async def lifespan(_: FastAPI):
    yield


app = FastAPI(title="Szerzodeselemzo API", lifespan=lifespan)

app.add_middleware(
    CORSMiddleware,
    allow_origins=_parse_cors_origins(CORS_ORIGINS),
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)


@app.get("/health")
async def health() -> dict[str, str]:
    return {"status": "rendben"}


@app.post("/analyze", response_model=AnalyzeResponse)
async def analyze(file: UploadFile = File(...)) -> AnalyzeResponse:
    if file.content_type not in ("application/pdf", "application/x-pdf"):
        raise HTTPException(status_code=400, detail="Csak PDF fájl támogatott")

    pdf_bytes = await file.read()
    if not pdf_bytes:
        raise HTTPException(status_code=400, detail="A feltöltött fájl üres")

    max_pdf_size = 50 * 1024 * 1024  # Gemini inline PDF limit
    if len(pdf_bytes) > max_pdf_size:
        raise HTTPException(status_code=400, detail="A PDF fájl meghaladja az 50 MB-os limitet")

    try:
        return await _analyze_pdf(pdf_bytes)
    except RuntimeError as exc:
        raise HTTPException(status_code=503, detail=str(exc)) from exc
    except ValueError as exc:
        logger.exception("Failed to parse Gemini response")
        raise HTTPException(status_code=502, detail=str(exc)) from exc
    except Exception as exc:
        logger.exception("Contract analysis failed")
        raise HTTPException(status_code=500, detail="A szerződés elemzése sikertelen") from exc


if __name__ == "__main__":
    import uvicorn

    uvicorn.run("main:app", host="0.0.0.0", port=PORT, reload=False)
