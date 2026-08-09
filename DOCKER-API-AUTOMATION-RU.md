# Автоматизация Docker → Remnawave → VLESS-каскад

1. Перед установкой Remnawave выполняется `ensure_docker_ready`.
2. Если Docker Engine и Compose работают, существующая установка сохраняется.
3. Если Docker отсутствует или повреждён, используются пакеты из официального APT-репозитория Docker:
   `docker-ce`, `docker-ce-cli`, `containerd.io`, `docker-buildx-plugin`, `docker-compose-plugin`.
4. Выполняются `systemctl enable --now docker`, `docker info`, `docker compose version` и тест `hello-world`.
5. Только после успешной проверки продолжается установка Remnawave.
6. Пункт 12 создаёт VLESS IN → VLESS OUT через локальный API Remnawave. Профили не клонируются: из-за глобальной уникальности inbound-тегов они обновляются на месте, а исходный JSON и активные inbound-теги сохраняются для полного отката. Входная и выходная ноды должны использовать разные Config Profile.

Запускать от root на Ubuntu 24.04.

## Защита от фоновых APT-блокировок (3.0.14)

После установки Docker Ubuntu может автоматически запустить `apt-daily` или `unattended-upgrades` и временно занять `dpkg` lock. Установщик теперь ждёт освобождения `/var/lib/dpkg/lock-frontend`, `/var/lib/dpkg/lock`, `/var/lib/apt/lists/lock` и `/var/cache/apt/archives/lock` до 15 минут, после чего автоматически продолжает установку. APT-команды также используют `DPkg::Lock::Timeout=900`, а настройка `unattended-upgrades` повторяется при временной ошибке.
