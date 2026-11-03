import io
import logging
import os
import re
import warnings
from dataclasses import dataclass

import agentplatform
from agentplatform import types as ap_types
from google.genai import types as genai_types
from pypdf import PdfReader

logger = logging.getLogger(__name__)

# A RAG Engine Python SDK kiserleti modulja warningot ir; a hivas ettol mukodik.
warnings.filterwarnings("ignore", message=".*rag module is experimental.*")

RAG_ENABLED = os.getenv("RAG_ENABLED", "true").lower() in ("1", "true", "yes")
GCP_PROJECT_ID = os.getenv("GCP_PROJECT_ID", "")
RAG_CORPUS = os.getenv("RAG_CORPUS", "")
RAG_LOCATION = os.getenv("RAG_LOCATION", "europe-west4")
RAG_TOP_K = int(os.getenv("RAG_TOP_K", "8"))
RAG_RANKER = os.getenv("RAG_RANKER", "semantic-ranker-default@latest")
RAG_MAX_CONTEXT_CHARS = int(os.getenv("RAG_MAX_CONTEXT_CHARS", "30000"))
RAG_QUERY_CHARS = int(os.getenv("RAG_QUERY_CHARS", "2500"))

_FALLBACK_QUERY = (
    "szerzodes fizetesi hatarido elore fizetes kesedelmi kamat "
    "szemelyes adat adatvedelem adatbiztonsag adatmegorzes"
)

_rag_client: agentplatform.Client | None = None


class RagRetrievalError(Exception):
    """A Vertex RAG visszakereses hibaja, a mar osszeallitott keres keressel."""

    def __init__(self, message: str, *, request: dict[str, object]) -> None:
        super().__init__(message)
        self.request = request


@dataclass(frozen=True)
class RetrievedChunk:
    source: str
    policy_name: str
    content: str
    score: float | None
    distance: float | None


@dataclass(frozen=True)
class PolicyRetrieval:
    """A promptba kerulo szabalyzati szoveg es az oktatasi panel masolata."""

    context: str
    request: dict[str, object]
    response: dict[str, object]


def rag_location() -> str:
    """A RAG Engine regionalis. A corpus nevéből olvassuk, kulonben RAG_LOCATION."""
    parts = RAG_CORPUS.split("/")
    if "locations" in parts:
        index = parts.index("locations")
        if index + 1 < len(parts):
            return parts[index + 1]
    return RAG_LOCATION


def is_rag_available() -> bool:
    return RAG_ENABLED and bool(RAG_CORPUS)


def get_rag_status() -> dict[str, object]:
    return {
        "enabled": RAG_ENABLED,
        "available": is_rag_available(),
        "corpus": RAG_CORPUS,
        "location": rag_location() if RAG_CORPUS else RAG_LOCATION,
    }


def _clip(text: str, limit: int) -> str:
    if len(text) <= limit:
        return text
    return text[:limit] + f"\n… ({len(text)} karakterből az első {limit} látható)"


def _policy_name(source: str) -> str:
    name = (source or "").rstrip("/").rsplit("/", 1)[-1]
    return name or "szabalyzat"


def _contract_query(pdf_bytes: bytes) -> tuple[str, str]:
    """A szerzodes szovege a vektoros kereses kerdese. Szkennelt PDF-nel altalanos kereses."""
    text = ""
    try:
        reader = PdfReader(io.BytesIO(pdf_bytes))
        text = "\n".join((page.extract_text() or "") for page in reader.pages)
    except Exception:
        logger.exception("A PDF szovege nem nyerheto ki, altalanos szabalyzat-kereses fut")

    text = re.sub(r"\s+", " ", text).strip()
    if len(text) < 80:
        return _FALLBACK_QUERY, "fallback"
    return text[:RAG_QUERY_CHARS], "pdf_text"


def _client() -> agentplatform.Client:
    global _rag_client
    if _rag_client is None:
        if not GCP_PROJECT_ID:
            raise RagRetrievalError(
                "A GCP_PROJECT_ID kornyezeti valtozo kotelezo a RAG kereseshez",
                request={"corpus": RAG_CORPUS},
            )
        _rag_client = agentplatform.Client(project=GCP_PROJECT_ID, location=rag_location())
    return _rag_client


