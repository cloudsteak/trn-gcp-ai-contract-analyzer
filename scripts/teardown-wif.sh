#!/usr/bin/env bash
set -euo pipefail

PROJECT_ID="${GCP_PROJECT_ID:-${GOOGLE_CLOUD_PROJECT:-}}"
GITHUB_REPO="${GITHUB_REPO:-}"
POOL_ID="${WIF_POOL_ID:-contract-analyzer-pool}"
PROVIDER_ID="${WIF_PROVIDER_ID:-github-provider}"
CICD_SA="${CICD_SERVICE_ACCOUNT:-contract-analyzer-cicd-sa}"
CICD_SA_EMAIL="${CICD_SA}@${PROJECT_ID}.iam.gserviceaccount.com"

if [[ -z "${PROJECT_ID}" ]]; then
  echo "Hiba: allitsd be a GCP_PROJECT_ID vagy GOOGLE_CLOUD_PROJECT kornyezeti valtozot."
  exit 1
fi

echo "GCP projekt beallitasa: ${PROJECT_ID}"
gcloud config set project "${PROJECT_ID}"

PROJECT_NUMBER="$(gcloud projects describe "${PROJECT_ID}" --format='value(projectNumber)')"

if [[ -n "${GITHUB_REPO}" ]] && gcloud iam service-accounts describe "${CICD_SA_EMAIL}" >/dev/null 2>&1; then
  echo "WIF kotés torlese a CI/CD service accountrol..."
  PRINCIPAL="principalSet://iam.googleapis.com/projects/${PROJECT_NUMBER}/locations/global/workloadIdentityPools/${POOL_ID}/attribute.repository/${GITHUB_REPO}"
  gcloud iam service-accounts remove-iam-policy-binding "${CICD_SA_EMAIL}" \
    --role="roles/iam.workloadIdentityUser" \
    --member="${PRINCIPAL}" \
    --quiet || true
fi

echo "WIF provider torlese..."
gcloud iam workload-identity-pools providers delete "${PROVIDER_ID}" \
  --location=global \
  --workload-identity-pool="${POOL_ID}" \
  --quiet 2>/dev/null || echo "A provider nem letezik, kihagyva."

echo "WIF pool torlese..."
gcloud iam workload-identity-pools delete "${POOL_ID}" \
  --location=global \
  --quiet 2>/dev/null || echo "A pool nem letezik, kihagyva."

echo "CI/CD service account IAM koteseinek torlese..."
for role in \
  roles/run.sourceDeveloper \
  roles/run.builder \
  roles/cloudbuild.builds.builder \
  roles/artifactregistry.writer \
  roles/storage.objectAdmin \
  roles/logging.logWriter \
  roles/serviceusage.serviceUsageConsumer; do
  gcloud projects remove-iam-policy-binding "${PROJECT_ID}" \
    --member="serviceAccount:${CICD_SA_EMAIL}" \
    --role="${role}" \
    --quiet || true
done

echo "CI/CD service account torlese..."
if gcloud iam service-accounts describe "${CICD_SA_EMAIL}" >/dev/null 2>&1; then
  gcloud iam service-accounts delete "${CICD_SA_EMAIL}" --quiet
else
  echo "A CI/CD service account nem letezik, kihagyva."
fi

echo "WIF teardown kesz."
