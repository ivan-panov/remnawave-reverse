#!/bin/bash
# Pinned launcher for bivlked/amneziawg-installer v5.24.0.
# Commit: 2c86966f59d54c0fd0bcf66639c537558a1a0c25
# On x86_64 with Linux >= 6.7 this upstream installer installs the
# AmneziaWG 3.0 kernel module from the official Amnezia PPA.
set -euo pipefail

UPSTREAM_VERSION="5.24.0"
UPSTREAM_COMMIT="2c86966f59d54c0fd0bcf66639c537558a1a0c25"
UPSTREAM_URL="https://raw.githubusercontent.com/bivlked/amneziawg-installer/${UPSTREAM_COMMIT}/install_amneziawg.sh"

tmp="$(mktemp /tmp/remnawave-amneziawg-installer.XXXXXX.sh)"
cleanup() { rm -f "$tmp"; }
trap cleanup EXIT INT TERM

curl -fL \
    --proto '=https' \
    --tlsv1.2 \
    --connect-timeout 20 \
    --retry 5 \
    --retry-delay 2 \
    -o "$tmp" \
    "$UPSTREAM_URL"

chmod 700 "$tmp"
grep -Fq 'SCRIPT_VERSION="5.24.0"' "$tmp" || {
    echo "Ошибка: загруженный AmneziaWG Installer не соответствует v${UPSTREAM_VERSION}." >&2
    exit 1
}
grep -Fq 'AWG_BRANCH="${AWG_BRANCH:-v${SCRIPT_VERSION}}"' "$tmp" || {
    echo "Ошибка: структура upstream-инсталлера неожиданно изменилась." >&2
    exit 1
}

# Pin helper scripts (awg_common/manage) to the same immutable commit.
AWG_BRANCH="$UPSTREAM_COMMIT" bash "$tmp" "$@"
