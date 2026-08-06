#!/usr/bin/env bash
set -Eeuo pipefail

LOG_FILE="${LOG_FILE:-/var/log/remnawave-container-update.log}"
LOCK_FILE="${LOCK_FILE:-/run/lock/remnawave-container-update.lock}"
HEALTH_TIMEOUT="${HEALTH_TIMEOUT:-300}"
LOW_MEMORY_KB="${LOW_MEMORY_KB:-358400}"

mkdir -p "$(dirname "$LOCK_FILE")" "$(dirname "$LOG_FILE")"
exec 9>"$LOCK_FILE"
if ! flock -n 9; then
    echo "Another Remnawave container update is already running." >&2
    exit 0
fi

exec > >(tee -a "$LOG_FILE") 2>&1
printf '\n[%s] Starting Remnawave application container update\n' "$(date -Is)"

if [ "${EUID:-$(id -u)}" -ne 0 ]; then
    echo "This updater must be run as root."
    exit 1
fi
if ! command -v docker >/dev/null 2>&1 || ! docker info >/dev/null 2>&1; then
    echo "Docker Engine is unavailable."
    exit 1
fi
if ! docker compose version >/dev/null 2>&1; then
    echo "Docker Compose plugin is unavailable."
    exit 1
fi
if ! command -v jq >/dev/null 2>&1; then
    echo "jq is required."
    exit 1
fi

compose_dirs=()
[ -f /opt/remnawave/docker-compose.yml ] && compose_dirs+=(/opt/remnawave)
[ -f /opt/remnanode/docker-compose.yml ] && compose_dirs+=(/opt/remnanode)
if [ "${#compose_dirs[@]}" -eq 0 ]; then
    echo "No Remnawave docker-compose.yml was found."
    exit 1
fi

service_exists() {
    local dir="$1" service="$2"
    (cd "$dir" && docker compose config --services 2>/dev/null | grep -Fxq "$service")
}

configured_image() {
    local dir="$1" service="$2"
    (cd "$dir" && docker compose config --format json | jq -er --arg s "$service" '.services[$s].image')
}

container_id() {
    local dir="$1" service="$2"
    (cd "$dir" && docker compose ps -q "$service" 2>/dev/null || true)
}

container_state() {
    local dir="$1" service="$2" cid status health
    cid="$(container_id "$dir" "$service")"
    [ -n "$cid" ] || { printf '%s\n' 'missing/missing'; return; }
    status="$(docker inspect -f '{{.State.Status}}' "$cid" 2>/dev/null || echo unknown)"
    health="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$cid" 2>/dev/null || echo unknown)"
    printf '%s/%s\n' "$status" "$health"
}

container_ready() {
    case "$(container_state "$1" "$2")" in
        running/healthy|running/none) return 0 ;;
        *) return 1 ;;
    esac
}

