import json
import logging
import os
import time
from contextlib import asynccontextmanager
from typing import Any, Literal

from dotenv import load_dotenv
from fastapi import FastAPI, File, Form, HTTPException, UploadFile
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import JSONResponse
from google import genai
from google.genai import types
from pydantic import BaseModel, Field

from api_trace import (
    ApiCallTrace,
    begin_api_traces,
    clip_text,
    record_api_call,
    reset_api_traces,
    snapshot_api_traces,
)
from rag import build_policy_retrieval, build_rag_prompt, get_rag_status, is_rag_available

load_dotenv()

logger = logging.getLogger(__name__)

GEMINI_MODEL = os.getenv("GEMINI_MODEL", "gemini-3.5-flash")
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


class PolicyFinding(BaseModel):
    policy: str
    status: Literal["compliant", "warning", "violation"]
    quote: str = Field(default="", max_length=4000)
    explanation: str = Field(..., max_length=2000)


class AnalyzeResponse(AnalysisResult):
    token_usage: TokenUsage
    rag_used: bool = False
    policy_findings: list[PolicyFinding] | None = None
    api_calls: list[ApiCallTrace] = []  # CSAK AZ API-NÉZET MIATT


def _parse_cors_origins(raw: str) -> list[str]:
    if raw.strip() == "*":
        return ["*"]
    return [origin.strip() for origin in raw.split(",") if origin.strip()]


def _build_genai_client() -> genai.Client:
    # Gemini Enterprise Agent Platform kliens ADC-vel (vertexai=True SDK parameter)
    if not GCP_PROJECT_ID:
        raise RuntimeError("A GCP_PROJECT_ID környezeti változó kötelező")

    # gemini-3.5-flash hivas a global endpointon megy, nem a Cloud Run regioban
    return genai.Client(
        vertexai=True,
        project=GCP_PROJECT_ID,
        location=GEMINI_LOCATION,
    )


class RagAnalysisPayload(AnalysisResult):
    policy_findings: list[PolicyFinding] = Field(default_factory=list)


def _parse_analysis_response(
    raw_text: str,
    *,
    include_policy_findings: bool,
) -> tuple[AnalysisResult, list[PolicyFinding] | None]:
    try:
        payload = json.loads(raw_text)
    except json.JSONDecodeError as exc:
        raise ValueError("A Gemini válasz nem érvényes JSON") from exc

    if include_policy_findings:
        rag_result = RagAnalysisPayload.model_validate(payload)
        return rag_result, rag_result.policy_findings

    return AnalysisResult.model_validate(payload), None


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


def _elapsed_ms(started: float) -> int:
    return max(0, int((time.perf_counter() - started) * 1000))


# --- CSAK AZ API-NÉZET MIATT ---
# A generateContent es a RAG visszakereses olvashato masolata. A hivast nem modositja.
def _gemini_endpoint() -> str:
    host = (
        "aiplatform.googleapis.com"
        if GEMINI_LOCATION == "global"
        else f"{GEMINI_LOCATION}-aiplatform.googleapis.com"
    )
    return (
        f"https://{host}/v1/projects/{GCP_PROJECT_ID}/locations/{GEMINI_LOCATION}"
        f"/publishers/google/models/{GEMINI_MODEL}:generateContent"
    )


def _gemini_request(
    prompt: str,
    pdf_bytes: bytes,
    *,
    file_name: str,
    rag_active: bool,
) -> dict[str, Any]:
    return {
        "method": "POST",
        "endpoint": _gemini_endpoint(),
        "model": GEMINI_MODEL,
        "file_name": file_name,
        "rag_used": rag_active,
        "prompt_chars": len(prompt),
        "config": {
            "response_mime_type": "application/json",
            "temperature": 0.2,
        },
        "contents": [
            {
                "type": "inline_data",
                "mime_type": "application/pdf",
                "file_name": file_name,
                "size_bytes": len(pdf_bytes),
            },
            {"type": "text", "text": clip_text(prompt, 6000)},
        ],
    }


def _response_body_from_text(response_text: str) -> dict[str, Any]:
    try:
        return {"body": json.loads(response_text)}
    except json.JSONDecodeError:
        return {"body": clip_text(response_text, 8000)}


def _gemini_response_body(
    response_text: str,
    response: types.GenerateContentResponse,
) -> dict[str, Any]:
    body = _response_body_from_text(response_text)
    body["token_usage"] = _extract_token_usage(response).model_dump()
    return body


def _trace_error(status_code: int, message: str) -> JSONResponse:
    """Hiba válasz, a már rögzített RAG és Gemini hívásokkal."""
    return JSONResponse(
        status_code=status_code,
        content={
            "detail": message,
            "api_calls": [trace.model_dump() for trace in snapshot_api_traces()],
        },
    )


# --- API-NÉZET VÉGE ---


