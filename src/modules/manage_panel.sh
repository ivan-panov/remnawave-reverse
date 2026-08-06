#!/bin/bash
# Module: Manage Panel / Node and container updates

get_remnawave_compose_dir() {
    if [ -f "/opt/remnawave/docker-compose.yml" ]; then
        printf '%s\n' "/opt/remnawave"
    elif [ -f "/opt/remnanode/docker-compose.yml" ]; then
        printf '%s\n' "/opt/remnanode"
    else
        return 1
    fi
}

compose_service_exists() {
    docker compose config --services 2>/dev/null | grep -Fxq "$1"
}

compose_container_ready() {
    local service="$1" cid status health
    cid="$(docker compose ps -q "$service" 2>/dev/null || true)"
    [ -n "$cid" ] || return 1
    status="$(docker inspect -f '{{.State.Status}}' "$cid" 2>/dev/null || true)"
    health="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$cid" 2>/dev/null || true)"
    [ "$status" = "running" ] && { [ "$health" = "healthy" ] || [ "$health" = "none" ]; }
}

install_container_update_tool() {
    local installed="${DIR_REMNAWAVE}tools/remnawave_container_update.sh"
    local target="/usr/local/sbin/remnawave-container-update"
    local candidate

    mkdir -p "${DIR_REMNAWAVE}tools"
    for candidate in \
        "${SCRIPT_DIR:-}/src/tools/remnawave_container_update.sh" \
        "${SCRIPT_DIR:-}/tools/remnawave_container_update.sh" \
        "$installed"; do
        if [ -s "$candidate" ]; then
            [ "$candidate" = "$installed" ] || cp "$candidate" "$installed"
            break
        fi
    done

    if [ ! -s "$installed" ]; then
        echo -e "${COLOR_RED}${LANG[CONTAINER_UPDATER_MISSING]}${COLOR_RESET}"
        return 1
    fi
    install -m 0755 "$installed" "$target"
}

show_manage_panel_menu() {
    echo -e ""
    echo -e "${COLOR_GREEN}${LANG[MENU_3]}${COLOR_RESET}"
    echo -e ""
    echo -e "${COLOR_YELLOW}1. ${LANG[START_PANEL_NODE]}${COLOR_RESET}"
    echo -e "${COLOR_YELLOW}2. ${LANG[STOP_PANEL_NODE]}${COLOR_RESET}"
    echo -e "${COLOR_YELLOW}3. ${LANG[UPDATE_PANEL_NODE]}${COLOR_RESET}"
    echo -e "${COLOR_YELLOW}4. ${LANG[VIEW_LOGS]}${COLOR_RESET}"
    echo -e "${COLOR_YELLOW}5. ${LANG[REMNAWAVE_CLI]}${COLOR_RESET}"
    echo -e "${COLOR_YELLOW}6. ${LANG[ACCESS_PANEL]}${COLOR_RESET}"
    echo -e "${COLOR_YELLOW}7. ${LANG[SHOW_CONTAINER_VERSIONS]}${COLOR_RESET}"
    echo -e "${COLOR_YELLOW}8. ${LANG[AUTO_UPDATE_MENU]}${COLOR_RESET}"
    echo -e ""
    echo -e "${COLOR_YELLOW}0. ${LANG[EXIT]}${COLOR_RESET}"
    echo -e ""
    reading "${LANG[MANAGE_PANEL_NODE_PROMPT]}" SUB_OPTION

    case $SUB_OPTION in
        1) start_panel_node ;;
        2) stop_panel_node ;;
        3) update_panel_node ;;
        4) view_logs ;;
        5) run_remnawave_cli ;;
        6) manage_panel_access ;;
        7) show_container_versions ;;
        8) manage_container_auto_updates ;;
        0) remnawave_reverse; return ;;
        *) echo -e "${COLOR_YELLOW}${LANG[MANAGE_PANEL_NODE_INVALID_CHOICE]}${COLOR_RESET}" ;;
    esac

    sleep 2
    log_clear
    show_manage_panel_menu
}

