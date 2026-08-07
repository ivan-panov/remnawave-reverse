#!/usr/bin/env bash
set -Eeuo pipefail

TARGET_DIR="${TARGET_DIR:-/opt/remnawave}"
API_URL="${REMNAWAVE_LOCAL_API_URL:-http://127.0.0.1:3000}"
TOKEN_NAME="subscription-page-$(date +%Y%m%d%H%M%S)"

red='\033[1;31m'; green='\033[1;32m'; yellow='\033[1;33m'; reset='\033[0m'
die() { printf '%b\n' "${red}$*${reset}" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || die "Не найдена команда: $1"; }
need curl; need jq; need docker
[ -f "$TARGET_DIR/.env" ] || die "Не найден $TARGET_DIR/.env"
[ -f "$TARGET_DIR/docker-compose.yml" ] || die "Не найден $TARGET_DIR/docker-compose.yml"

read -rp 'Логин администратора Remnawave: ' RW_USER
read -srp 'Пароль администратора Remnawave: ' RW_PASS
printf '\n'

login_payload=$(jq -nc --arg username "$RW_USER" --arg password "$RW_PASS" '{username:$username,password:$password}')
login_response=$(curl -fsS --http1.1 --connect-timeout 5 --max-time 30 \
  -X POST "$API_URL/api/auth/login" \
  -H 'Content-Type: application/json' \
  -H 'X-Forwarded-For: 127.0.0.1' \
  -H 'X-Forwarded-Proto: https' \
  -H 'X-Remnawave-Client-Type: browser' \
  -d "$login_payload") || die 'Не удалось войти в локальный API панели.'
unset RW_PASS login_payload

admin_token=$(printf '%s' "$login_response" | jq -r '.response.accessToken // .accessToken // empty')
unset login_response
[ ${#admin_token} -ge 20 ] || die 'API не вернул административный JWT.'

(
  cd "$TARGET_DIR"
  docker compose stop remnawave-subscription-page >/dev/null 2>&1 || true
)

create_payload=$(jq -nc --arg name "$TOKEN_NAME" '{name:$name,expiresInDays:365,scopes:["*"]}')
body_file=$(mktemp); error_file=$(mktemp)
trap 'rm -f "$body_file" "$error_file"' EXIT
set +e
http_code=$(curl -sS --http1.1 --connect-timeout 5 --max-time 30 \
  -o "$body_file" -w '%{http_code}' \
  -X POST "$API_URL/api/tokens" \
  -H "Authorization: Bearer $admin_token" \
  -H 'Content-Type: application/json' \
  -H 'X-Forwarded-For: 127.0.0.1' \
  -H 'X-Forwarded-Proto: https' \
  -H 'X-Remnawave-Client-Type: browser' \
  -d "$create_payload" 2>"$error_file")
curl_rc=$?
set -e
unset admin_token create_payload
body=$(cat "$body_file")
error_text=$(cat "$error_file")

if [ "$curl_rc" -ne 0 ]; then
  docker inspect remnawave --format 'backend: status={{.State.Status}} health={{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}} restarts={{.RestartCount}} oom={{.State.OOMKilled}} exit={{.State.ExitCode}}' >&2 2>/dev/null || true
  docker logs --tail=100 remnawave >&2 2>/dev/null || true
  die "Ошибка curl ${curl_rc}: ${error_text:-пустой ответ сервера}"
fi
[[ "$http_code" =~ ^20[01]$ ]] || die "API вернул HTTP $http_code: $body"

sub_token=$(printf '%s' "$body" | jq -r '.response.token // .response.apiToken // .response.apiKey // .token // .apiToken // .apiKey // empty')
unset body
[ ${#sub_token} -ge 20 ] || die 'API создал запись, но не вернул значение токена.'

cp -a "$TARGET_DIR/.env" "$TARGET_DIR/.env.before-subpage-repair.$(date +%s)"
cp -a "$TARGET_DIR/docker-compose.yml" "$TARGET_DIR/docker-compose.yml.before-subpage-repair.$(date +%s)"

tmp_env=$(mktemp "$TARGET_DIR/.env.tmp.XXXXXX")
awk -v value="$sub_token" '
  BEGIN { found=0 }
  /^REMNAWAVE_API_TOKEN=/ { print "REMNAWAVE_API_TOKEN=" value; found=1; next }
  { print }
  END { if (!found) print "REMNAWAVE_API_TOKEN=" value }
' "$TARGET_DIR/.env" > "$tmp_env"
chmod 600 "$tmp_env"
mv -f "$tmp_env" "$TARGET_DIR/.env"
unset sub_token

sed -i 's|REMNAWAVE_API_TOKEN=.*|REMNAWAVE_API_TOKEN=${REMNAWAVE_API_TOKEN}|' "$TARGET_DIR/docker-compose.yml"
grep -Fq 'REMNAWAVE_API_TOKEN=${REMNAWAVE_API_TOKEN}' "$TARGET_DIR/docker-compose.yml" || die 'Не удалось исправить ссылку на токен в Compose.'

(
  cd "$TARGET_DIR"
  docker compose config -q
  docker compose up -d --force-recreate --no-deps remnawave-subscription-page
)

for _ in $(seq 1 24); do
  state=$(docker inspect -f '{{.State.Status}}' remnawave-subscription-page 2>/dev/null || true)
  health=$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' remnawave-subscription-page 2>/dev/null || true)
  present=$(docker inspect remnawave-subscription-page --format '{{range .Config.Env}}{{println .}}{{end}}' 2>/dev/null | awk -F= '/^REMNAWAVE_API_TOKEN=/{if(length($2)>=20)print "yes"}')
  if [ "$state" = running ] && [ "$present" = yes ] && { [ "$health" = healthy ] || [ "$health" = none ]; }; then
    printf '%b\n' "${green}Subscription Page восстановлена: токен передан, контейнер ${health}.${reset}"
    exit 0
  fi
  sleep 5
done

docker logs --tail=100 remnawave-subscription-page >&2 2>/dev/null || true
die 'Токен передан, но Subscription Page не стала healthy за 120 секунд.'