def _retrieve_policy_prompt(file_name: str) -> str:
    started = time.perf_counter()
    retrieval = build_policy_retrieval()
    request = {**retrieval.request, "file_name": file_name}
    if not retrieval.context:
        record_api_call(
            service="RAG",
            operation="retrievePolicies",
            status="error",
            duration_ms=_elapsed_ms(started),
            request=request,
            response=retrieval.response,
            error="Nincs elérhető belső szabályzat a RAG elemzéshez",
        )
        raise ValueError("Nincs elerheto belso szabalyzat a RAG elemzeshez")

    record_api_call(
        service="RAG",
        operation="retrievePolicies",
        status="ok",
        duration_ms=_elapsed_ms(started),
        request=request,
        response=retrieval.response,
    )
    return build_rag_prompt(ANALYSIS_PROMPT, retrieval.context)


def _generate_analysis(
    pdf_bytes: bytes,
    prompt: str,
    *,
    file_name: str,
    rag_active: bool,
) -> AnalyzeResponse:
    request = _gemini_request(prompt, pdf_bytes, file_name=file_name, rag_active=rag_active)
    started = time.perf_counter()
    try:
        client = _get_genai_client()
        response = client.models.generate_content(
            model=GEMINI_MODEL,
            contents=[
                types.Part.from_bytes(data=pdf_bytes, mime_type="application/pdf"),
                prompt,
            ],
            config=types.GenerateContentConfig(
                response_mime_type="application/json",
                temperature=0.2,
            ),
        )
    except Exception as exc:
        record_api_call(
            service="Gemini",
            operation="generateContent",
            status="error",
            duration_ms=_elapsed_ms(started),
            request=request,
            error=str(exc),
        )
        raise

    response_text = response.text or ""
    duration_ms = _elapsed_ms(started)
    if not response_text:
        record_api_call(
            service="Gemini",
            operation="generateContent",
            status="error",
            duration_ms=duration_ms,
            request=request,
            error="A Gemini üres választ adott vissza",
        )
        raise ValueError("A Gemini üres választ adott vissza")

    try:
        analysis, policy_findings = _parse_analysis_response(
            response_text,
            include_policy_findings=rag_active,
        )
    except ValueError as exc:
        record_api_call(
            service="Gemini",
            operation="generateContent",
            status="error",
            duration_ms=duration_ms,
            request=request,
            response=_response_body_from_text(response_text),
            error=str(exc),
        )
        raise

    record_api_call(
        service="Gemini",
        operation="generateContent",
        status="ok",
        duration_ms=duration_ms,
        request=request,
        response=_gemini_response_body(response_text, response),
    )
    # RagAnalysisPayload tartalmaz policy_findings mezot is, duplikalt kwargs elkerulese
    return AnalyzeResponse(
        **analysis.model_dump(exclude={"policy_findings"}),
        token_usage=_extract_token_usage(response),
        rag_used=rag_active,
        policy_findings=policy_findings,
        api_calls=snapshot_api_traces(),
    )


async def _analyze_pdf(
    pdf_bytes: bytes,
    *,
    use_rag: bool = False,
    file_name: str = "",
) -> AnalyzeResponse:
    # A PDF-et nativan adjuk at a Gemini API-nak, szoveg konverzio nelkul
    prompt = ANALYSIS_PROMPT
    rag_active = use_rag and is_rag_available()

    if rag_active:
        prompt = _retrieve_policy_prompt(file_name)

    return _generate_analysis(
        pdf_bytes,
        prompt,
        file_name=file_name,
        rag_active=rag_active,
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


@app.get("/rag/status")
async def rag_status() -> dict[str, object]:
    return get_rag_status()


@app.post("/analyze", response_model=AnalyzeResponse)
async def analyze(
    file: UploadFile = File(...),
    use_rag: bool = Form(False),
) -> AnalyzeResponse | JSONResponse:
    if file.content_type not in ("application/pdf", "application/x-pdf"):
        raise HTTPException(status_code=400, detail="Csak PDF fájl támogatott")

    pdf_bytes = await file.read()
    if not pdf_bytes:
        raise HTTPException(status_code=400, detail="A feltöltött fájl üres")

    max_pdf_size = 50 * 1024 * 1024  # Gemini inline PDF limit
    if len(pdf_bytes) > max_pdf_size:
        raise HTTPException(status_code=400, detail="A PDF fájl meghaladja az 50 MB-os limitet")

    if use_rag and not is_rag_available():
        raise HTTPException(
            status_code=400,
            detail="A RAG modul nincs engedelyezve vagy nincs szabalyzat betoltve",
        )

    # CSAK AZ API-NÉZET MIATT – a napló az elemzés végén a válaszba kerül
    token = begin_api_traces()
    try:
        try:
            return await _analyze_pdf(pdf_bytes, use_rag=use_rag, file_name=file.filename or "")
        except RuntimeError as exc:
            return _trace_error(503, str(exc))
        except ValueError as exc:
            logger.exception("Failed to parse Gemini response")
            return _trace_error(502, str(exc))
        except Exception:
            logger.exception("Contract analysis failed")
            return _trace_error(500, "A szerződés elemzése sikertelen")
    finally:
        reset_api_traces(token)


if __name__ == "__main__":
    import uvicorn

    uvicorn.run("main:app", host="0.0.0.0", port=PORT, reload=False)
