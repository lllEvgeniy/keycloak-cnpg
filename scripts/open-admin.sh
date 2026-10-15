#!/usr/bin/env bash
# Port-forward the admin hostname. The public ingress answers 403 on /admin.
set -euo pipefail

NAMESPACE="${NAMESPACE:-keycloak}"
LOCAL_PORT="${LOCAL_PORT:-9090}"
SERVICE="${SERVICE:-keycloak-service}"

if ! kubectl --namespace "$NAMESPACE" get secret keycloak-bootstrap-admin >/dev/null 2>&1; then
  echo "Secret keycloak-bootstrap-admin не найден. Сначала запустите scripts/bootstrap.sh." >&2
  exit 1
fi

username="$(kubectl --namespace "$NAMESPACE" get secret keycloak-bootstrap-admin -o jsonpath='{.data.username}' | base64 -d)"
password="$(kubectl --namespace "$NAMESPACE" get secret keycloak-bootstrap-admin -o jsonpath='{.data.password}' | base64 -d)"

echo "Admin console: http://127.0.0.1:${LOCAL_PORT}/admin"
echo "Username: ${username}"
echo "Password: ${password}"
echo "Остановка: Ctrl-C"
exec kubectl --namespace "$NAMESPACE" port-forward "svc/${SERVICE}" "${LOCAL_PORT}:8080"
