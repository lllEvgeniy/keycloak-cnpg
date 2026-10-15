#!/usr/bin/env bash
# Logical backup and restore of the Keycloak database on the CNPG primary.
set -euo pipefail

NAMESPACE="${NAMESPACE:-keycloak}"
CLUSTER="${CLUSTER:-keycloak-db}"
SECRET="${SECRET:-keycloak-db-app}"
BACKUP_DIR="${BACKUP_DIR:-backups}"

usage() {
  echo "Использование: $0 backup | restore <file.dump>" >&2
  exit 1
}

secret_key() {
  kubectl --namespace "$NAMESPACE" get secret "$SECRET" -o "jsonpath={.data.$1}" | base64 -d
}

current_primary() {
  local primary
  primary="$(kubectl --namespace "$NAMESPACE" get "clusters.postgresql.cnpg.io" "$CLUSTER" -o jsonpath='{.status.currentPrimary}')"
  if [[ -z "$primary" ]]; then
    echo "У кластера ${CLUSTER} нет status.currentPrimary." >&2
    exit 1
  fi
  printf '%s\n' "$primary"
}

do_backup() {
  local primary db out
  primary="$(current_primary)"
  db="$(secret_key dbname)"
  mkdir -p "$BACKUP_DIR"
  out="${BACKUP_DIR}/keycloak-$(date -u +%Y%m%dT%H%M%SZ).dump"
  if ! kubectl exec --namespace "$NAMESPACE" "$primary" -c postgres -- \
    pg_dump -Fc --no-owner --dbname="$db" >"$out"; then
    rm -f "$out"
    exit 1
  fi
  chmod 600 "$out"
  echo "Бэкап: ${out}"
  echo "Снят с primary ${primary}."
}

do_restore() {
  local dump="$1"
  local primary db user ready
  if [[ "${RESTORE_CONFIRM:-}" != "yes" ]]; then
    echo "Восстановление сотрёт объекты в базе. Запустите с RESTORE_CONFIRM=yes." >&2
    exit 1
  fi
  if [[ ! -f "$dump" ]]; then
    echo "Файл не найден: ${dump}" >&2
    exit 1
  fi
  ready="$(kubectl --namespace "$NAMESPACE" get pods -l app.kubernetes.io/component=server --no-headers 2>/dev/null | awk '$3 == "Running" { c++ } END { print c+0 }')"
  if [[ "$ready" -gt 0 && "${ALLOW_ONLINE_RESTORE:-}" != "yes" ]]; then
    echo "Keycloak ещё запущен и пишет в базу. Остановите его через CR и повторите:" >&2
    echo "  kubectl patch keycloak keycloak --namespace ${NAMESPACE} --type merge -p '{\"spec\":{\"instances\":0}}'" >&2
    echo "После восстановления верните три реплики:" >&2
    echo "  kubectl patch keycloak keycloak --namespace ${NAMESPACE} --type merge -p '{\"spec\":{\"instances\":3}}'" >&2
    exit 1
  fi
  primary="$(current_primary)"
  db="$(secret_key dbname)"
  user="$(secret_key username)"
  kubectl exec -i --namespace "$NAMESPACE" "$primary" -c postgres -- \
    pg_restore --clean --if-exists --no-owner --role="$user" --dbname="$db" --verbose <"$dump"
  echo "Восстановление на primary ${primary} завершено."
}

command="${1:-}"
case "$command" in
  backup)
    do_backup
    ;;
  restore)
    [[ $# -eq 2 ]] || usage
    do_restore "$2"
    ;;
  *)
    usage
    ;;
esac
