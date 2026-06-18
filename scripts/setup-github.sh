#!/usr/bin/env bash
# GitHub Actions secrets beallitasa – setup-wif.sh utan
set -euo pipefail

PROJECT_ID="${GCP_PROJECT_ID:-${GOOGLE_CLOUD_PROJECT:-}}"
GITHUB_REPO="${GITHUB_REPO:-}"
POOL_ID="${WIF_POOL_ID:-contract-analyzer-pool}"
PROVIDER_ID="${WIF_PROVIDER_ID:-github-provider}"
CICD_SA="${CICD_SERVICE_ACCOUNT:-contract-analyzer-cicd-sa}"
AUTO_YES="${AUTO_YES:-false}"

usage() {
  cat <<'EOF'
Hasznalat:
  export GCP_PROJECT_ID=<a-gcp-projekt-id>
  export GITHUB_REPO=<szervezet>/<repo-nev>   # opcionalis, ha gh a cwd repot latja
  ./scripts/setup-github.sh [--yes]

Beallitja a deploy.yml altal hasznalt GitHub Actions secrets ertekeket.

Elofeltetelek:
  - setup-wif.sh mar lefutott (WIF + CI/CD SA)
  - gh CLI telepitve es bejelentkezve (gh auth login)
  - repo admin jogosultsag

Kornyezeti valtozok (felulirhatok, egyebkent automatikusan szamolva):
  GCP_WIF_PROVIDER           WIF provider teljes resource neve
  GCP_WIF_SERVICE_ACCOUNT    CI/CD service account e-mail

Kapcsolok:
  --yes           Megerosites nelkul
EOF
}

for arg in "$@"; do
  case "${arg}" in
    -h | --help)
      usage
      exit 0
      ;;
    -y | --yes)
      AUTO_YES=true
      ;;
    *)
      echo "Ismeretlen argumentum: ${arg}" >&2
      usage >&2
      exit 1
      ;;
  esac
done

if [[ -z "${PROJECT_ID}" ]]; then
  echo "Hiba: allitsd be a GCP_PROJECT_ID vagy GOOGLE_CLOUD_PROJECT kornyezeti valtozot." >&2
  exit 1
fi

if ! command -v gh >/dev/null 2>&1; then
  echo "Hiba: a gh CLI nincs telepitve. Telepites: https://cli.github.com/" >&2
  exit 1
fi

if ! gh auth status >/dev/null 2>&1; then
  echo "Hiba: nincs bejelentkezve a gh CLI-ba. Futtasd: gh auth login" >&2
  exit 1
fi

if [[ -z "${GITHUB_REPO}" ]]; then
  if GITHUB_REPO="$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null)"; then
    echo "Repository automatikusan felismerve: ${GITHUB_REPO}"
  else
    echo "Hiba: allitsd be a GITHUB_REPO kornyezeti valtozot (pl. export GITHUB_REPO=org/repo)." >&2
    exit 1
  fi
fi

echo "GCP projekt: ${PROJECT_ID}"
gcloud config set project "${PROJECT_ID}" >/dev/null

PROJECT_NUMBER="$(gcloud projects describe "${PROJECT_ID}" --format='value(projectNumber)')"
CICD_SA_EMAIL="${GCP_WIF_SERVICE_ACCOUNT:-${CICD_SA}@${PROJECT_ID}.iam.gserviceaccount.com}"
WIF_PROVIDER="${GCP_WIF_PROVIDER:-projects/${PROJECT_NUMBER}/locations/global/workloadIdentityPools/${POOL_ID}/providers/${PROVIDER_ID}}"

echo ""
echo "Repository: ${GITHUB_REPO}"
echo ""
echo "Beallitando secrets:"
echo "  GCP_PROJECT_ID=${PROJECT_ID}"
echo "  GCP_WIF_PROVIDER=${WIF_PROVIDER}"
echo "  GCP_WIF_SERVICE_ACCOUNT=${CICD_SA_EMAIL}"
echo ""

if [[ "${AUTO_YES}" != "true" ]]; then
  read -r -p "Folytatod a beallitast? [y/N] " confirm
  if [[ ! "${confirm}" =~ ^[yY]$ ]]; then
    echo "Megszakitva."
    exit 0
  fi
fi

set_github_secret() {
  local name="$1"
  local value="$2"
  echo "Secret beallitasa: ${name}"
  gh secret set "${name}" --repo "${GITHUB_REPO}" --app actions --body "${value}"
}

set_github_secret "GCP_PROJECT_ID" "${PROJECT_ID}"
set_github_secret "GCP_WIF_PROVIDER" "${WIF_PROVIDER}"
set_github_secret "GCP_WIF_SERVICE_ACCOUNT" "${CICD_SA_EMAIL}"

echo ""
echo "GitHub setup kesz: ${GITHUB_REPO}"
echo "Kovetkezo lepes: GitHub repoban PR nyitasa es merge a main branchre"
echo "  Ha a forraskodban nincs modositas, adj hozza egy-egy ures sort:"
echo "    backend/main.py"
echo "    frontend/src/App.jsx"
echo "  Pull requests -> New pull request -> Merge -> Actions -> Deploy"
