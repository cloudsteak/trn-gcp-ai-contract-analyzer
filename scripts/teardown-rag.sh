#!/usr/bin/env bash
# Visszavonja a upload-doc-to-rag.sh altal letrehozott corpust, bucketet es RAG beallitasokat.
# Ujrafuttathato: ami mar nincs meg, azt kihagyja.
set -euo pipefail

PROJECT_ID="${GCP_PROJECT_ID:-${GOOGLE_CLOUD_PROJECT:-}}"
GCP_REGION="${GCP_REGION:-europe-west4}"
RAG_LOCATION="${RAG_LOCATION:-${GCP_REGION}}"
RAG_CORPUS_DISPLAY_NAME="${RAG_CORPUS_DISPLAY_NAME:-contract-regulations}"
BACKEND_SERVICE="${BACKEND_SERVICE:-contract-analyzer-backend}"
SERVICE_ACCOUNT="${SERVICE_ACCOUNT:-contract-analyzer-sa}"

if [[ -z "${PROJECT_ID}" ]]; then
  echo "Hiba: allitsd be a GCP_PROJECT_ID vagy GOOGLE_CLOUD_PROJECT kornyezeti valtozot." >&2
  exit 1
fi

echo "Projekt: ${PROJECT_ID}"
echo "RAG regio: ${RAG_LOCATION}"
gcloud config set project "${PROJECT_ID}"

SA_EMAIL="${SERVICE_ACCOUNT}@${PROJECT_ID}.iam.gserviceaccount.com"
API_ROOT="https://${RAG_LOCATION}-aiplatform.googleapis.com/v1"

echo "RAG corpus torlese: ${RAG_CORPUS_DISPLAY_NAME}"
LIST_HTTP="$(mktemp)"
LIST_CODE="$(curl -sS -o "${LIST_HTTP}" -w '%{http_code}' \
  -H "Authorization: Bearer $(gcloud auth print-access-token)" \
  "${API_ROOT}/projects/${PROJECT_ID}/locations/${RAG_LOCATION}/ragCorpora?pageSize=100" || true)"
CORPUS_NAME=""
if [[ "${LIST_CODE}" == 2* ]]; then
  CORPUS_NAME="$(python3 -c '
import json, sys
display = sys.argv[1]
data = json.load(sys.stdin)
for corpus in data.get("ragCorpora") or []:
    if corpus.get("displayName") == display:
        print(corpus.get("name", ""))
        break
' "${RAG_CORPUS_DISPLAY_NAME}" < "${LIST_HTTP}")"
else
  echo "A corpus lista ${LIST_CODE} valaszt adott, a torles kihagyva." >&2
  cat "${LIST_HTTP}" >&2 || true
fi
rm -f "${LIST_HTTP}"

if [[ -n "${CORPUS_NAME}" ]]; then
  CORPUS_ID="${CORPUS_NAME##*/}"
  DELETE_HTTP="$(mktemp)"
  DELETE_CODE="$(curl -sS -o "${DELETE_HTTP}" -w '%{http_code}' -X DELETE \
    -H "Authorization: Bearer $(gcloud auth print-access-token)" \
    "${API_ROOT}/projects/${PROJECT_ID}/locations/${RAG_LOCATION}/ragCorpora/${CORPUS_ID}" || true)"
  if [[ "${DELETE_CODE}" == 2* ]]; then
    echo "Corpus torles elinditva: ${CORPUS_NAME}"
  else
    echo "A corpus torlese ${DELETE_CODE} valaszt adott: ${CORPUS_NAME}" >&2
    cat "${DELETE_HTTP}" >&2 || true
  fi
  rm -f "${DELETE_HTTP}"
else
  echo "A corpus nem letezik, kihagyva."
fi

delete_rag_bucket() {
  local bucket="$1"
  echo "RAG bucket torlese: gs://${bucket}"
  gcloud storage rm --recursive "gs://${bucket}/**" || true
  gcloud storage buckets delete "gs://${bucket}" --quiet
}

BUCKETS=()
if [[ -n "${RAG_BUCKET:-}" ]]; then
  BUCKETS+=("${RAG_BUCKET}")
else
  while IFS= read -r bucket; do
    [[ -n "${bucket}" ]] && BUCKETS+=("${bucket}")
  done < <(gcloud storage buckets list --format='value(name)' | grep -E '^contract-analyzer-policy-[0-9]{6}$' || true)
  BUCKETS+=("${PROJECT_ID}-regulations")
fi

deleted_bucket=0
for bucket in "${BUCKETS[@]}"; do
  if gcloud storage buckets describe "gs://${bucket}" >/dev/null 2>&1; then
    delete_rag_bucket "${bucket}"
    deleted_bucket=1
  fi
done
if (( deleted_bucket == 0 )); then
  echo "A bucket nem letezik, kihagyva."
fi

if gcloud iam service-accounts describe "${SA_EMAIL}" >/dev/null 2>&1; then
  echo "A semantic ranker jog torlese a backend service accountrol."
  gcloud projects remove-iam-policy-binding "${PROJECT_ID}" \
    --member="serviceAccount:${SA_EMAIL}" \
    --role="roles/discoveryengine.viewer" \
    --quiet || true
fi

if [[ "${SKIP_CLOUD_RUN_ENV:-}" != "1" ]] \
  && gcloud run services describe "${BACKEND_SERVICE}" --region="${GCP_REGION}" >/dev/null 2>&1; then
  echo "Cloud Run RAG kornyezeti valtozok torlese: ${BACKEND_SERVICE}"
  gcloud run services update "${BACKEND_SERVICE}" \
    --region="${GCP_REGION}" \
    --remove-env-vars="RAG_ENABLED,RAG_CORPUS" \
    --quiet || true
fi

echo "RAG teardown kesz."
if [[ "${SKIP_CLOUD_RUN_ENV:-}" == "1" ]]; then
  echo "A ./scripts/teardown.sh hivta, a Cloud Run torlese elott."
else
  echo "Csak a corpus es a bucket torolt. A Cloud Run meg megvan."
  echo "Teljes torles: ./scripts/teardown.sh, utana ./scripts/teardown-wif.sh es ./scripts/teardown-github.sh"
fi
