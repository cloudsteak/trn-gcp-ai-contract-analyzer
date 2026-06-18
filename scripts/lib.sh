#!/usr/bin/env bash
# GCP setup helper fuggvenyek – service account propagalas es IAM retry

wait_for_service_account() {
  local email="$1"
  local max_attempts="${2:-30}"
  local attempt=1

  while (( attempt <= max_attempts )); do
    if gcloud iam service-accounts describe "${email}" >/dev/null 2>&1; then
      echo "Service account elerheto: ${email}"
      return 0
    fi
    echo "Varakozas a service account propagalasra (${attempt}/${max_attempts}): ${email}"
    sleep 2
    ((attempt++)) || true
  done

  echo "Hiba: service account nem lett elerheto idoben: ${email}" >&2
  return 1
}

retry_gcloud() {
  local max_attempts="${1:-12}"
  shift
  local attempt=1
  local delay=5

  while (( attempt <= max_attempts )); do
    if "$@"; then
      return 0
    fi
    if (( attempt < max_attempts )); then
      echo "gcloud parancs sikertelen, ujraproba ${attempt}/${max_attempts}..."
      sleep "${delay}"
    fi
    ((attempt++)) || true
  done

  echo "Hiba: gcloud parancs veglegesen sikertelen." >&2
  return 1
}

add_project_iam_binding() {
  local project="$1"
  local member="$2"
  local role="$3"

  retry_gcloud 5 gcloud projects add-iam-policy-binding "${project}" \
    --member="${member}" \
    --role="${role}" \
    --condition=None
}

add_sa_iam_binding() {
  local sa_email="$1"
  local member="$2"
  local role="$3"

  retry_gcloud 5 gcloud iam service-accounts add-iam-policy-binding "${sa_email}" \
    --member="${member}" \
    --role="${role}" \
    --condition=None
}
