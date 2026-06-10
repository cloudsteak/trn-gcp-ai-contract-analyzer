#!/usr/bin/env bash
set -euo pipefail

PROJECT_ID="${GCP_PROJECT_ID:-${GOOGLE_CLOUD_PROJECT:-}}"
REGION="${GCP_REGION:-europe-west1}"
BACKEND_SERVICE="${BACKEND_SERVICE:-contract-analyzer-backend}"
FRONTEND_SERVICE="${FRONTEND_SERVICE:-contract-analyzer-frontend}"
SERVICE_ACCOUNT="${SERVICE_ACCOUNT:-contract-analyzer-sa}"
SA_EMAIL="${SERVICE_ACCOUNT}@${PROJECT_ID}.iam.gserviceaccount.com"

if [[ -z "${PROJECT_ID}" ]]; then
  echo "Hiba: allitsd be a GCP_PROJECT_ID vagy GOOGLE_CLOUD_PROJECT kornyezeti valtozot."
  exit 1
fi

echo "GCP projekt beallitasa: ${PROJECT_ID}"
gcloud config set project "${PROJECT_ID}"

echo "Cloud Run backend service torlese..."
if gcloud run services describe "${BACKEND_SERVICE}" --region="${REGION}" >/dev/null 2>&1; then
  gcloud run services delete "${BACKEND_SERVICE}" --region="${REGION}" --quiet
else
  echo "A backend service nem letezik, kihagyva."
fi

echo "Cloud Run frontend service torlese..."
if gcloud run services describe "${FRONTEND_SERVICE}" --region="${REGION}" >/dev/null 2>&1; then
  gcloud run services delete "${FRONTEND_SERVICE}" --region="${REGION}" --quiet
else
  echo "A frontend service nem letezik, kihagyva."
fi

echo "Service account IAM koteseinek torlese..."
for role in roles/run.invoker roles/aiplatform.user; do
  gcloud projects remove-iam-policy-binding "${PROJECT_ID}" \
    --member="serviceAccount:${SA_EMAIL}" \
    --role="${role}" \
    --quiet || true
done

echo "Service account torlese..."
if gcloud iam service-accounts describe "${SA_EMAIL}" >/dev/null 2>&1; then
  gcloud iam service-accounts delete "${SA_EMAIL}" --quiet
else
  echo "A service account nem letezik, kihagyva."
fi

echo "Teardown kesz."
