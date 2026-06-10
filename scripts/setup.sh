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

echo "Szukseges API-k engedelyezese..."
gcloud services enable run.googleapis.com aiplatform.googleapis.com cloudbuild.googleapis.com

echo "Service account letrehozasa: ${SERVICE_ACCOUNT}"
if gcloud iam service-accounts describe "${SA_EMAIL}" >/dev/null 2>&1; then
  echo "A service account mar letezik, kihagyva."
else
  gcloud iam service-accounts create "${SERVICE_ACCOUNT}" \
    --display-name="Contract Analyzer Service Account"
fi

echo "IAM szerepkorok hozzarendelese a service accounthoz..."
gcloud projects add-iam-policy-binding "${PROJECT_ID}" \
  --member="serviceAccount:${SA_EMAIL}" \
  --role="roles/run.invoker" \
  --condition=None

gcloud projects add-iam-policy-binding "${PROJECT_ID}" \
  --member="serviceAccount:${SA_EMAIL}" \
  --role="roles/aiplatform.user" \
  --condition=None

echo "Cloud Run backend service letrehozasa placeholder image-dzsel..."
if gcloud run services describe "${BACKEND_SERVICE}" --region="${REGION}" >/dev/null 2>&1; then
  echo "A backend service mar letezik, kihagyva."
else
  gcloud run deploy "${BACKEND_SERVICE}" \
    --image="gcr.io/cloudrun/hello" \
    --region="${REGION}" \
    --platform=managed \
    --allow-unauthenticated \
    --service-account="${SA_EMAIL}" \
    --quiet
fi

echo "Cloud Run frontend service letrehozasa placeholder image-dzsel..."
if gcloud run services describe "${FRONTEND_SERVICE}" --region="${REGION}" >/dev/null 2>&1; then
  echo "A frontend service mar letezik, kihagyva."
else
  gcloud run deploy "${FRONTEND_SERVICE}" \
    --image="gcr.io/cloudrun/hello" \
    --region="${REGION}" \
    --platform=managed \
    --allow-unauthenticated \
    --service-account="${SA_EMAIL}" \
    --quiet
fi

echo "Backend kornyezeti valtozok beallitasa..."
gcloud run services update "${BACKEND_SERVICE}" \
  --region="${REGION}" \
  --service-account="${SA_EMAIL}" \
  --set-env-vars="GEMINI_MODEL=gemini-3.1-flash-lite,GCP_PROJECT_ID=${PROJECT_ID},GEMINI_LOCATION=global,CORS_ORIGINS=*"

echo "Frontend kornyezeti valtozok beallitasa..."
BACKEND_URL="$(gcloud run services describe "${BACKEND_SERVICE}" --region="${REGION}" --format='value(status.url)')"
gcloud run services update "${FRONTEND_SERVICE}" \
  --region="${REGION}" \
  --service-account="${SA_EMAIL}" \
  --set-env-vars="VITE_API_URL=${BACKEND_URL}"

echo "Setup kesz."
echo "Backend URL: ${BACKEND_URL}"
FRONTEND_URL="$(gcloud run services describe "${FRONTEND_SERVICE}" --region="${REGION}" --format='value(status.url)')"
echo "Frontend URL: ${FRONTEND_URL}"
echo ""
echo "Kovetkezo lepes: GitHub Actions WIF beallitasa (JSON kulcs nelkul):"
echo "  export GITHUB_REPO=<szervezet>/<repo-nev>"
echo "  ./scripts/setup-wif.sh"