wait_service() {
    local dir="$1" service="$2" elapsed=0 state
    while [ "$elapsed" -lt "$HEALTH_TIMEOUT" ]; do
        state="$(container_state "$dir" "$service")"
        case "$state" in
            running/healthy|running/none)
                echo "$service is ready: $state"
                return 0
                ;;
            exited/*|dead/*)
                echo "$service failed: $state"
                return 1
                ;;
        esac
        sleep 5
        elapsed=$((elapsed + 5))
    done
    echo "$service did not become ready in ${HEALTH_TIMEOUT}s: $(container_state "$dir" "$service")"
    return 1
}

restore_service_image() {
    local dir="$1" service="$2" image_ref="$3" old_image_id="$4"
    [ -n "$old_image_id" ] || return 1
    docker image inspect "$old_image_id" >/dev/null 2>&1 || return 1
    echo "Rolling back $service to $old_image_id"
    docker image tag "$old_image_id" "$image_ref"
    (cd "$dir" && docker compose up -d --no-deps --force-recreate "$service")
    wait_service "$dir" "$service"
}

update_service() {
    local dir="$1" service="$2" image_ref old_cid old_image_id old_state new_image_id
    service_exists "$dir" "$service" || return 0
    image_ref="$(configured_image "$dir" "$service")"
    old_cid="$(container_id "$dir" "$service")"
    old_image_id=""
    [ -n "$old_cid" ] && old_image_id="$(docker inspect -f '{{.Image}}' "$old_cid" 2>/dev/null || true)"
    old_state="$(container_state "$dir" "$service")"

    echo
    echo "=== $service ($image_ref) ==="
    echo "Current state: $old_state"
    (cd "$dir" && docker compose pull "$service")
    new_image_id="$(docker image inspect -f '{{.Id}}' "$image_ref" 2>/dev/null || true)"

    if [ -n "$old_image_id" ] && [ "$old_image_id" = "$new_image_id" ] && container_ready "$dir" "$service"; then
        echo "$service already uses the current image."
        return 0
    fi

    if ! (cd "$dir" && docker compose up -d --no-deps --force-recreate "$service"); then
        echo "Failed to recreate $service."
        restore_service_image "$dir" "$service" "$image_ref" "$old_image_id" || true
        return 1
    fi

    if ! wait_service "$dir" "$service"; then
        (cd "$dir" && docker compose logs --tail=200 "$service") || true
        if restore_service_image "$dir" "$service" "$image_ref" "$old_image_id"; then
            echo "$service was rolled back successfully."
        else
            echo "Automatic rollback of $service failed."
        fi
        return 1
    fi

    echo "$service updated successfully."
}

validate_compose() {
    local dir="$1"
    (cd "$dir" && docker compose config -q)
}

# Automatic runs never perform the major Panel 2.x -> 3.x migration.
# It requires an interactive backup/confirmation in the installer menu.
for dir in "${compose_dirs[@]}"; do
    validate_compose "$dir"
    if grep -Eq 'image:[[:space:]]*remnawave/backend:2([[:space:]]|$)' "$dir/docker-compose.yml"; then
        echo "Automatic update refused: $dir still uses remnawave/backend:2."
        echo "Run: rr -> Manage panel/node -> Update panel/node"
        exit 2
    fi
done

# On small VPSs free memory before pulling/recreating the panel.
stopped_for_memory=()
available_kb="$(awk '/MemAvailable:/ {print $2}' /proc/meminfo)"
if [ "${available_kb:-0}" -lt "$LOW_MEMORY_KB" ] && [ -f /opt/remnawave/docker-compose.yml ]; then
    echo "Low-memory mode enabled (MemAvailable=${available_kb:-0} KiB)."
    for service in remnawave-subscription-page remnanode; do
        if service_exists /opt/remnawave "$service" && container_ready /opt/remnawave "$service"; then
            (cd /opt/remnawave && docker compose stop "$service") || true
            stopped_for_memory+=("$service")
        fi
    done
fi

restart_stopped_services() {
    local service
    [ -f /opt/remnawave/docker-compose.yml ] || return 0
    for service in "${stopped_for_memory[@]:-}"; do
        [ -n "$service" ] || continue
        if ! container_ready /opt/remnawave "$service"; then
            (cd /opt/remnawave && docker compose up -d --no-deps "$service") || true
        fi
    done
}
trap restart_stopped_services EXIT

# Officially recommended order: Panel first, then Nodes.
if [ -f /opt/remnawave/docker-compose.yml ]; then
    update_service /opt/remnawave remnawave
    update_service /opt/remnawave remnawave-subscription-page
    update_service /opt/remnawave remnawave-nginx
    update_service /opt/remnawave remnawave-caddy
    update_service /opt/remnawave remnanode
fi

if [ -f /opt/remnanode/docker-compose.yml ]; then
    update_service /opt/remnanode remnanode
    update_service /opt/remnanode remnawave-nginx
    update_service /opt/remnanode caddy-remnawave
fi

trap - EXIT
restart_stopped_services

docker image prune -f >/dev/null 2>&1 || true

echo
echo "Current Remnawave containers:"
docker ps --filter 'name=remnawave' --filter 'name=remnanode' \
    --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}'
printf '[%s] Update completed successfully\n' "$(date -Is)"