run_remnawave_cli() {
    if ! docker ps --format '{{.Names}}' | grep -q '^remnawave$'; then
        echo -e "${COLOR_YELLOW}${LANG[CONTAINER_NOT_RUNNING]}${COLOR_RESET}"
        return 1
    fi

    exec 3>&1 4>&2
    exec > /dev/tty 2>&1
    echo -e "${COLOR_YELLOW}${LANG[RUNNING_CLI]}${COLOR_RESET}"

    if docker exec -it -e TERM=xterm-256color remnawave cli; then
        echo -e "${COLOR_GREEN}${LANG[CLI_SUCCESS]}${COLOR_RESET}"
    elif docker exec -it -e TERM=xterm-256color remnawave remnawave; then
        echo -e "${COLOR_GREEN}${LANG[CLI_SUCCESS]}${COLOR_RESET}"
    else
        echo -e "${COLOR_RED}${LANG[CLI_FAILED]}${COLOR_RESET}"
        exec 1>&3 2>&4
        return 1
    fi
    exec 1>&3 2>&4
}

start_panel_node() {
    local dir
    dir="$(get_remnawave_compose_dir)" || {
        echo -e "${COLOR_RED}${LANG[DIR_NOT_FOUND]}${COLOR_RESET}"
        return 1
    }
    cd "$dir" || return 1
    docker compose config -q || return 1

    if [ -n "$(docker compose ps -q --status running 2>/dev/null)" ]; then
        echo -e "${COLOR_GREEN}${LANG[PANEL_RUNNING]}${COLOR_RESET}"
        return 0
    fi

    echo -e "${COLOR_YELLOW}${LANG[STARTING_PANEL_NODE]}...${COLOR_RESET}"
    docker compose up -d --remove-orphans
    echo -e "${COLOR_GREEN}${LANG[PANEL_RUN]}${COLOR_RESET}"
}

stop_panel_node() {
    local dir
    dir="$(get_remnawave_compose_dir)" || {
        echo -e "${COLOR_RED}${LANG[DIR_NOT_FOUND]}${COLOR_RESET}"
        return 1
    }
    cd "$dir" || return 1

    if [ -z "$(docker compose ps -q --status running 2>/dev/null)" ]; then
        echo -e "${COLOR_GREEN}${LANG[PANEL_STOPPED]}${COLOR_RESET}"
        return 0
    fi

    echo -e "${COLOR_YELLOW}${LANG[STOPPING_REMNAWAVE]}...${COLOR_RESET}"
    docker compose down
    echo -e "${COLOR_GREEN}${LANG[PANEL_STOP]}${COLOR_RESET}"
}

create_preupdate_backup() {
    local dir="$1"
    PREUPDATE_BACKUP_DIR="${dir}/backups/update-$(date +%Y%m%d-%H%M%S)"
    mkdir -p "$PREUPDATE_BACKUP_DIR"
    cp -a "$dir/docker-compose.yml" "$PREUPDATE_BACKUP_DIR/"
    [ -f "$dir/.env" ] && cp -a "$dir/.env" "$PREUPDATE_BACKUP_DIR/"
    [ -f "$dir/nginx.conf" ] && cp -a "$dir/nginx.conf" "$PREUPDATE_BACKUP_DIR/"
    [ -f "$dir/Caddyfile" ] && cp -a "$dir/Caddyfile" "$PREUPDATE_BACKUP_DIR/"

    if docker ps --format '{{.Names}}' | grep -q '^remnawave-db$'; then
        echo -e "${COLOR_YELLOW}${LANG[CREATING_DB_BACKUP]}${COLOR_RESET}"
        if ! (set -o pipefail; docker exec remnawave-db sh -lc 'pg_dumpall -U "$POSTGRES_USER"' | gzip -1 > "$PREUPDATE_BACKUP_DIR/postgres.sql.gz"); then
            rm -f "$PREUPDATE_BACKUP_DIR/postgres.sql.gz"
            echo -e "${COLOR_RED}${LANG[DB_BACKUP_FAILED]}${COLOR_RESET}"
            return 1
        fi
    fi
}

