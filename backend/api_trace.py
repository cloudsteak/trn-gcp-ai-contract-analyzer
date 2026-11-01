# CSAK AZ API-NÉZET MIATT – ez az egész fájl.
# Egy elemzés közben összegyűjti a RAG visszakeresés és a Gemini hívás
# oktatási másolatát. Az elemzés eredményét nem befolyásolja.
import logging
from contextvars import ContextVar, Token
from datetime import UTC, datetime
from typing import Any

from pydantic import BaseModel, Field

logger = logging.getLogger(__name__)

_bucket: ContextVar[list["ApiCallTrace"] | None] = ContextVar("api_call_traces", default=None)


class ApiCallTrace(BaseModel):
    """Egy kimenő RAG vagy Gemini hívás oktatási nyoma. layer: rag vagy ai."""

    direction: str = "be-ai"
    layer: str = "ai"
    service: str
    operation: str
    status: str
    duration_ms: int = 0
    occurred_at: str
    request: dict[str, Any] = Field(default_factory=dict)
    response: dict[str, Any] | None = None
    error: str | None = None


def begin_api_traces() -> Token:
    """Új, üres hívásnapló a jelenlegi elemzéshez."""
    return _bucket.set([])


def snapshot_api_traces() -> list[ApiCallTrace]:
    """Az eddig rögzített hívások másolata."""
    return list(_bucket.get() or [])


def reset_api_traces(token: Token) -> None:
    """Napló visszaállítása az elemzés végén."""
    _bucket.reset(token)


def clip_text(text: str | None, limit: int = 4000) -> str:
    """Hosszú prompt vágása, hogy a felület olvasható maradjon."""
    if not text:
        return ""
    if len(text) <= limit:
        return text
    return text[:limit] + f"\n… ({len(text)} karakterből az első {limit} látható)"


def _layer_for_service(service: str) -> str:
    """A szabályzat-visszakeresés és a nyelvi modell külön réteg a panelen."""
    if "rag" in service.lower():
        return "rag"
    return "ai"


def record_api_call(
    *,
    service: str,
    operation: str,
    status: str,
    duration_ms: int,
    request: dict[str, Any],
    response: dict[str, Any] | None = None,
    error: str | None = None,
) -> None:
    """Egy RAG vagy Gemini hívás hozzáadása a naplóhoz. Hiba nem állítja meg az elemzést."""
    try:
        bucket = _bucket.get()
        if bucket is None:
            return
        layer = _layer_for_service(service)
        bucket.append(
            ApiCallTrace(
                direction="be-rag" if layer == "rag" else "be-ai",
                layer=layer,
                service=service,
                operation=operation,
                status=status,
                duration_ms=max(0, int(duration_ms)),
                occurred_at=datetime.now(UTC).isoformat(timespec="milliseconds"),
                request=request,
                response=response,
                error=error,
            )
        )
    except Exception as exc:
        logger.warning("API nyom rögzítése sikertelen: %s", exc)
