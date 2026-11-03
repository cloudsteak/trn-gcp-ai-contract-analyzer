#!/usr/bin/env bash
# A policy/ fajlok feltoltese a RAG corpusba.
# A setup.sh elso telepiteskor meghivja. Egyedul akkor kell, ha a policy/ valtozik.
# Ujrafuttathato: a meglevo bucketet es a display name alapjan meglevo corpust nem hozza letre ujra.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

PROJECT_ID="${GCP_PROJECT_ID:-${GOOGLE_CLOUD_PROJECT:-}}"
GCP_REGION="${GCP_REGION:-europe-west4}"
RAG_LOCATION="${RAG_LOCATION:-${GCP_REGION}}"
RAG_CORPUS_DISPLAY_NAME="${RAG_CORPUS_DISPLAY_NAME:-contract-regulations}"
RAG_BUCKET="${RAG_BUCKET:-}"
POLICY_DIR="${POLICY_DIR:-${REPO_ROOT}/policy}"
BACKEND_SERVICE="${BACKEND_SERVICE:-contract-analyzer-backend}"
SERVICE_ACCOUNT="${SERVICE_ACCOUNT:-contract-analyzer-sa}"

if [[ -z "${PROJECT_ID}" ]]; then
  echo "Hiba: allitsd be a GCP_PROJECT_ID vagy GOOGLE_CLOUD_PROJECT kornyezeti valtozot." >&2
  exit 1
fi

if [[ ! -d "${POLICY_DIR}" ]]; then
  echo "Hiba: nincs szabalyzat mappa: ${POLICY_DIR}" >&2
  exit 1
fi

POLICY_FILES=()
while IFS= read -r path; do
  POLICY_FILES+=("${path}")
done < <(find "${POLICY_DIR}" -maxdepth 1 -type f \( -name '*.md' -o -name '*.txt' -o -name '*.pdf' \) | sort)

