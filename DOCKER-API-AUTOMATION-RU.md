# Автоматизация Docker → Remnawave → VLESS-каскад

1. Перед установкой Remnawave выполняется `ensure_docker_ready`.
2. Если Docker Engine и Compose работают, существующая установка сохраняется.
3. Если Docker отсутствует или повреждён, используются пакеты из официального APT-репозитория Docker:
   `docker-ce`, `docker-ce-cli`, `containerd.io`, `docker-buildx-plugin`, `docker-compose-plugin`.
4. Выполняются `systemctl enable --now docker`, `docker info`, `docker compose version` и тест `hello-world`.
5. Только после успешной проверки продолжается установка Remnawave.
6. Пункт 12 создаёт VLESS IN → VLESS OUT через локальный API Remnawave. Профили не клонируются: из-за глобальной уникальности inbound-тегов они обновляются на месте, а исходный JSON и активные inbound-теги сохраняются для полного отката. Входная и выходная ноды должны использовать разные Config Profile.

Запускать от root на Ubuntu 24.04.