ensure_existing_v3_compression() {
    local dir="$1" file tmp
    if [ -f "$dir/nginx.conf" ] && ! grep -q 'Remnawave v3 response compression' "$dir/nginx.conf"; then
        file="$dir/nginx.conf"
        tmp="$(mktemp)"
        cat > "$tmp" <<'NGINX'
# Remnawave v3 response compression
gzip on;
gzip_vary on;
gzip_proxied any;
gzip_comp_level 6;
gzip_min_length 1024;
gzip_types application/javascript application/json application/manifest+json application/xml application/wasm font/opentype font/eot font/otf font/ttf image/svg+xml text/css text/javascript text/plain text/xml;

NGINX
        cat "$file" >> "$tmp"
        cat "$tmp" > "$file"
        rm -f "$tmp"
    fi

    if [ -f "$dir/Caddyfile" ] && ! grep -q 'encode zstd gzip' "$dir/Caddyfile"; then
        file="$dir/Caddyfile"
        tmp="$(mktemp)"
        awk '
            /^https:\/\/\{\$PANEL_DOMAIN\}[[:space:]]*\{/ || /^https:\/\/\{\$SUB_DOMAIN\}[[:space:]]*\{/ {
                print
                print "    encode zstd gzip"
                next
            }
            { print }
        ' "$file" > "$tmp"
        cat "$tmp" > "$file"
        rm -f "$tmp"
    fi
}

normalize_current_compose_for_updates() {
    local dir="$1" tmp
    local compose="$dir/docker-compose.yml"

    # Application/proxy images track maintained branches. PostgreSQL remains
    # pinned because database upgrades must be handled separately.
    sed -Ei \
        -e 's#(image:[[:space:]]*nginx):(1\.28|1\.30)([[:space:]]*)$#\1:stable\3#' \
        -e 's#(image:[[:space:]]*caddy):2\.11\.2([[:space:]]*)$#\1:2\2#' \
        -e 's#(image:[[:space:]]*valkey/valkey):9\.0\.3-alpine([[:space:]]*)$#\1:9-alpine\2#' \
        "$compose"

    if compose_service_exists remnawave-subscription-page && ! grep -q '^[[:space:]]*-[[:space:]]*TRUST_PROXY=' "$compose"; then
        tmp="$(mktemp)"
        awk '
            { print }
            /^[[:space:]]*-[[:space:]]*REMNAWAVE_API_TOKEN=/ {
                print "      - TRUST_PROXY=1"
            }
        ' "$compose" > "$tmp"
        cat "$tmp" > "$compose"
        rm -f "$tmp"
    fi
}

migrate_backend_v2_to_v3() {
    local dir="$1" answer backup_dir
    local compose="$dir/docker-compose.yml"
    PANEL_MAJOR_MIGRATION=false
    grep -Eq 'image:[[:space:]]*remnawave/backend:2([[:space:]]|$)' "$compose" || return 0

    echo -e "${COLOR_YELLOW}${LANG[PANEL_V2_DETECTED]}${COLOR_RESET}"
    echo -e "${COLOR_YELLOW}${LANG[PANEL_V3_MIGRATION_WARNING]}${COLOR_RESET}"
    reading "${LANG[PANEL_V3_MIGRATION_CONFIRM]}" answer
    if [[ "$answer" != "y" && "$answer" != "Y" ]]; then
        echo -e "${COLOR_YELLOW}${LANG[UPDATE_CANCELLED]}${COLOR_RESET}"
        return 1
    fi

    create_preupdate_backup "$dir" || return 1
    backup_dir="$PREUPDATE_BACKUP_DIR"
    sed -Ei 's#(image:[[:space:]]*remnawave/backend):2([[:space:]]*)$#\1:3\2#' "$compose"
    ensure_existing_v3_compression "$dir"
    docker compose config -q || {
        cp "$backup_dir/docker-compose.yml" "$compose"
        [ -f "$backup_dir/nginx.conf" ] && cp "$backup_dir/nginx.conf" "$dir/nginx.conf"
        [ -f "$backup_dir/Caddyfile" ] && cp "$backup_dir/Caddyfile" "$dir/Caddyfile"
        echo -e "${COLOR_RED}${LANG[COMPOSE_INVALID_ROLLBACK]}${COLOR_RESET}"
        return 1
    }
    PANEL_MAJOR_MIGRATION=true
    echo -e "${COLOR_GREEN}$(printf "${LANG[BACKUP_SAVED]}" "$backup_dir")${COLOR_RESET}"
}

update_panel_node() {
    local dir available_kb
    dir="$(get_remnawave_compose_dir)" || {
        echo -e "${COLOR_RED}${LANG[DIR_NOT_FOUND]}${COLOR_RESET}"
        return 1
    }
    cd "$dir" || return 1

    if ! docker info >/dev/null 2>&1 || ! docker compose version >/dev/null 2>&1; then
        echo -e "${COLOR_RED}${LANG[DOCKER_NOT_READY]}${COLOR_RESET}"
        return 1
    fi
    docker compose config -q || return 1

    available_kb="$(awk '/MemAvailable:/ {print $2}' /proc/meminfo)"
    if [ "${available_kb:-0}" -lt 307200 ]; then
        echo -e "${COLOR_YELLOW}${LANG[LOW_MEMORY_UPDATE_WARNING]}${COLOR_RESET}"
    fi

    migrate_backend_v2_to_v3 "$dir" || return 1
    normalize_current_compose_for_updates "$dir"
    ensure_existing_v3_compression "$dir"
    docker compose config -q || return 1

    install_container_update_tool || return 1
    echo -e "${COLOR_YELLOW}${LANG[UPDATING]}${COLOR_RESET}"
    if /usr/local/sbin/remnawave-container-update; then
        echo -e "${COLOR_GREEN}${LANG[UPDATE_SUCCESS1]}${COLOR_RESET}"
        echo -e "${COLOR_GREEN}$(printf "${LANG[UPDATE_LOG_PATH]}" "/var/log/remnawave-container-update.log")${COLOR_RESET}"
    else
        echo -e "${COLOR_RED}${LANG[CONTAINER_UPDATE_FAILED]}${COLOR_RESET}"
        docker compose ps || true
        return 1
    fi
}

show_container_versions() {
    local dir
    dir="$(get_remnawave_compose_dir)" || {
        echo -e "${COLOR_RED}${LANG[DIR_NOT_FOUND]}${COLOR_RESET}"
        return 1
    }
    cd "$dir" || return 1
    echo -e "${COLOR_GREEN}${LANG[CONFIGURED_IMAGES]}${COLOR_RESET}"
    docker compose config --images | sort -u
    echo
    docker ps --filter "name=remnawave" --filter "name=remnanode" \
        --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}'
    echo
    docker compose images
}

show_auto_update_menu() {
    echo -e ""
    echo -e "${COLOR_GREEN}${LANG[AUTO_UPDATE_MENU]}${COLOR_RESET}"
    echo -e "${COLOR_YELLOW}1. ${LANG[AUTO_UPDATE_ENABLE]}${COLOR_RESET}"
    echo -e "${COLOR_YELLOW}2. ${LANG[AUTO_UPDATE_DISABLE]}${COLOR_RESET}"
    echo -e "${COLOR_YELLOW}3. ${LANG[AUTO_UPDATE_STATUS]}${COLOR_RESET}"
    echo -e "${COLOR_YELLOW}4. ${LANG[AUTO_UPDATE_RUN_NOW]}${COLOR_RESET}"
    echo -e "${COLOR_YELLOW}0. ${LANG[EXIT]}${COLOR_RESET}"
}

write_auto_update_units() {
    cat > /etc/systemd/system/remnawave-container-update.service <<'UNIT'
[Unit]
Description=Update Remnawave application containers
Wants=network-online.target docker.service
After=network-online.target docker.service

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/remnawave-container-update
Nice=10
IOSchedulingClass=best-effort
IOSchedulingPriority=7
UNIT

    cat > /etc/systemd/system/remnawave-container-update.timer <<'UNIT'
[Unit]
Description=Weekly Remnawave application container update

[Timer]
OnCalendar=Sun *-*-* 04:15:00
RandomizedDelaySec=30m
Persistent=true

[Install]
WantedBy=timers.target
UNIT
    systemctl daemon-reload
}

panel_v3_ready_for_auto_updates() {
    if [ -f /opt/remnawave/docker-compose.yml ] && \
       grep -Eq 'image:[[:space:]]*remnawave/backend:2([[:space:]]|$)' /opt/remnawave/docker-compose.yml; then
        echo -e "${COLOR_YELLOW}${LANG[AUTO_UPDATE_V3_REQUIRED]}${COLOR_RESET}"
        return 1
    fi
    return 0
}

manage_container_auto_updates() {
    local option
    show_auto_update_menu
    reading "${LANG[AUTO_UPDATE_PROMPT]}" option
    case "$option" in
        1)
            panel_v3_ready_for_auto_updates || return 1
            install_container_update_tool || return 1
            write_auto_update_units
            systemctl enable --now remnawave-container-update.timer
            systemctl list-timers remnawave-container-update.timer --no-pager
            ;;
        2)
            systemctl disable --now remnawave-container-update.timer 2>/dev/null || true
            rm -f /etc/systemd/system/remnawave-container-update.timer \
                  /etc/systemd/system/remnawave-container-update.service
            systemctl daemon-reload
            echo -e "${COLOR_GREEN}${LANG[AUTO_UPDATE_DISABLED_OK]}${COLOR_RESET}"
            ;;
        3)
            systemctl status remnawave-container-update.timer --no-pager || true
            systemctl list-timers remnawave-container-update.timer --no-pager || true
            echo -e "${COLOR_GREEN}$(printf "${LANG[UPDATE_LOG_PATH]}" "/var/log/remnawave-container-update.log")${COLOR_RESET}"
            ;;
        4)
            panel_v3_ready_for_auto_updates || return 1
            install_container_update_tool || return 1
            /usr/local/sbin/remnawave-container-update
            ;;
        0) return 0 ;;
        *) echo -e "${COLOR_YELLOW}${LANG[MANAGE_PANEL_NODE_INVALID_CHOICE]}${COLOR_RESET}" ;;
    esac
}

