#!/usr/bin/env bash
# Create the local cluster and install CNPG, Keycloak, and the edge rules.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
export PATH="${HOME}/.local/bin:${PATH}"

CLUSTER="keycloak"
NAMESPACE="keycloak"
CNPG_CHART_VERSION="0.29.1"
KEYCLOAK_REF="26.8.1"

need() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Не найдено в PATH: $1" >&2
    exit 1
  fi
}

need docker
need kubectl
need helm
need k3d

if ! k3d cluster list 2>/dev/null | awk 'NR > 1 { print $1 }' | grep -qx "$CLUSTER"; then
  k3d cluster create --config infra/k8s/cluster.yaml \
    --volume "${ROOT}/infra/k8s/cni-calico.yaml:/var/lib/rancher/k3s/server/manifests/cni-calico.yaml@server:0"
fi

kubectl config use-context "k3d-${CLUSTER}"
kubectl wait --for=condition=Ready nodes --all --timeout=300s

helm repo add cnpg https://cloudnative-pg.github.io/charts --force-update
helm repo update cnpg
helm upgrade --install cnpg cnpg/cloudnative-pg \
  --version "$CNPG_CHART_VERSION" \
  --namespace cnpg-system \
  --create-namespace \
  --values infra/k8s/cnpg/operator-values.yaml \
  --wait \
  --timeout 10m

kubectl apply -f infra/k8s/namespace.yaml
kubectl apply -k "https://github.com/keycloak/keycloak-k8s-resources/kubernetes?ref=${KEYCLOAK_REF}"
kubectl --namespace "$NAMESPACE" rollout status deployment/keycloak-operator --timeout=300s

# The operator creates "<name>-initial-admin" itself. A custom name must be
# different, otherwise the operator tries to create the same Secret and fails.
if ! kubectl --namespace "$NAMESPACE" get secret keycloak-bootstrap-admin >/dev/null 2>&1; then
  password="$(python3 -c 'import secrets; print(secrets.token_urlsafe(18))')"
  kubectl --namespace "$NAMESPACE" create secret generic keycloak-bootstrap-admin \
    --from-literal=username=admin \
    --from-literal=password="$password"
  echo "Keycloak admin username: admin"
  echo "Keycloak admin password: ${password}"
  echo "Пароль записан только в Secret keycloak-bootstrap-admin."
else
  echo "Secret keycloak-bootstrap-admin уже есть, пароль повторно не печатаю."
fi

kubectl apply -f infra/k8s/network/networkpolicy.yaml
kubectl apply -f infra/k8s/cnpg/cluster.yaml
kubectl wait --namespace "$NAMESPACE" --for=condition=Ready "cluster/keycloak-db" --timeout=15m

kubectl apply -f apps/keycloak/keycloak.yaml
kubectl apply -f apps/keycloak/ingress.yaml
for _ in $(seq 1 60); do
  if kubectl --namespace "$NAMESPACE" get statefulset/keycloak >/dev/null 2>&1; then
    break
  fi
  sleep 5
done
kubectl --namespace "$NAMESPACE" rollout status statefulset/keycloak --timeout=15m

echo "Публичный URL: http://auth.127.0.0.1.sslip.io:8080"
echo "Админка: ./scripts/open-admin.sh"