if (( ${#POLICY_FILES[@]} == 0 )); then
  echo "Hiba: a ${POLICY_DIR} mappaban nincs .md, .txt vagy .pdf fajl." >&2
  exit 1
fi

echo "Projekt: ${PROJECT_ID}"
echo "RAG regio: ${RAG_LOCATION}"
echo "Corpus: ${RAG_CORPUS_DISPLAY_NAME}"
gcloud config set project "${PROJECT_ID}"

echo "Szukseges API-k engedelyezese..."
gcloud services enable \
  aiplatform.googleapis.com \
  storage.googleapis.com \
  discoveryengine.googleapis.com

PROJECT_NUMBER="$(gcloud projects describe "${PROJECT_ID}" --format='value(projectNumber)')"
SA_EMAIL="${SERVICE_ACCOUNT}@${PROJECT_ID}.iam.gserviceaccount.com"
RAG_AGENT="service-${PROJECT_NUMBER}@gcp-sa-vertex-rag.iam.gserviceaccount.com"
API_ROOT="https://${RAG_LOCATION}-aiplatform.googleapis.com/v1"

access_token() {
  gcloud auth print-access-token
}

LEGACY_BUCKET="${PROJECT_ID}-regulations"
if gcloud storage buckets describe "gs://${LEGACY_BUCKET}" >/dev/null 2>&1; then
  echo "Regi bucket torlese: gs://${LEGACY_BUCKET}"
  gcloud storage rm --recursive "gs://${LEGACY_BUCKET}/**" || true
  gcloud storage buckets delete "gs://${LEGACY_BUCKET}" --quiet
fi

delete_bucket() {
  local bucket="$1"
  gcloud storage rm --recursive "gs://${bucket}/**" || true
  gcloud storage buckets delete "gs://${bucket}" --quiet
}

if [[ -z "${RAG_BUCKET}" ]]; then
  while IFS= read -r candidate; do
    [[ -z "${candidate}" ]] && continue
    candidate_location="$(gcloud storage buckets describe "gs://${candidate}" --format='value(location)' | python3 -c 'import sys; print(sys.stdin.read().strip().lower())')"
    if [[ "${candidate_location}" == "${RAG_LOCATION}" ]]; then
      RAG_BUCKET="${candidate}"
      break
    fi
    echo "Mas regioban levo bucket torlese: gs://${candidate} (${candidate_location})"
    delete_bucket "${candidate}"
  done < <(gcloud storage buckets list --format='value(name)' | grep -E '^contract-analyzer-policy-[0-9]{6}$' || true)
fi

if [[ -n "${RAG_BUCKET}" ]] && gcloud storage buckets describe "gs://${RAG_BUCKET}" >/dev/null 2>&1; then
  bucket_location="$(gcloud storage buckets describe "gs://${RAG_BUCKET}" --format='value(location)' | python3 -c 'import sys; print(sys.stdin.read().strip().lower())')"
  if [[ "${bucket_location}" == "${RAG_LOCATION}" ]]; then
    echo "A bucket mar letezik: gs://${RAG_BUCKET}"
  else
    echo "Mas regioban levo bucket torlese: gs://${RAG_BUCKET} (${bucket_location})"
    delete_bucket "${RAG_BUCKET}"
    RAG_BUCKET=""
  fi
fi

if [[ -z "${RAG_BUCKET}" ]] || ! gcloud storage buckets describe "gs://${RAG_BUCKET}" >/dev/null 2>&1; then
  bucket_created=0
  bucket_attempt=1
  while (( bucket_attempt <= 5 )); do
    if [[ -z "${RAG_BUCKET}" ]] || (( bucket_attempt > 1 )); then
      RAG_BUCKET="contract-analyzer-policy-$(python3 -c 'import random; print(f"{random.randint(0, 999999):06d}")')"
    fi
    echo "Bucket letrehozasa: gs://${RAG_BUCKET}"
    if gcloud storage buckets create "gs://${RAG_BUCKET}" \
      --location="${RAG_LOCATION}" \
      --uniform-bucket-level-access; then
      bucket_created=1
      break
    fi
    echo "A bucket nev foglalt, uj szamot valasztok."
    ((bucket_attempt++)) || true
  done
  if (( bucket_created == 0 )); then
    echo "Hiba: a bucket nem hozhato letre." >&2
    exit 1
  fi
fi

if gcloud iam service-accounts describe "${SA_EMAIL}" >/dev/null 2>&1; then
  echo "A backend service account a semantic rankert hasznalhatja."
  add_project_iam_binding "${PROJECT_ID}" "serviceAccount:${SA_EMAIL}" "roles/discoveryengine.viewer"
else
  echo "A ${SA_EMAIL} meg nem letezik. A ranker jogot a setup.sh adja hozza."
fi

GCS_URIS=()
echo "Szabalyzatok feltoltese a policy/ mappabol..."
for path in "${POLICY_FILES[@]}"; do
  name="$(basename "${path}")"
  destination="gs://${RAG_BUCKET}/policy/${name}"
  gcloud storage cp "${path}" "${destination}"
  GCS_URIS+=("${destination}")
  echo "  ${destination}"
done

find_corpus_name() {
  curl -fsS \
    -H "Authorization: Bearer $(access_token)" \
    "${API_ROOT}/projects/${PROJECT_ID}/locations/${RAG_LOCATION}/ragCorpora?pageSize=100" \
    | python3 -c '
import json, sys
display = sys.argv[1]
data = json.load(sys.stdin)
for corpus in data.get("ragCorpora") or []:
    if corpus.get("displayName") == display:
        print(corpus.get("name", ""))
        break
' "${RAG_CORPUS_DISPLAY_NAME}"
}

# A kesz operation valaszat stdout-ra irja. A varakozas a stderr-re megy.
wait_operation() {
  local op_name="$1"
  local attempt=1
  local max_attempts=90
  local body status

  while (( attempt <= max_attempts )); do
    body="$(curl -fsS -H "Authorization: Bearer $(access_token)" "${API_ROOT}/${op_name}")"
    set +e
    python3 -c '
import json, sys
op = json.load(sys.stdin)
if op.get("error"):
    print(json.dumps(op["error"], ensure_ascii=False), file=sys.stderr)
    sys.exit(2)
if op.get("done") is True:
    print(json.dumps(op.get("response") or {}, ensure_ascii=False))
    sys.exit(0)
sys.exit(1)
' <<<"${body}"
    status=$?
    set -e
    if [[ "${status}" -eq 0 ]]; then
      return 0
    fi
    if [[ "${status}" -eq 2 ]]; then
      echo "Hiba: a RAG muvelet sikertelen." >&2
      return 1
    fi
    echo "RAG muvelet folyamatban (${attempt}/${max_attempts})..." >&2
    sleep 10
    ((attempt++)) || true
  done

  echo "Hiba: a RAG muvelet nem fejezodott be 15 percen belul." >&2
  return 1
}

# A szolgaltatasfiok az elso corpus letrehozasakor jon letre, elotte a bucket IAM 400-at ad.
grant_rag_agent_bucket_access() {
  local attempt=1
  local max_attempts=36
  local err_file
  err_file="$(mktemp)"

  echo "A RAG Data Service Agent olvasasi joga a bucketen: ${RAG_AGENT}"
  while (( attempt <= max_attempts )); do
    if gcloud storage buckets add-iam-policy-binding "gs://${RAG_BUCKET}" \
      --member="serviceAccount:${RAG_AGENT}" \
      --role="roles/storage.objectViewer" \
      --quiet >"${err_file}" 2>&1; then
      rm -f "${err_file}"
      return 0
    fi
    if ! grep -q "does not exist" "${err_file}"; then
      cat "${err_file}" >&2
      rm -f "${err_file}"
      return 1
    fi
    echo "A RAG Data Service Agent meg nem letezik, varakozas (${attempt}/${max_attempts})..." >&2
    sleep 5
    ((attempt++)) || true
  done

  cat "${err_file}" >&2
  rm -f "${err_file}"
  echo "Hiba: a RAG Data Service Agent nem lett elerheto: ${RAG_AGENT}" >&2
  return 1
}

CORPUS_NAME="$(find_corpus_name)"
if [[ -n "${CORPUS_NAME}" ]]; then
  echo "A corpus mar letezik: ${CORPUS_NAME}"
else
  echo "Corpus letrehozasa (text-multilingual-embedding-002, RagManaged Spanner, KNN)..."
  CREATE_BODY="$(python3 -c '
import json, sys
project, location, display = sys.argv[1:]
endpoint = (
    f"projects/{project}/locations/{location}/publishers/google/models/"
    "text-multilingual-embedding-002"
)
print(json.dumps({
    "displayName": display,
    "description": "Szerzodeselemzo belso szabalyzatok",
    "vectorDbConfig": {
        "ragEmbeddingModelConfig": {
            "vertexPredictionEndpoint": {"endpoint": endpoint}
        },
        "ragManagedDb": {"knn": {}},
    },
}))
' "${PROJECT_ID}" "${RAG_LOCATION}" "${RAG_CORPUS_DISPLAY_NAME}")"
  CREATE_HTTP="$(mktemp)"
  CREATE_CODE="$(curl -sS -o "${CREATE_HTTP}" -w '%{http_code}' -X POST \
    -H "Authorization: Bearer $(access_token)" \
    -H "Content-Type: application/json" \
    -d "${CREATE_BODY}" \
    "${API_ROOT}/projects/${PROJECT_ID}/locations/${RAG_LOCATION}/ragCorpora")"
  if [[ "${CREATE_CODE}" != 2* ]]; then
    echo "Hiba: a corpus letrehozas ${CREATE_CODE} valaszt adott." >&2
    cat "${CREATE_HTTP}" >&2
    rm -f "${CREATE_HTTP}"
    exit 1
  fi
  CREATE_RESPONSE="$(cat "${CREATE_HTTP}")"
  rm -f "${CREATE_HTTP}"
  OP_NAME="$(python3 -c 'import json,sys; print(json.load(sys.stdin)["name"])' <<<"${CREATE_RESPONSE}")"
  CORPUS_RESPONSE="$(wait_operation "${OP_NAME}")"
  CORPUS_NAME="$(python3 -c 'import json,sys; print(json.load(sys.stdin).get("name", ""))' <<<"${CORPUS_RESPONSE}")"
  if [[ -z "${CORPUS_NAME}" ]]; then
    echo "Hiba: a corpus letrejott, de a resource nev nem olvashato." >&2
    echo "${CORPUS_RESPONSE}" >&2
    exit 1
  fi
  echo "Corpus letrehozva: ${CORPUS_NAME}"
fi

grant_rag_agent_bucket_access

echo "Szabalyzatok importalasa a corpusba..."
IMPORT_BODY="$(python3 -c '
import json, sys
print(json.dumps({
    "importRagFilesConfig": {
        "gcsSource": {"uris": sys.argv[1:]},
        "ragFileTransformationConfig": {
            "ragFileChunkingConfig": {
                "fixedLengthChunking": {"chunkSize": 512, "chunkOverlap": 100}
            }
        },
        "maxEmbeddingRequestsPerMin": 1000,
    }
}))
' "${GCS_URIS[@]}")"
CORPUS_ID="${CORPUS_NAME##*/}"
IMPORT_HTTP="$(mktemp)"
IMPORT_CODE="$(curl -sS -o "${IMPORT_HTTP}" -w '%{http_code}' -X POST \
  -H "Authorization: Bearer $(access_token)" \
  -H "Content-Type: application/json" \
  -d "${IMPORT_BODY}" \
  "${API_ROOT}/projects/${PROJECT_ID}/locations/${RAG_LOCATION}/ragCorpora/${CORPUS_ID}/ragFiles:import")"
if [[ "${IMPORT_CODE}" != 2* ]]; then
  echo "Hiba: a szabalyzat import ${IMPORT_CODE} valaszt adott." >&2
  cat "${IMPORT_HTTP}" >&2
  rm -f "${IMPORT_HTTP}"
  exit 1
fi
IMPORT_RESPONSE="$(cat "${IMPORT_HTTP}")"
rm -f "${IMPORT_HTTP}"
IMPORT_OP="$(python3 -c 'import json,sys; print(json.load(sys.stdin)["name"])' <<<"${IMPORT_RESPONSE}")"
IMPORT_RESULT="$(wait_operation "${IMPORT_OP}")"
echo "Import eredmeny: ${IMPORT_RESULT}"
python3 -c '
import json, sys
data = json.loads(sys.stdin.read())

def count(*keys):
    for key in keys:
        if data.get(key) is not None:
            return int(data[key])
    return 0

failed = count("failedRagFilesCount", "failed_rag_files_count")
imported = count("importedRagFilesCount", "imported_rag_files_count")
skipped = count("skippedRagFilesCount", "skipped_rag_files_count")
print(f"importalt={imported} kihagyott={skipped} sikertelen={failed}")
if failed and imported == 0 and skipped == 0:
    sys.exit(1)
' <<<"${IMPORT_RESULT}"

if gcloud run services describe "${BACKEND_SERVICE}" --region="${GCP_REGION}" >/dev/null 2>&1; then
  echo "Cloud Run RAG_CORPUS frissitese: ${BACKEND_SERVICE}"
  gcloud run services update "${BACKEND_SERVICE}" \
    --region="${GCP_REGION}" \
    --update-env-vars="RAG_ENABLED=true,RAG_CORPUS=${CORPUS_NAME}"
fi

echo "Szabalyzatok feltoltve a corpusba."
echo "RAG_CORPUS=${CORPUS_NAME}"
echo ""
echo "A ./scripts/upload-doc-to-rag.sh a policy/ fajlokat tolti a corpusba."
echo "Elso telepiteskor a ./scripts/setup.sh hivja, kulon nem kell futtatni."
echo "Ujrafuttatas: uj vagy modositott fajl a policy/ mappaban."