view_logs() {
    local dir
    dir="$(get_remnawave_compose_dir)" || {
        echo -e "${COLOR_RED}${LANG[DIR_NOT_FOUND]}${COLOR_RESET}"
        return 1
    }
    cd "$dir" || return 1
    if [ -z "$(docker compose ps -q --status running 2>/dev/null)" ]; then
        echo -e "${COLOR_RED}${LANG[CONTAINER_NOT_RUNNING]}${COLOR_RESET}"
        return 1
    fi
    echo -e "${COLOR_YELLOW}${LANG[VIEW_LOGS]}${COLOR_RESET}"
    docker compose logs -f -t
}

#Manage Panel Access
show_panel_access() {
    echo -e ""
    echo -e "${COLOR_GREEN}${LANG[MENU_9]}${COLOR_RESET}"
    echo -e ""
    echo -e "${COLOR_YELLOW}1. ${LANG[PORT_8443_OPEN]}${COLOR_RESET}"
    echo -e "${COLOR_YELLOW}2. ${LANG[PORT_8443_CLOSE]}${COLOR_RESET}"
    echo -e ""
    echo -e "${COLOR_YELLOW}0. ${LANG[EXIT]}${COLOR_RESET}"
    echo -e ""
}

manage_panel_access() {
    show_panel_access
    reading "${LANG[IPV6_PROMPT]}" ACCESS_OPTION
    case $ACCESS_OPTION in
        1)
            open_panel_access
            ;;
        2)
            close_panel_access
            ;;
        0)
            echo -e "${COLOR_YELLOW}${LANG[EXIT]}${COLOR_RESET}"
            sleep 2
            log_clear
            remnawave_reverse
            ;;
        *)
            echo -e "${COLOR_YELLOW}${LANG[IPV6_INVALID_CHOICE]}${COLOR_RESET}"
            ;;
    esac
    sleep 2
    log_clear
    manage_panel_access
}

