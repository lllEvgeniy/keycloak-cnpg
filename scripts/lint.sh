#!/usr/bin/env bash
# Same checks as ci/pr-validation.yaml, runnable on a laptop.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

manifests=(
  infra/k8s/namespace.yaml
  infra/k8s/cnpg/cluster.yaml
  infra/k8s/network/networkpolicy.yaml
  apps/keycloak/keycloak.yaml
  apps/keycloak/ingress.yaml
)
scripts=(
  scripts/bootstrap.sh
  scripts/open-admin.sh
  scripts/postgres-backup.sh
  scripts/lint.sh
)

python3 - "$ROOT" "${manifests[@]}" <<'PY'
import pathlib, sys
import yaml
root = pathlib.Path(sys.argv[1])
for name in sys.argv[2:]:
    docs = list(yaml.safe_load_all((root / name).read_text()))
    if not any(isinstance(doc, dict) and doc.get("kind") for doc in docs):
        raise SystemExit(f"{name}: no Kubernetes objects")
    print(f"yaml ok {name}")
PY

run_shellcheck() {
  if command -v shellcheck >/dev/null 2>&1; then
    shellcheck "${scripts[@]}"
    return
  fi
  docker run --rm -v "${ROOT}:/work" -w /work --entrypoint shellcheck koalaman/shellcheck-alpine:v0.11.0 \
    "${scripts[@]}"
}

run_kubeconform() {
  if command -v kubeconform >/dev/null 2>&1; then
    kubeconform -strict -summary -ignore-missing-schemas "${manifests[@]}"
    return
  fi
  docker run --rm -v "${ROOT}:/work" -w /work ghcr.io/yannh/kubeconform:v0.7.0 \
    -strict -summary -ignore-missing-schemas "${manifests[@]}"
}

run_checkov() {
  local args=(
    -f infra/k8s/namespace.yaml
    -f infra/k8s/cnpg/cluster.yaml
    -f infra/k8s/network/networkpolicy.yaml
    -f apps/keycloak/keycloak.yaml
    -f apps/keycloak/ingress.yaml
    --framework kubernetes
    --compact
    --quiet
  )
  if command -v checkov >/dev/null 2>&1; then
    checkov "${args[@]}"
    return
  fi
  docker run --rm -v "${ROOT}:/work" -w /work bridgecrew/checkov:3.2.472 \
    -f infra/k8s/namespace.yaml \
    -f infra/k8s/cnpg/cluster.yaml \
    -f infra/k8s/network/networkpolicy.yaml \
    -f apps/keycloak/keycloak.yaml \
    -f apps/keycloak/ingress.yaml \
    --framework kubernetes \
    --compact \
    --quiet
}

run_shellcheck
run_kubeconform
run_checkov
