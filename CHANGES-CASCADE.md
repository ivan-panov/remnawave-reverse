# 3.0.11

- Исправлена ложная ошибка VLESS-каскада после успешного `profile-modification`: некоторые версии Remnawave отвечают на bulk-action пустым телом/204 No Content.
- После назначения Config Profile скрипт теперь проверяет фактическое состояние ноды через `/api/nodes/{uuid}` и ждёт до 2.5 секунд асинхронного применения.
- Непустые API-ошибки `profile-modification` теперь выводятся непосредственно, а rollback выполняется только если назначение действительно не подтвердилось.
- Локальные API-запросы теперь передают корректный `X-Forwarded-For: 127.0.0.1` вместо URL/порта в этом заголовке.

# 3.0.10

- Проведён полный статический аудит актуального архива 3.0.9.
- VLESS-каскад больше не клонирует активные Config Profile: новые установки обновляют два разных профиля на месте и сохраняют полный JSON/active inbound tags для отката. Это устраняет конфликт глобально уникальных inbound-тегов Remnawave.
- Добавлен безопасный rollback для in-place каскада и совместимость со старыми state v2.
- Самообновление теперь обновляет полный набор runtime-файлов, включая отсутствующие модули, оба языка, tools и vendor launcher, и проверяет каждый shell-файл через `bash -n` до замены.
- Исправлен неполный rollback ремонта standalone Nginx: Certbot renew hook меняется только после успешной live-проверки контейнера.
- Удалены дубли функции/локализационного ключа и лишнее повторное добавление выбранного inbound в cascade-модуле.
- Исправлены ещё 21 PNG-файл с ошибочным расширением `.webp`; теперь все WebP имеют корректный RIFF/WebP формат.
- Workflow документации обновлён на Node 24-совместимые Actions (`checkout@v7`, `withastro/action@v6`, `deploy-pages@v5`).
- Из релизного архива удалены старые validation/build/hotfix отчёты и настройки VS Code.

# 3.0.9

- Standalone Nginx Node now mounts `/etc/letsencrypt` read-only as a complete tree, so Certbot `live -> archive` symlinks remain valid inside the container and after renewals.
- Standalone Node nginx configuration now reads certificates directly from `/etc/letsencrypt/live/<domain>/`.
- Startup self-repair migrates existing `/etc/nginx/ssl/...` Node configs, adds the mount to the correct `remnawave-nginx` service, recreates only that container, then verifies certificate readability and `nginx -t`.
- Repair now detects a stale running container by Docker mount inspection and performs rollback with logs if live verification fails.

# 3.0.8

- Исправлена установка Nginx для отдельной Remnawave Node: сертификаты теперь монтируются в `/opt/remnanode/docker-compose.yml`, а не в `/opt/remnawave/docker-compose.yml`.
- Пути deploy-hook Certbot теперь соответствуют реальному каталогу установки (`/opt/remnawave` или `/opt/remnanode`).
- Добавлено безопасное автоисправление уже установленной отдельной Node: при отсутствии certificate volume mounts создаётся резервная копия Compose, добавляются только существующие сертификаты, выполняется `docker compose config`, затем пересоздаётся только `remnawave-nginx`.
- Проверка запуска отдельной Node больше не зависит от `curl https://SELFSTEAL_DOMAIN`: при REALITY этот запрос может штатно попадать в target. Теперь проверяются контейнер `remnanode`, fallback-контейнер, TCP/2222 и `/dev/shm/nginx.sock`.
- Исправлены ошибочно переименованные PNG-файлы документации `logo.webp`, `banner.webp`, `banner-black.webp`: теперь это настоящие WebP, чтобы Astro build не падал на image metadata.

# 3.0.7

- Исправлено создание Config Profile для VLESS-каскада: Remnawave ограничивает поле `name` длиной 30 символов, а прежние имена `Cascade Exit - <node> - <timestamp>` и `Cascade Entry - <node> - <timestamp>` гарантированно могли превышать лимит.
- Служебные профили теперь получают короткие уникальные имена `CascadeExit-YYYYMMDDhhmmss` и `CascadeEntry-YYYYMMDDhhmmss` (26 и 27 символов соответственно).
- Ошибка не связана с выбранным режимом RU-direct; повторный запуск после обновления безопасен, если предыдущий вызов завершился на HTTP 400 при создании первого exit-профиля.

# 3.0.6

- Исправлена подготовка UFW на VPS с отключённым IPv6: `/etc/default/ufw` автоматически синхронизируется с состоянием ядра (`IPV6=no`).
- Ошибка UFW больше не маскируется сообщением «Не удалось установить Docker».
- При сбое UFW выводится реальная диагностическая причина.
- Диапазон главного меню исправлен с `0-12` на `0-13`.

## 3.0.5

- Исправлена интеграция AmneziaWG 3.0 с Config Profile: вместо полного клонирования профиль обновляется на месте, поскольку Remnawave требует глобально уникальные inbound-теги и отклоняет клон с HTTP 409.
- Исходный JSON и активные inbound-теги сохраняются в state.json и используются для отключения/отката.
- Добавлена совместимость с двумя вариантами PATCH API Config Profile и вывод тела API-ошибки при сбое.

# 3.0.4

- Исправлено добавление `NET_ADMIN` контейнеру `remnanode` для AmneziaWG 3.0/TPROXY.
- В новых установках Panel+Node `NET_ADMIN` задаётся сразу в Compose.
- Для существующих установок пункт 13 предпочитает структурное изменение Compose через `yq`, проверяет итоговую конфигурацию через `docker compose config --format json`, затем пересоздаёт только `remnanode` с `--no-deps --force-recreate`.
- Проверка capability принимает `NET_ADMIN` и `CAP_NET_ADMIN`.

# 3.0.3

- AmneziaWG 3.0 module now recreates the pinned v5.24.0 launcher automatically when `/usr/local/remnawave_reverse/vendor/amneziawg-installer/install_amneziawg.sh` is missing after an in-place updater run or a raw-script installation.
- Keeps the immutable upstream commit pin and existing optional AWG client endpoint domain support.

# 3.0.2

- Версия установщика повышена до `3.0.2`, чтобы встроенная проверка обновлений корректно отличала новую сборку от `3.0.1`.
- Сохранена автоматическая выдача и запись `REMNAWAVE_API_TOKEN` для Subscription Page при установке.
- В пункте 13 сохранён опциональный FQDN для `Endpoint` AmneziaWG 3.0 с проверкой DNS и fallback на публичный IP VPS.
- SSL-сертификат для AWG endpoint не выпускается: FQDN используется только для DNS-разрешения UDP endpoint.

# 3.0.1

- Отображаемая версия установщика сокращена до `3.0.1`.
- В пункт 13 добавлен опциональный FQDN для клиентского `Endpoint` AmneziaWG; домен проверяется по A-записи на публичный IPv4 текущего VPS и передаётся upstream-инсталлятору через `--endpoint`. SSL для AWG-домена не выпускается.

- Добавлен модуль `src/modules/cascade_vless.sh`.
- Добавлен пункт 12 главного меню.
- Автоматизировано создание VLESS + REALITY bridge между двумя нодами Remnawave.
- Добавлены два режима маршрутизации: весь трафик через exit и RU direct.
- Исходные профили клонируются и сохраняются для отката.
- Добавлены проверка состояния, отключение, повторное включение и полное удаление.
- Добавлены русская и английская локализации.
- Добавлена установка локально включённых модулей из архива.
- Официальное автообновление отключено для защиты модификации от перезаписи.