open_panel_access() {
    local dir=""
    if [ -d "/opt/remnawave" ]; then
        dir="/opt/remnawave"
    elif [ -d "/opt/remnanode" ]; then
        dir="/opt/remnanode"
    else
        echo -e "${COLOR_RED}${LANG[DIR_NOT_FOUND]}${COLOR_RESET}"
        exit 1
    fi

    cd "$dir" || { echo -e "${COLOR_RED}${LANG[CHANGE_DIR_FAILED]} $dir${COLOR_RESET}"; exit 1; }

    local webserver=""
    if [ -f "nginx.conf" ]; then
        webserver="nginx"
    elif [ -f "Caddyfile" ]; then
        webserver="caddy"
    else
        echo -e "${COLOR_RED}${LANG[CONFIG_NOT_FOUND]}${COLOR_RESET}"
        exit 1
    fi

    if [ "$webserver" = "nginx" ]; then
        PANEL_DOMAIN=$(grep -B 20 "proxy_pass http://remnawave" "$dir/nginx.conf" | grep "server_name" | grep -v "server_name _" | awk '{print $2}' | sed 's/;//' | head -n 1)

        cookie_line=$(grep -A 2 "map \$http_cookie \$auth_cookie" "$dir/nginx.conf" | grep "~*\w\+.*=")
        cookies_random1=$(echo "$cookie_line" | grep -oP '~*\K\w+(?==)')
        cookies_random2=$(echo "$cookie_line" | grep -oP '=\K\w+(?=")')

        if [ -z "$PANEL_DOMAIN" ] || [ -z "$cookies_random1" ] || [ -z "$cookies_random2" ]; then
            echo -e "${COLOR_RED}${LANG[NGINX_CONF_ERROR]}${COLOR_RESET}"
            exit 1
        fi

        if command -v ss >/dev/null 2>&1; then
            if ss -tuln | grep -q ":8443"; then
                echo -e "${COLOR_RED}${LANG[PORT_8443_IN_USE]}${COLOR_RESET}"
                exit 1
            fi
        elif command -v netstat >/dev/null 2>&1; then
            if netstat -tuln | grep -q ":8443"; then
                echo -e "${COLOR_RED}${LANG[PORT_8443_IN_USE]}${COLOR_RESET}"
                exit 1
            fi
        else
            echo -e "${COLOR_RED}${LANG[NO_PORT_CHECK_TOOLS]}${COLOR_RESET}"
            exit 1
        fi

        sed -i "/server_name $PANEL_DOMAIN;/,/}/{/^[[:space:]]*$/d; s/listen 8443 ssl;//}" "$dir/nginx.conf"
        sed -i "/server_name $PANEL_DOMAIN;/a \    listen 8443 ssl;" "$dir/nginx.conf"
        if [ $? -ne 0 ]; then
            echo -e "${COLOR_RED}${LANG[NGINX_CONF_MODIFY_FAILED]}${COLOR_RESET}"
            exit 1
        fi

        docker compose up -d --no-deps --force-recreate remnawave-nginx > /dev/null 2>&1 &
        spinner $! "${LANG[WAITING]}"

        ufw allow from 0.0.0.0/0 to any port 8443 proto tcp > /dev/null 2>&1
        ufw reload > /dev/null 2>&1
        sleep 1

        local panel_link="https://${PANEL_DOMAIN}:8443/auth/login?${cookies_random1}=${cookies_random2}"
        echo -e "${COLOR_YELLOW}${LANG[OPEN_PANEL_LINK]}${COLOR_RESET}"
        echo -e "${COLOR_WHITE}${panel_link}${COLOR_RESET}"
        echo -e "${COLOR_RED}${LANG[PORT_8443_WARNING]}${COLOR_RESET}"
    elif [ "$webserver" = "caddy" ]; then
        PANEL_DOMAIN=$(grep 'PANEL_DOMAIN=' "$dir/docker-compose.yml" | head -n 1 | sed 's/.*PANEL_DOMAIN=//; s/[[:space:]]*$//')

        if [ -z "$PANEL_DOMAIN" ]; then
            echo -e "${COLOR_RED}${LANG[CADDY_CONF_ERROR]}${COLOR_RESET}"
            exit 1
        fi

        if grep -q "https://{\$PANEL_DOMAIN}:8443 {" "$dir/Caddyfile"; then
            echo -e "${COLOR_YELLOW}${LANG[PORT_8443_ALREADY_CONFIGURED]}${COLOR_RESET}"
            return 0
        fi

        if command -v ss >/dev/null 2>&1; then
            if ss -tuln | grep -q ":8443"; then
                echo -e "${COLOR_RED}${LANG[PORT_8443_IN_USE]}${COLOR_RESET}"
                exit 1
            fi
        elif command -v netstat >/dev/null 2>&1; then
            if netstat -tuln | grep -q ":8443"; then
                echo -e "${COLOR_RED}${LANG[PORT_8443_IN_USE]}${COLOR_RESET}"
                exit 1
            fi
        else
            echo -e "${COLOR_RED}${LANG[NO_PORT_CHECK_TOOLS]}${COLOR_RESET}"
            exit 1
        fi

        sed -i "s|redir https://{\$PANEL_DOMAIN}{uri} permanent|redir https://{\$PANEL_DOMAIN}:8443{uri} permanent|g" "$dir/Caddyfile"

        sed -i "s|https://{\$PANEL_DOMAIN} {|https://{\$PANEL_DOMAIN}:8443 {|g" "$dir/Caddyfile"
        sed -i "/https:\/\/{\$PANEL_DOMAIN}:8443 {/,/^}/ { /bind unix\/{\$CADDY_SOCKET_PATH}/d }" "$dir/Caddyfile"

        docker compose up -d --no-deps --force-recreate remnawave-caddy > /dev/null 2>&1 &
        spinner $! "${LANG[WAITING]}"

        ufw allow from 0.0.0.0/0 to any port 8443 proto tcp > /dev/null 2>&1
        ufw reload > /dev/null 2>&1
        sleep 1

        local cookie_line=$(grep 'header +Set-Cookie' "$dir/Caddyfile" | head -n 1)
        local cookies_random1=$(echo "$cookie_line" | grep -oP 'Set-Cookie "\K[^=]+')
        local cookies_random2=$(echo "$cookie_line" | grep -oP 'Set-Cookie "[^=]+=\K[^;]+')

        local panel_link="https://${PANEL_DOMAIN}:8443/auth/login"
        if [ -n "$cookies_random1" ] && [ -n "$cookies_random2" ]; then
            panel_link="${panel_link}?${cookies_random1}=${cookies_random2}"
        fi
        echo -e "${COLOR_YELLOW}${LANG[OPEN_PANEL_LINK]}${COLOR_RESET}"
        echo -e "${COLOR_WHITE}${panel_link}${COLOR_RESET}"
        echo -e "${COLOR_RED}${LANG[PORT_8443_WARNING]}${COLOR_RESET}"
    fi
}

