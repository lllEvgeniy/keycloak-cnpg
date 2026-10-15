# Что сделано и почему

Стенд закрывает условие тестового: Keycloak в Kubernetes, база через CNPG, админка недоступна обычным пользователям, бэкап и восстановление Postgres скриптом. Кластер локальный, его можно поднять по [README.md](README.md). Версии и параметры продублированы в [apps/keycloak/config.json](apps/keycloak/config.json). Источник правды для Kubernetes — манифесты.

## Что развёрнуто

- k3d: 1 server и 3 agent, Kubernetes v1.35.9, снаружи только порт `8080`.
- Calico v3.33.0. Pod CIDR `10.42.0.0/16`, внутри Docker используется VXLAN.
- CloudNativePG 1.30.1 (Helm-чарт 0.29.1). Кластер `keycloak-db`: PostgreSQL 17.11, 3 инстанса, одна синхронная реплика.
- Keycloak Operator 26.8.1 и Keycloak CR на 3 реплики. База — сервис `keycloak-db-rw`.
- Публичный URL `http://auth.127.0.0.1.sslip.io:8080`. Путь `/admin` отвечает 403.
- Админ-консоль на `http://127.0.0.1:9090`, её открывает `scripts/open-admin.sh`.
- `scripts/postgres-backup.sh`: `backup` и `restore` только с primary.
- Пароли создаются в кластере и в git не попадают.

## Почему операторы

Keycloak и PostgreSQL поставлены своими операторами, а не самодельным Deployment и не сторонним чартом.

CloudNativePG сам выбирает primary и переключает его, если под пропал. Keycloak Operator сам собирает StatefulSet, Service и пробы. В репозитории остаются CR и параметры, а жизненный цикл остаётся у того, кто его поддерживает. Отдельный Helm-чарт Keycloak здесь только спрятал бы те же объекты.

Версии закреплены: Keycloak 26.8.1, чарт CNPG 0.29.1, образ `ghcr.io/cloudnative-pg/postgresql:17.11-system-trixie`.

## Почему три реплики и одна синхронная

Три пода Keycloak и три инстанса Postgres разложены по трём agent-нодам. У Keycloak spread по `kubernetes.io/hostname` с `DoNotSchedule`. У CNPG required anti-affinity по той же метке. Server-нода с taint, на неё рабочие поды не садятся.

У Postgres режим `synchronous.method: any`, `number: 1`, `dataDurability: required`. Это актуальная форма `minSyncReplicas: 1` и `maxSyncReplicas: 1` в CNPG 1.30. Подтверждённая запись дожидается одного standby, поэтому потеря одного пода не забирает уже зафиксированные данные. Третий инстанс остаётся запасным. Две обязательные синхронные реплики остановили бы запись при падении любого пода.

Репликация закрывает отказ ноды. Она не закрывает `DROP` и порчу строк. Для этого рядом лежит отдельный бэкап.

## Почему бэкап — скрипт, а не Barman

Условие просит shell-скрипт. `scripts/postgres-backup.sh` делает логический дамп так, как это описывает сам CNPG для аварийного случая:

- primary берётся из `status.currentPrimary`, не с реплики;
- `pg_dump -Fc` пишет файл `backups/keycloak-<timestamp>.dump` с правами `600`;
- имя базы и роль читаются из Secret `keycloak-db-app`, пароль в вывод не попадает;
- `restore` запускается только с `RESTORE_CONFIRM=yes` и делает `pg_restore --clean --if-exists --no-owner --role=<пользователь приложения>`.

Перед восстановлением Keycloak останавливается через CR:

```bash
kubectl patch keycloak keycloak --namespace keycloak --type merge -p '{"spec":{"instances":0}}'
```

`kubectl scale` StatefulSet здесь не подходит: оператор видит `spec.instances: 3` и сразу возвращает три реплики. После `pg_restore` instances возвращают на 3.

Физический backup в object storage на этом стенде не подключён. Локально нет S3, а начиная с CNPG 1.26 встроенный Barman выносится из ядра оператора в плагин. Для настоящего DR следующим шагом был бы Barman Cloud Plugin. Логический дамп этот шаг не заменяет, он закрывает требование тестового.

## Почему админка закрыта на прокси

Обычный пользователь ходит на публичный hostname. Админ-консоль смотрит на другой адрес:

- `hostname`: `http://auth.127.0.0.1.sslip.io:8080`
- `hostname-admin`: `http://127.0.0.1:9090`

Этого недостаточно. Документация Keycloak прямо говорит, что `hostname-admin` не запрещает Administration REST API на публичном URL. Поэтому Traefik режет путь до пода. IngressRoute с priority 100 на `PathPrefix(/admin)` висит на middleware `ipAllowList` с адресом `192.0.2.1/32`. Это TEST-NET из RFC 5737, реального клиента с таким адресом нет, Traefik отвечает 403. Account console и OIDC этот маршрут не затрагивает.

Консоль открывается так: `scripts/open-admin.sh` делает `kubectl port-forward` на `127.0.0.1:9090`. С публичного URL этот адрес не работает.

Роли `admin` и `realm-admin` обычным пользователям не выдаются. Это второй слой. Основной замок стоит на входе: роль не мешает вызвать API, если путь открыт.

## Почему секреты выглядят именно так

Пароль приложения создаёт CNPG в Secret `keycloak-db-app`. В манифесте его нет.

Пароль администратора один раз создаёт `scripts/bootstrap.sh` в Secret `keycloak-bootstrap-admin` и печатает его в терминал. Имя специально не `keycloak-initial-admin`: это имя оператор резервирует за собой и пытается создать сам. Если положить туда свой Secret заранее, reconcile падает с `already exists`.

## Почему k3d и Calico

Условие — Kubernetes, Helm и манифесты. Облако и Terraform в него не входят, только локальный кластер.

Flannel в k3s не применяет NetworkPolicy, поэтому CNI — Calico. В namespace `keycloak` стоит default-deny на ingress:

- на порт 8080 Keycloak ходит только Traefik;
- на порт 5432 Postgres ходят свои поды и Keycloak;
- порт 8000 CNPG открыт оператору и kubelet, иначе пробы и reconcile ломаются;
- порт 9000 Keycloak открыт kubelet для проб и в Ingress не публикуется.

На Docker-bridge k3d оставлен VXLAN. IPIP там теряет пакеты из-за checksum offload.

## Почему ресурсы меньше боевых

В манифестах лабораторный профиль: Keycloak request 250m / 768Mi, limit 1 CPU / 1536Mi; Postgres request 100m / 256Mi, limit 500m / 768Mi. У обоих есть liveness и readiness. У Keycloak периоды заданы в CR, HTTP-пробы на порту 9000 рисует оператор. У CNPG HTTP-пробы на порту 8000 тоже рисует оператор: в CR Cluster отдельных полей probe нет.

Боевой профиль из гайда Keycloak HA — около 2 CPU и 1250Mi запроса на под, limit около 6 CPU и 2250Mi. Три таких пода плюс три Postgres на ноутбук не садятся. Эти цифры записаны в `apps/keycloak/config.json`, в поле `keycloak.resources.production`.


