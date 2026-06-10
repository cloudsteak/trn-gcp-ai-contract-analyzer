#!/usr/bin/env bash
set -euo pipefail

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
gcloud services enable iam.googleapis.com iamcredentials.googleapis.com sts.googleapis.com cloudresourcemanager.googleapis.com

echo "CI/CD service account letrehozasa: ${CICD_SA}"
if gcloud iam service-accounts describe "${CICD_SA_EMAIL}" >/dev/null 2>&1; then
  echo "A CI/CD service account mar letezik, kihagyva."
else
  gcloud iam service-accounts create "${CICD_SA}" \
    --display-name="Contract Analyzer GitHub Actions Deploy"
fi

echo "Deploy jogosultsagok hozzarendelese a CI/CD service accounthoz..."
for role in \
  roles/run.admin \
  roles/cloudbuild.builds.editor \
  roles/artifactregistry.admin \
  roles/storage.admin \
  roles/serviceusage.serviceUsageConsumer; do
  gcloud projects add-iam-policy-binding "${PROJECT_ID}" \
    --member="serviceAccount:${CICD_SA_EMAIL}" \
    --role="${role}" \
    --condition=None
done

echo "Jogosultsag a futo Cloud Run service account hasznalatahoz..."
gcloud iam service-accounts add-iam-policy-binding "${RUNTIME_SA_EMAIL}" \
  --role="roles/iam.serviceAccountUser" \
  --member="serviceAccount:${CICD_SA_EMAIL}" \
  --condition=None 2>/dev/null || {
  echo "Figyelem: a ${RUNTIME_SA} meg nem letezik. Futtasd elobb a setup.sh-t, majd ujra ezt a scriptet."
}

echo "Workload Identity Pool letrehozasa: ${POOL_ID}"
if gcloud iam workload-identity-pools describe "${POOL_ID}" \
  --location=global >/dev/null 2>&1; then
  echo "A WIF pool mar letezik, kihagyva."
else
  gcloud iam workload-identity-pools create "${POOL_ID}" \
    --location=global \
    --display-name="Contract Analyzer GitHub Actions"
fi

echo "GitHub OIDC provider letrehozasa: ${PROVIDER_ID}"
if gcloud iam workload-identity-pools providers describe "${PROVIDER_ID}" \
  --location=global \
  --workload-identity-pool="${POOL_ID}" >/dev/null 2>&1; then
  echo "A WIF provider mar letezik, kihagyva."
else
  gcloud iam workload-identity-pools providers create-oidc "${PROVIDER_ID}" \
    --location=global \
    --workload-identity-pool="${POOL_ID}" \
    --display-name="GitHub Actions" \
    --issuer-uri="https://token.actions.githubusercontent.com" \
    --attribute-mapping="google.subject=assertion.sub,attribute.actor=assertion.actor,attribute.repository=assertion.repository" \
    --attribute-condition="assertion.repository == '${GITHUB_REPO}'"
fi

WIF_PROVIDER="projects/${PROJECT_NUMBER}/locations/global/workloadIdentityPools/${POOL_ID}/providers/${PROVIDER_ID}"
PRINCIPAL="principalSet://iam.googleapis.com/projects/${PROJECT_NUMBER}/locations/global/workloadIdentityPools/${POOL_ID}/attribute.repository/${GITHUB_REPO}"

echo "WIF hozzaferest kotve a CI/CD service accounthoz..."
gcloud iam service-accounts add-iam-policy-binding "${CICD_SA_EMAIL}" \
  --role="roles/iam.workloadIdentityUser" \
  --member="${PRINCIPAL}" \
  --condition=None

echo ""
echo "WIF setup kesz."
echo ""
echo "Allitsd be a kovetkezo GitHub Secrets-eket (Settings -> Secrets and variables -> Actions):"
echo ""
echo "  GCP_PROJECT_ID=${PROJECT_ID}"
echo "  GCP_WIF_PROVIDER=${WIF_PROVIDER}"
echo "  GCP_WIF_SERVICE_ACCOUNT=${CICD_SA_EMAIL}"
echo ""
echo "A JSON kulcs nem szukseges – a deploy.yml Workload Identity Federation-t hasznal."