close_panel_access() {
    local dir=""
    if [ -d "/opt/remnawave" ]; then
        dir="/opt/remnawave"
    elif [ -d "/opt/remnanode" ]; then
        dir="/opt/remnanode"
    else
        echo -e "${COLOR_RED}${LANG[DIR_NOT_FOUND]}${COLOR_RESET}"
        exit 1
    fi

    cd "$dir" || { echo -e "${COLOR_RED}${LANG[CHANGE_DIR_FAILED]} $dir${COLOR_RESET}"; exit 1; }

    echo -e "${COLOR_YELLOW}${LANG[PORT_8443_CLOSE]}${COLOR_RESET}"

    local webserver=""
    if [ -f "nginx.conf" ]; then
        webserver="nginx"
    elif [ -f "Caddyfile" ]; then
        webserver="caddy"
    else
        echo -e "${COLOR_RED}${LANG[CONFIG_NOT_FOUND]}${COLOR_RESET}"
        exit 1
    fi

    if [ "$webserver" = "nginx" ]; then
        PANEL_DOMAIN=$(grep -B 20 "proxy_pass http://remnawave" "$dir/nginx.conf" | grep "server_name" | grep -v "server_name _" | awk '{print $2}' | sed 's/;//' | head -n 1)

        if [ -z "$PANEL_DOMAIN" ]; then
            echo -e "${COLOR_RED}${LANG[NGINX_CONF_ERROR]}${COLOR_RESET}"
            exit 1
        fi

        if grep -A 10 "server_name $PANEL_DOMAIN;" "$dir/nginx.conf" | grep -q "listen 8443 ssl;"; then
            sed -i "/server_name $PANEL_DOMAIN;/,/}/{/^[[:space:]]*$/d; s/listen 8443 ssl;//}" "$dir/nginx.conf"
            if [ $? -ne 0 ]; then
                echo -e "${COLOR_RED}${LANG[NGINX_CONF_MODIFY_FAILED]}${COLOR_RESET}"
                exit 1
            fi

            docker compose up -d --no-deps --force-recreate remnawave-nginx > /dev/null 2>&1 &
            spinner $! "${LANG[WAITING]}"
        else
            echo -e "${COLOR_YELLOW}${LANG[PORT_8443_NOT_CONFIGURED]}${COLOR_RESET}"
        fi

        if ufw status | grep -q "8443.*ALLOW"; then
            ufw delete allow from 0.0.0.0/0 to any port 8443 proto tcp > /dev/null 2>&1
            ufw reload > /dev/null 2>&1
            if [ $? -ne 0 ]; then
                echo -e "${COLOR_RED}${LANG[UFW_RELOAD_FAILED]}${COLOR_RESET}"
                exit 1
            fi
            echo -e "${COLOR_GREEN}${LANG[PORT_8443_CLOSED]}${COLOR_RESET}"
        else
            echo -e "${COLOR_YELLOW}${LANG[PORT_8443_ALREADY_CLOSED]}${COLOR_RESET}"
        fi
    elif [ "$webserver" = "caddy" ]; then
        PANEL_DOMAIN=$(grep 'PANEL_DOMAIN=' "$dir/docker-compose.yml" | head -n 1 | sed 's/.*PANEL_DOMAIN=//; s/[[:space:]]*$//')

        if [ -z "$PANEL_DOMAIN" ]; then
            echo -e "${COLOR_RED}${LANG[CADDY_CONF_ERROR]}${COLOR_RESET}"
            exit 1
        fi

        if grep -q "https://{\$PANEL_DOMAIN}:8443 {" "$dir/Caddyfile"; then
            sed -i "s|https://{\$PANEL_DOMAIN}:8443 {|https://{\$PANEL_DOMAIN} {|g" "$dir/Caddyfile"

            sed -i "/https:\/\/{\$PANEL_DOMAIN} {/a \    bind unix/{\$CADDY_SOCKET_PATH}" "$dir/Caddyfile"

            sed -i "s|redir https://{\$PANEL_DOMAIN}:8443{uri} permanent|redir https://{\$PANEL_DOMAIN}{uri} permanent|g" "$dir/Caddyfile"

            docker compose up -d --no-deps --force-recreate remnawave-caddy > /dev/null 2>&1 &
            spinner $! "${LANG[WAITING]}"
        else
            echo -e "${COLOR_YELLOW}${LANG[PORT_8443_NOT_CONFIGURED]}${COLOR_RESET}"
        fi

        if ufw status | grep -q "8443.*ALLOW"; then
            ufw delete allow from 0.0.0.0/0 to any port 8443 proto tcp > /dev/null 2>&1
            ufw reload > /dev/null 2>&1
            if [ $? -ne 0 ]; then
                echo -e "${COLOR_RED}${LANG[UFW_RELOAD_FAILED]}${COLOR_RESET}"
                exit 1
            fi
            echo -e "${COLOR_GREEN}${LANG[PORT_8443_CLOSED]}${COLOR_RESET}"
        else
            echo -e "${COLOR_YELLOW}${LANG[PORT_8443_ALREADY_CLOSED]}${COLOR_RESET}"
        fi
    fi
}
