import logging
import os
import re
from dataclasses import dataclass
from pathlib import Path

logger = logging.getLogger(__name__)

RAG_ENABLED = os.getenv("RAG_ENABLED", "false").lower() in ("1", "true", "yes")
RAG_POLICY_DIR = os.getenv("RAG_POLICY_DIR", "policies")
RAG_MAX_POLICY_CHARS = int(os.getenv("RAG_MAX_POLICY_CHARS", "30000"))
RAG_CHUNK_SIZE = int(os.getenv("RAG_CHUNK_SIZE", "1500"))

_POLICY_EXTENSIONS = {".txt", ".md"}


@dataclass(frozen=True)
class PolicyDocument:
    name: str
    path: Path
    content: str


@dataclass(frozen=True)
class PolicyChunk:
    policy_name: str
    content: str


def _backend_root() -> Path:
    return Path(__file__).resolve().parent


def resolve_policy_dir() -> Path:
    policy_path = Path(RAG_POLICY_DIR)
    if policy_path.is_absolute():
        return policy_path
    return _backend_root() / policy_path


def is_rag_available() -> bool:
    return RAG_ENABLED and bool(load_policy_documents())


def load_policy_documents() -> list[PolicyDocument]:
    policy_dir = resolve_policy_dir()
    if not policy_dir.is_dir():
        return []

    documents: list[PolicyDocument] = []
    for path in sorted(policy_dir.iterdir()):
        if not path.is_file() or path.suffix.lower() not in _POLICY_EXTENSIONS:
            continue
        try:
            content = path.read_text(encoding="utf-8").strip()
        except OSError:
            logger.exception("Nem olvashato szabalyzat fajl: %s", path)
            continue
        if not content:
            continue
        documents.append(PolicyDocument(name=path.stem, path=path, content=content))

    return documents


def _split_into_chunks(content: str, chunk_size: int) -> list[str]:
    paragraphs = [part.strip() for part in re.split(r"\n\s*\n", content) if part.strip()]
    chunks: list[str] = []
    current = ""

    for paragraph in paragraphs:
        if len(paragraph) > chunk_size:
            if current:
                chunks.append(current)
                current = ""
            for index in range(0, len(paragraph), chunk_size):
                chunks.append(paragraph[index : index + chunk_size])
            continue

        candidate = f"{current}\n\n{paragraph}".strip() if current else paragraph
        if len(candidate) <= chunk_size:
            current = candidate
            continue

        chunks.append(current)
        current = paragraph

    if current:
        chunks.append(current)

    return chunks


def _chunk_policy_documents(documents: list[PolicyDocument]) -> list[PolicyChunk]:
    chunks: list[PolicyChunk] = []
    for document in documents:
        for chunk in _split_into_chunks(document.content, RAG_CHUNK_SIZE):
            chunks.append(PolicyChunk(policy_name=document.name, content=chunk))
    return chunks


def _select_chunks(chunks: list[PolicyChunk], max_chars: int) -> list[PolicyChunk]:
    if not chunks:
        return []

    total_chars = sum(len(chunk.content) for chunk in chunks)
    if total_chars <= max_chars:
        return chunks

    # Egyszeru round-robin valasztas: minden szabalyzatbol aranyosan veszunk reszt
    by_policy: dict[str, list[PolicyChunk]] = {}
    for chunk in chunks:
        by_policy.setdefault(chunk.policy_name, []).append(chunk)

    selected: list[PolicyChunk] = []
    policy_names = sorted(by_policy)
    indices = dict.fromkeys(policy_names, 0)

    while sum(len(chunk.content) for chunk in selected) < max_chars:
        added_in_round = False
        for policy_name in policy_names:
            policy_chunks = by_policy[policy_name]
            index = indices[policy_name]
            if index >= len(policy_chunks):
                continue

            candidate = policy_chunks[index]
            indices[policy_name] += 1
            if sum(len(chunk.content) for chunk in selected) + len(candidate.content) > max_chars:
                if not selected:
                    selected.append(candidate)
                return selected

            selected.append(candidate)
            added_in_round = True

        if not added_in_round:
            break

    return selected


def build_policy_context() -> str:
    documents = load_policy_documents()
    if not documents:
        return ""

    chunks = _select_chunks(_chunk_policy_documents(documents), RAG_MAX_POLICY_CHARS)
    if not chunks:
        return ""

    sections: list[str] = []
    for chunk in chunks:
        sections.append(f"### Szabalyzat: {chunk.policy_name}\n{chunk.content}")

    return "\n\n".join(sections)


def get_rag_status() -> dict[str, object]:
    documents = load_policy_documents()
    return {
        "enabled": RAG_ENABLED,
        "available": RAG_ENABLED and bool(documents),
        "policy_count": len(documents),
        "policy_names": [document.name for document in documents],
        "policy_dir": str(resolve_policy_dir()),
    }


RAG_PROMPT_EXTENSION = (
    '\n\nTovabbi mezo a belso szabalyzatokkal valo osszeveteshez:\n'
    '- "policy_findings": objektumok listaja, mindegyik:\n'
    '  - "policy": a relevans belso szabalyzat neve\n'
    '  - "status": "compliant" (megfelel), "warning" (figyelmeztetes) vagy '
    '"violation" (sertes)\n'
    '  - "quote": relevans idézet a szerzodesbol (ha van)\n'
    '  - "explanation": rovid magyar magyarazat\n\n'
    "Hasonlitsd ossze a szerzodest az alabb csatolt belso szabalyzati reszekkel. "
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