def _retrieve_contexts(query: str) -> list[RetrievedChunk]:
    ranking = None
    if RAG_RANKER:
        ranking = genai_types.RagRetrievalConfigRanking(
            rank_service=genai_types.RagRetrievalConfigRankingRankService(model_name=RAG_RANKER)
        )

    def call(hybrid: bool):
        retrieval: dict[str, object] = {"top_k": RAG_TOP_K}
        if ranking is not None:
            retrieval["ranking"] = ranking
        if hybrid:
            retrieval["hybrid_search"] = genai_types.RagRetrievalConfigHybridSearch(alpha=0.4)
        return _client().rag.retrieve_contexts(
            vertex_rag_store=genai_types.VertexRagStore(
                rag_resources=[
                    genai_types.VertexRagStoreRagResource(rag_corpus=RAG_CORPUS)
                ]
            ),
            query=ap_types.RagQuery(
                text=query,
                rag_retrieval_config=genai_types.RagRetrievalConfig(**retrieval),
            ),
        )

    try:
        response = call(hybrid=True)
    except Exception as exc:
        if "429" in str(exc) or "RESOURCE_EXHAUSTED" in str(exc):
            raise
        logger.warning("Hibrid RAG kereses sikertelen, ujra vektoros keresessel: %s", exc)
        response = call(hybrid=False)

    chunks: list[RetrievedChunk] = []
    contexts = getattr(getattr(response, "contexts", None), "contexts", None) or []
    for ctx in contexts:
        text = getattr(ctx, "text", None) or ""
        if not text:
            chunk = getattr(ctx, "chunk", None)
            text = getattr(chunk, "text", "") if chunk is not None else ""
        text = text.strip()
        if not text:
            continue
        source = getattr(ctx, "source_uri", "") or getattr(ctx, "source_display_name", "") or ""
        score = getattr(ctx, "score", None)
        distance = getattr(ctx, "distance", None)
        try:
            score = float(score) if score is not None else None
        except (TypeError, ValueError):
            score = None
        try:
            distance = float(distance) if distance is not None else None
        except (TypeError, ValueError):
            distance = None
        chunks.append(
            RetrievedChunk(
                source=source,
                policy_name=_policy_name(source),
                content=text,
                score=score,
                distance=distance,
            )
        )
    return chunks


def _context_from_chunks(chunks: list[RetrievedChunk]) -> tuple[str, list[RetrievedChunk]]:
    selected: list[RetrievedChunk] = []
    parts: list[str] = []
    used = 0
    for chunk in chunks:
        piece = f"### Szabalyzat: {chunk.policy_name}\n{chunk.content}"
        if selected and used + len(piece) > RAG_MAX_CONTEXT_CHARS:
            break
        selected.append(chunk)
        parts.append(piece)
        used += len(piece)
    return "\n\n".join(parts), selected


def retrieve_for_contract(pdf_bytes: bytes) -> PolicyRetrieval:
    """Vertex RAG Engine: a szerzodeshez hasonlo szabalyzat-reszletek."""
    if not RAG_CORPUS:
        raise RagRetrievalError(
            "A RAG_CORPUS kornyezeti valtozo ures",
            request={"method": "POST", "operation": "retrieveContexts"},
        )

    query, query_source = _contract_query(pdf_bytes)
    location = rag_location()
    request: dict[str, object] = {
        "method": "POST",
        "endpoint": (
            f"https://{location}-aiplatform.googleapis.com/v1/projects/{GCP_PROJECT_ID}"
            f"/locations/{location}:retrieveContexts"
        ),
        "corpus": RAG_CORPUS,
        "location": location,
        "top_k": RAG_TOP_K,
        "ranker": RAG_RANKER,
        "query_source": query_source,
        "query": _clip(query, 1500),
    }

    try:
        chunks = _retrieve_contexts(query)
    except RagRetrievalError:
        raise
    except Exception as exc:
        raise RagRetrievalError(str(exc), request=request) from exc

    context, selected = _context_from_chunks(chunks)
    visible = [
        {
            "policy": chunk.policy_name,
            "source": chunk.source,
            "score": chunk.score,
            "distance": chunk.distance,
            "chars": len(chunk.content),
            "content": _clip(chunk.content, 1500),
        }
        for chunk in selected[:8]
    ]
    response: dict[str, object] = {
        "chunk_count": len(chunks),
        "chunk_count_selected": len(selected),
        "context_chars": len(context),
        "policy_names": sorted({chunk.policy_name for chunk in selected}),
        "selected_chunks": visible,
    }
    if len(visible) < len(selected):
        response["omitted_chunks"] = len(selected) - len(visible)
    return PolicyRetrieval(context=context, request=request, response=response)


RAG_PROMPT_EXTENSION = (
    '\n\nTovabbi mezo a belso szabalyzatokkal valo osszeveteshez:\n'
    '- "policy_findings": objektumok listaja, mindegyik:\n'
    '  - "policy": a relevans belso szabalyzat neve\n'
    '  - "status": "compliant" (megfelel), "warning" (figyelmeztetes) vagy '
    '"violation" (sertes)\n'
    '  - "quote": relevans idézet a szerzodesbol (ha van)\n'
    '  - "explanation": rovid magyar magyarazat\n\n'
    "Hasonlitsd ossze a szerzodest az alabb csatolt belso szabalyzati reszekkel. "
    "A reszletek a RAG Engine visszakeresesebol jonnek, nem a teljes szabalyzat-tar. "
    "Ha egy szabalyzat nem relevans ehhez a szerzodeshez, hagyd ki. "
    "A tobbi mezo (summary, key_clauses, risk_flags, contract_quality) "
    "valtozatlanul kotelezo."
)


def build_rag_prompt(base_prompt: str, policy_context: str) -> str:
    return (
        f"{base_prompt}{RAG_PROMPT_EXTENSION}\n\n"
        "## Belso szabalyzati kontextus (RAG)\n\n"
        f"{policy_context}"
    )
