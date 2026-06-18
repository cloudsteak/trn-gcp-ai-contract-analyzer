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

wif_pool_state() {
  local project_id="$1"
  local pool_id="$2"
  gcloud iam workload-identity-pools describe "${pool_id}" \
    --project="${project_id}" \
    --location=global \
    --format='value(state)' 2>/dev/null || echo ""
}

wait_for_wif_pool_active() {
  local project_id="$1"
  local pool_id="$2"
  local max_attempts="${3:-30}"
  local attempt=1
  local state=""

  while (( attempt <= max_attempts )); do
    state="$(wif_pool_state "${project_id}" "${pool_id}")"
    if [[ "${state}" == "ACTIVE" ]]; then
      echo "WIF pool aktiv: ${pool_id}"
      return 0
    fi
    echo "Varakozas WIF pool aktiv allapotra (${attempt}/${max_attempts}): ${pool_id} (allapot: ${state:-ismeretlen})"
    sleep 2
    ((attempt++)) || true
  done

  echo "Hiba: WIF pool nem lett aktiv idoben: ${pool_id}" >&2
  return 1
}

# teardown utan a pool soft-delete allapotban maradhat – describe sikeres, de provider letrehozas NOT_FOUND
ensure_wif_pool() {
  local project_id="$1"
  local pool_id="$2"
  local display_name="$3"
  local state=""

  state="$(wif_pool_state "${project_id}" "${pool_id}")"
  case "${state}" in
    ACTIVE)
      echo "A WIF pool mar letezik es aktiv, kihagyva: ${pool_id}"
      ;;
    DELETED)
      echo "A WIF pool torolt allapotban van (soft-delete), visszaallitas: ${pool_id}"
      gcloud iam workload-identity-pools undelete "${pool_id}" \
        --project="${project_id}" \
        --location=global
      wait_for_wif_pool_active "${project_id}" "${pool_id}"
      ;;
    "")
      echo "WIF pool letrehozasa: ${pool_id}"
      gcloud iam workload-identity-pools create "${pool_id}" \
        --project="${project_id}" \
        --location=global \
        --display-name="${display_name}"
      wait_for_wif_pool_active "${project_id}" "${pool_id}"
      ;;
    *)
      echo "Figyelem: WIF pool ismeretlen allapot (${state}), varakozas aktivra: ${pool_id}"
      wait_for_wif_pool_active "${project_id}" "${pool_id}"
      ;;
  esac
}

wif_provider_state() {
  local project_id="$1"
  local pool_id="$2"
  local provider_id="$3"
  gcloud iam workload-identity-pools providers describe "${provider_id}" \
    --project="${project_id}" \
    --location=global \
    --workload-identity-pool="${pool_id}" \
    --format='value(state)' 2>/dev/null || echo ""
}

ensure_wif_oidc_provider() {
  local project_id="$1"
  local pool_id="$2"
  local provider_id="$3"
  local github_repo="$4"
  local state=""

  state="$(wif_provider_state "${project_id}" "${pool_id}" "${provider_id}")"
  case "${state}" in
    ACTIVE)
      echo "A WIF provider mar letezik es aktiv, kihagyva: ${provider_id}"
      ;;
    DELETED)
      echo "A WIF provider torolt allapotban van (soft-delete), visszaallitas: ${provider_id}"
      gcloud iam workload-identity-pools providers undelete "${provider_id}" \
        --project="${project_id}" \
        --location=global \
        --workload-identity-pool="${pool_id}"
      ;;
    "")
      echo "GitHub OIDC provider letrehozasa: ${provider_id}"
      retry_gcloud 12 gcloud iam workload-identity-pools providers create-oidc "${provider_id}" \
        --project="${project_id}" \
        --location=global \
        --workload-identity-pool="${pool_id}" \
        --display-name="GitHub Actions" \
        --issuer-uri="https://token.actions.githubusercontent.com" \
        --attribute-mapping="google.subject=assertion.sub,attribute.actor=assertion.actor,attribute.repository=assertion.repository" \
        --attribute-condition="assertion.repository == '${github_repo}'"
      ;;
    *)
      echo "Figyelem: WIF provider ismeretlen allapot (${state}): ${provider_id}"
      ;;
  esac
}
