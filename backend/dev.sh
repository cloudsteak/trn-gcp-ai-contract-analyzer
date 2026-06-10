#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
uv sync
exec uv run python -m uvicorn main:app --reload --host 127.0.0.1 --port 8080
