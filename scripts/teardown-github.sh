#!/usr/bin/env bash
# GitHub Actions secrets es pipeline workflow run history torlese – a setup-github.sh altal beallitott ertekek
set -euo pipefail

GITHUB_REPO="${GITHUB_REPO:-}"
AUTO_YES="${AUTO_YES:-false}"

GITHUB_SECRETS=(
  GCP_PROJECT_ID
  GCP_WIF_PROVIDER
  GCP_WIF_SERVICE_ACCOUNT
  # Regi / alternativ nevek
  GCP_WORKLOAD_IDENTITY_PROVIDER
  GCP_SERVICE_ACCOUNT
)

# A CI/CD pipeline workflow-k (deploy + lint)
GITHUB_WORKFLOWS=(
  deploy.yml
  lint.yml
)

usage() {
  cat <<'EOF'
Hasznalat:
  export GITHUB_REPO=<szervezet>/<repo-nev>   # opcionalis, ha gh a cwd repot latja
  ./scripts/teardown-github.sh [--yes]

Torli a setup-github.sh altal beallitott GitHub Actions secrets ertekeket,
es uriteti a pipeline (deploy + lint) workflow run history-t.

Elofeltetelek:
  - gh CLI telepitve es bejelentkezve (gh auth login)
  - repo admin jogosultsag a secrets es workflow run torleshez

Kornyezeti valtozok:
  GITHUB_REPO   Cel repository (pl. cloudsteak/trn-gcp-ai-contract-analyzer)
  AUTO_YES=true Ugyanaz, mint a --yes kapcsolo (nem interaktiv megerosites)
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

EXISTING_SECRETS=()
while IFS= read -r line; do
  [[ -n "${line}" ]] && EXISTING_SECRETS+=("${line}")
done < <(gh secret list --repo "${GITHUB_REPO}" --app actions --json name -q '.[].name' 2>/dev/null || true)

secret_exists() {
  local name="$1"
  local item
  if [[ ${#EXISTING_SECRETS[@]} -eq 0 ]]; then
    return 1
  fi
  for item in "${EXISTING_SECRETS[@]}"; do
    [[ "${item}" == "${name}" ]] && return 0
  done
  return 1
}

SECRETS_TO_DELETE=()

for name in "${GITHUB_SECRETS[@]}"; do
  if secret_exists "${name}"; then
    SECRETS_TO_DELETE+=("${name}")
  fi
done

count_workflow_runs() {
  local workflow="$1"
  gh run list --repo "${GITHUB_REPO}" -w "${workflow}" \
    --json databaseId -q 'length' -L 1000 2>/dev/null || echo 0
}

delete_workflow_runs() {
  local workflow="$1"
  local deleted=0

  while true; do
    local batch_deleted=0

    while IFS= read -r run_id; do
      [[ -z "${run_id}" ]] && continue
      echo "Workflow run torlese: ${workflow} #${run_id}"
      if gh run delete "${run_id}" --repo "${GITHUB_REPO}"; then
        deleted=$((deleted + 1))
        batch_deleted=$((batch_deleted + 1))
      fi
    done < <(
      gh run list --repo "${GITHUB_REPO}" -w "${workflow}" \
        --json databaseId -q '.[].databaseId' -L 100 2>/dev/null || true
    )

    if [[ "${batch_deleted}" -eq 0 ]]; then
      break
    fi
  done

  echo "${workflow}: ${deleted} run torolve."
}

WORKFLOW_RUN_COUNTS=()
TOTAL_RUNS=0

for workflow in "${GITHUB_WORKFLOWS[@]}"; do
  count="$(count_workflow_runs "${workflow}")"
  WORKFLOW_RUN_COUNTS+=("${workflow}:${count}")
  TOTAL_RUNS=$((TOTAL_RUNS + count))
done

if [[ ${#SECRETS_TO_DELETE[@]} -eq 0 && "${TOTAL_RUNS}" -eq 0 ]]; then
  echo "Nincs torlendo GitHub secret vagy pipeline workflow run a ${GITHUB_REPO} repoban."
  exit 0
fi

echo "Repository: ${GITHUB_REPO}"
echo ""

if [[ ${#SECRETS_TO_DELETE[@]} -gt 0 ]]; then
  echo "Torlendo secrets (${#SECRETS_TO_DELETE[@]}):"
  printf '  - %s\n' "${SECRETS_TO_DELETE[@]}"
  echo ""
fi

if [[ "${TOTAL_RUNS}" -gt 0 ]]; then
  echo "Torlendo pipeline workflow run-ok (${TOTAL_RUNS} osszesen):"
  for entry in "${WORKFLOW_RUN_COUNTS[@]}"; do
    workflow="${entry%%:*}"
    count="${entry##*:}"
    if [[ "${count}" -gt 0 ]]; then
      printf '  - %s (%s run)\n' "${workflow}" "${count}"
    fi
  done
  echo ""
fi

if [[ "${AUTO_YES}" != "true" ]]; then
  read -r -p "Folytatod a torlest? [y/N] " confirm
  if [[ ! "${confirm}" =~ ^[yY]$ ]]; then
    echo "Megszakitva."
    exit 0
  fi
fi

for name in "${SECRETS_TO_DELETE[@]+"${SECRETS_TO_DELETE[@]}"}"; do
  echo "Secret torlese: ${name}"
  gh secret delete "${name}" --repo "${GITHUB_REPO}" --app actions
done

if [[ "${TOTAL_RUNS}" -gt 0 ]]; then
  echo ""
  echo "Pipeline workflow run history uritese..."
  for workflow in "${GITHUB_WORKFLOWS[@]}"; do
    delete_workflow_runs "${workflow}"
  done
fi

echo ""
echo "GitHub teardown kesz: ${GITHUB_REPO}"
