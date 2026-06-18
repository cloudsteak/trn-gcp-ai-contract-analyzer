#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

PROJECT_ID="${GCP_PROJECT_ID:-${GOOGLE_CLOUD_PROJECT:-}}"
GITHUB_REPO="${GITHUB_REPO:-}"
POOL_ID="${WIF_POOL_ID:-contract-analyzer-pool}"
PROVIDER_ID="${WIF_PROVIDER_ID:-github-provider}"
CICD_SA="${CICD_SERVICE_ACCOUNT:-contract-analyzer-cicd-sa}"
RUNTIME_SA="${SERVICE_ACCOUNT:-contract-analyzer-sa}"
CICD_SA_EMAIL="${CICD_SA}@${PROJECT_ID}.iam.gserviceaccount.com"
RUNTIME_SA_EMAIL="${RUNTIME_SA}@${PROJECT_ID}.iam.gserviceaccount.com"

if [[ -z "${PROJECT_ID}" ]]; then
  echo "Hiba: allitsd be a GCP_PROJECT_ID vagy GOOGLE_CLOUD_PROJECT kornyezeti valtozot."
  exit 1
fi

if [[ -z "${GITHUB_REPO}" ]]; then
  echo "Hiba: allitsd be a GITHUB_REPO kornyezeti valtozot (pl. szervezet/repo-nev)."
  exit 1
fi

echo "GCP projekt beallitasa: ${PROJECT_ID}"
gcloud config set project "${PROJECT_ID}"

PROJECT_NUMBER="$(gcloud projects describe "${PROJECT_ID}" --format='value(projectNumber)')"

echo "Szukseges API-k engedelyezese WIF-hez..."
gcloud services enable \
  iam.googleapis.com \
  iamcredentials.googleapis.com \
  sts.googleapis.com \
  cloudresourcemanager.googleapis.com \
  cloudbuild.googleapis.com \
  artifactregistry.googleapis.com

echo "CI/CD service account letrehozasa: ${CICD_SA}"
if gcloud iam service-accounts describe "${CICD_SA_EMAIL}" >/dev/null 2>&1; then
  echo "A CI/CD service account mar letezik, kihagyva."
else
  gcloud iam service-accounts create "${CICD_SA}" \
    --display-name="Contract Analyzer GitHub Actions Deploy"
fi

wait_for_service_account "${CICD_SA_EMAIL}"

COMPUTE_SA="${PROJECT_NUMBER}-compute@developer.gserviceaccount.com"
CLOUDBUILD_SA="${PROJECT_NUMBER}@cloudbuild.gserviceaccount.com"

echo "Deploy jogosultsagok hozzarendelese a CI/CD service accounthoz..."
for role in \
  roles/run.sourceDeveloper \
  roles/run.builder \
  roles/cloudbuild.builds.builder \
  roles/artifactregistry.writer \
  roles/storage.objectAdmin \
  roles/logging.logWriter \
  roles/serviceusage.serviceUsageConsumer; do
  add_project_iam_binding "${PROJECT_ID}" "serviceAccount:${CICD_SA_EMAIL}" "${role}"
done

echo "CI/CD service account onmagat hasznalhatja build service accountkent..."
add_sa_iam_binding "${CICD_SA_EMAIL}" "serviceAccount:${CICD_SA_EMAIL}" "roles/iam.serviceAccountUser"

echo "CI/CD service account hasznalhatja az alap Cloud Build / Compute accountokat..."
for BUILD_SA in "${CLOUDBUILD_SA}" "${COMPUTE_SA}"; do
  if gcloud iam service-accounts describe "${BUILD_SA}" >/dev/null 2>&1; then
    add_sa_iam_binding "${BUILD_SA}" "serviceAccount:${CICD_SA_EMAIL}" "roles/iam.serviceAccountUser"
  fi
done

echo "Cloud Build service account deployolhat a futo Cloud Run service accounttal..."
if gcloud iam service-accounts describe "${CLOUDBUILD_SA}" >/dev/null 2>&1; then
  add_project_iam_binding "${PROJECT_ID}" "serviceAccount:${CLOUDBUILD_SA}" "roles/run.builder"
  if gcloud iam service-accounts describe "${RUNTIME_SA_EMAIL}" >/dev/null 2>&1; then
    add_sa_iam_binding "${RUNTIME_SA_EMAIL}" "serviceAccount:${CLOUDBUILD_SA}" "roles/iam.serviceAccountUser"
  else
    echo "Figyelem: a ${RUNTIME_SA} meg nem letezik. Futtasd elobb a setup.sh-t, majd ujra ezt a scriptet."
  fi
fi

echo "Jogosultsag a futo Cloud Run service account hasznalatahoz..."
if gcloud iam service-accounts describe "${RUNTIME_SA_EMAIL}" >/dev/null 2>&1; then
  add_sa_iam_binding "${RUNTIME_SA_EMAIL}" "serviceAccount:${CICD_SA_EMAIL}" "roles/iam.serviceAccountUser"
else
  echo "Figyelem: a ${RUNTIME_SA} meg nem letezik. Futtasd elobb a setup.sh-t, majd ujra ezt a scriptet."
fi

ensure_wif_pool "${PROJECT_ID}" "${POOL_ID}" "Contract Analyzer GitHub Actions"
ensure_wif_oidc_provider "${PROJECT_ID}" "${POOL_ID}" "${PROVIDER_ID}" "${GITHUB_REPO}"

WIF_PROVIDER="projects/${PROJECT_NUMBER}/locations/global/workloadIdentityPools/${POOL_ID}/providers/${PROVIDER_ID}"
PRINCIPAL="principalSet://iam.googleapis.com/projects/${PROJECT_NUMBER}/locations/global/workloadIdentityPools/${POOL_ID}/attribute.repository/${GITHUB_REPO}"

echo "WIF hozzaferest kotve a CI/CD service accounthoz..."
add_sa_iam_binding "${CICD_SA_EMAIL}" "${PRINCIPAL}" "roles/iam.workloadIdentityUser"

echo ""
echo "WIF setup kesz."
echo ""
echo "Kornyezeti valtozok (masold be vagy futtasd):"
echo ""
echo "export GCP_PROJECT_ID=${PROJECT_ID}"
echo "export GITHUB_REPO=${GITHUB_REPO}"
echo "export WIF_POOL_ID=${POOL_ID}"
echo "export WIF_PROVIDER_ID=${PROVIDER_ID}"
echo "export CICD_SERVICE_ACCOUNT=${CICD_SA}"
echo "export SERVICE_ACCOUNT=${RUNTIME_SA}"
echo "export GCP_WIF_PROVIDER=${WIF_PROVIDER}"
echo "export GCP_WIF_SERVICE_ACCOUNT=${CICD_SA_EMAIL}"
echo ""
echo "GitHub Secrets (Settings -> Secrets and variables -> Actions):"
echo ""
echo "  GCP_PROJECT_ID=${PROJECT_ID}"
echo "  GCP_WIF_PROVIDER=${WIF_PROVIDER}"
echo "  GCP_WIF_SERVICE_ACCOUNT=${CICD_SA_EMAIL}"
echo ""
echo "A JSON kulcs nem szukseges – a deploy.yml Workload Identity Federation-t hasznal."
echo ""
echo "Kovetkezo lepes (GitHub secrets, gh CLI):"
echo "  ./scripts/setup-github.sh"
echo ""
echo "Teardown (demo ujrainditashoz, forditott sorrendben):"
echo "  ./scripts/teardown.sh"
echo "  ./scripts/teardown-wif.sh"
echo "  ./scripts/teardown-github.sh"
