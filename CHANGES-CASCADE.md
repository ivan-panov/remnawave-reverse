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
