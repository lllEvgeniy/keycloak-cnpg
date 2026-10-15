# Keycloak

Локальный кластер k3d с Keycloak и PostgreSQL (CloudNativePG). Описание конфигурации: [apps/keycloak/config.json](apps/keycloak/config.json).

## Требования

Docker, kubectl, Helm 3, k3d 5.9, python3. Для трёх реплик Keycloak и трёх инстансов Postgres нужно около 12 ГБ свободной RAM.

## Запуск

```bash
./scripts/bootstrap.sh
```

Публичный URL: http://auth.127.0.0.1.sslip.io:8080

Админка открывается только с этой машины:

```bash
./scripts/open-admin.sh
```

Запрос `GET /admin` на публичном URL отвечает 403.

## Бэкап Postgres

```bash
./scripts/postgres-backup.sh backup
```

Перед восстановлением остановите Keycloak, иначе он пишет в базу во время `pg_restore`.

```bash
kubectl patch keycloak keycloak --namespace keycloak --type merge -p '{"spec":{"instances":0}}'
RESTORE_CONFIRM=yes ./scripts/postgres-backup.sh restore backups/<file>.dump
kubectl patch keycloak keycloak --namespace keycloak --type merge -p '{"spec":{"instances":3}}'
```

## Проверка манифестов

```bash
./scripts/lint.sh
```
