#!/bin/bash
# Module: Remnawave API Functions

make_api_request() {
    local method=$1
    local url=$2
    local token=$3
    local data=$4

    local headers=(
        -H "Authorization: Bearer $token"
        -H "Content-Type: application/json"
        -H "X-Forwarded-For: ${url#http://}"
        -H "X-Forwarded-Proto: https"
        -H "X-Remnawave-Client-Type: browser"
    )

    if [ -n "$data" ]; then
        curl -s -X "$method" "$url" "${headers[@]}" -d "$data"
    else
        curl -s -X "$method" "$url" "${headers[@]}"
    fi
}


register_remnawave() {
    local domain_url=$1
    local username=$2
    local password=$3
    local token=$4

    local register_data='{"username":"'"$username"'","password":"'"$password"'"}'
    local register_response=$(make_api_request "POST" "http://$domain_url/api/auth/register" "$token" "$register_data")

    if [ -z "$register_response" ]; then
        echo -e "${COLOR_RED}${LANG[ERROR_EMPTY_RESPONSE_REGISTER]}${COLOR_RESET}"
    elif [[ "$register_response" == *"accessToken"* ]]; then
        echo "$register_response" | jq -r '.response.accessToken'
    else
        echo -e "${COLOR_RED}${LANG[ERROR_REGISTER]}: $register_response${COLOR_RESET}"
    fi
}

get_panel_token() {
    TOKEN_FILE="${DIR_REMNAWAVE}/token"
    local domain_url="127.0.0.1:3000"

    local auth_status=$(make_api_request "GET" "http://${domain_url}/api/auth/status" "")
    local oauth_enabled=false

    if [ -n "$auth_status" ]; then
        local github_enabled=$(echo "$auth_status" | jq -r '.response.authentication.oauth2.providers.github // false' 2>/dev/null)
        local yandex_enabled=$(echo "$auth_status" | jq -r '.response.authentication.oauth2.providers.yandex // false' 2>/dev/null)
        local pocketid_enabled=$(echo "$auth_status" | jq -r '.response.authentication.oauth2.providers.pocketid // false' 2>/dev/null)
        local telegram_enabled=$(echo "$auth_status" | jq -r '.response.authentication.tgAuth.enabled // false' 2>/dev/null)

        if [ "$github_enabled" = "true" ] || [ "$yandex_enabled" = "true" ] || \
           [ "$pocketid_enabled" = "true" ] || [ "$telegram_enabled" = "true" ]; then
            oauth_enabled=true
        fi
    fi

    if [ -f "$TOKEN_FILE" ]; then
        token=$(cat "$TOKEN_FILE")
        echo -e "${COLOR_YELLOW}${LANG[USING_SAVED_TOKEN]}${COLOR_RESET}"
        local test_response=$(make_api_request "GET" "${domain_url}/api/config-profiles" "$token")

        if [ -z "$test_response" ] || ! echo "$test_response" | jq -e '.response.configProfiles' > /dev/null 2>&1; then
            if echo "$test_response" | grep -q '"statusCode":401' || \
               echo "$test_response" | jq -e '.message | test("Unauthorized")' > /dev/null 2>&1; then
                echo -e "${COLOR_RED}${LANG[INVALID_SAVED_TOKEN]}${COLOR_RESET}"
            else
                echo -e "${COLOR_RED}${LANG[INVALID_SAVED_TOKEN]}: $test_response${COLOR_RESET}"
            fi
            token=""
        fi
    fi

    if [ -z "$token" ]; then
        if [ "$oauth_enabled" = true ]; then
            echo -e "${COLOR_YELLOW}=================================================${COLOR_RESET}"
            echo -e "${COLOR_RED}${LANG[WARNING_LABEL]}${COLOR_RESET}"
            echo -e "${COLOR_YELLOW}${LANG[TELEGRAM_OAUTH_WARNING]}${COLOR_RESET}"
            printf "${COLOR_YELLOW}${LANG[CREATE_API_TOKEN_INSTRUCTION]}${COLOR_RESET}\n" "$PANEL_DOMAIN"
            reading "${LANG[ENTER_API_TOKEN]}" token
            if [ -z "$token" ]; then
                echo -e "${COLOR_RED}${LANG[EMPTY_TOKEN_ERROR]}${COLOR_RESET}"
                return 1
            fi

            local test_response=$(make_api_request "GET" "${domain_url}/api/config-profiles" "$token")
            if [ -z "$test_response" ] || ! echo "$test_response" | jq -e '.response.configProfiles' > /dev/null 2>&1; then
                echo -e "${COLOR_RED}${LANG[INVALID_SAVED_TOKEN]}: $test_response${COLOR_RESET}"
                return 1
            fi
        else
            reading "${LANG[ENTER_PANEL_USERNAME]}" username
            reading "${LANG[ENTER_PANEL_PASSWORD]}" password

            local login_response=$(make_api_request "POST" "${domain_url}/api/auth/login" "" "{\"username\":\"$username\",\"password\":\"$password\"}")
            token=$(echo "$login_response" | jq -r '.response.accessToken // .accessToken // ""')
            if [ -z "$token" ] || [ "$token" == "null" ]; then
                echo -e "${COLOR_RED}${LANG[ERROR_TOKEN]}: $login_response${COLOR_RESET}"
                return 1
            fi
        fi

        echo "$token" > "$TOKEN_FILE"
        echo -e "${COLOR_GREEN}${LANG[TOKEN_RECEIVED_AND_SAVED]}${COLOR_RESET}"
    else
        echo -e "${COLOR_GREEN}${LANG[TOKEN_USED_SUCCESSFULLY]}${COLOR_RESET}"
    fi

    local final_test_response=$(make_api_request "GET" "${domain_url}/api/config-profiles" "$token")
    if [ -z "$final_test_response" ] || ! echo "$final_test_response" | jq -e '.response.configProfiles' > /dev/null 2>&1; then
        echo -e "${COLOR_RED}${LANG[INVALID_SAVED_TOKEN]}: $final_test_response${COLOR_RESET}"
        return 1
    fi
}

get_public_key() {
    local domain_url=$1
    local token=$2
    local target_dir=$3

    local api_response=$(make_api_request "GET" "http://$domain_url/api/keygen" "$token")

    if [ -z "$api_response" ]; then
        echo -e "${COLOR_RED}${LANG[ERROR_PUBLIC_KEY]}${COLOR_RESET}"
    fi

    local pubkey=$(echo "$api_response" | jq -r '.response.secretKey // .response.pubKey // empty')
    if [ -z "$pubkey" ]; then
        echo -e "${COLOR_RED}${LANG[ERROR_EXTRACT_PUBLIC_KEY]}${COLOR_RESET}"
    fi

    sed -i "s|SECRET_KEY=\"PUBLIC KEY FROM REMNAWAVE-PANEL\"|SECRET_KEY=\"$pubkey\"|g" "$target_dir/docker-compose.yml"

    echo -e "${COLOR_GREEN}${LANG[PUBLIC_KEY_SUCCESS]}${COLOR_RESET}"
}

generate_xray_keys() {
    local domain_url=$1
    local token=$2

    local api_response=$(make_api_request "GET" "http://$domain_url/api/system/tools/x25519/generate" "$token")

    if [ -z "$api_response" ]; then
        echo -e "${COLOR_RED}${LANG[ERROR_GENERATE_KEYS]}${COLOR_RESET}"
        return 1
    fi

    if echo "$api_response" | jq -e '.errorCode' > /dev/null 2>&1; then
        local error_message=$(echo "$api_response" | jq -r '.message')
        echo -e "${COLOR_RED}${LANG[ERROR_GENERATE_KEYS]}: $error_message${COLOR_RESET}"
    fi

    local private_key=$(echo "$api_response" | jq -r '.response.keypairs[0].privateKey')

    if [ -z "$private_key" ] || [ "$private_key" = "null" ]; then
        echo -e "${COLOR_RED}${LANG[ERROR_EXTRACT_PRIVATE_KEY]}${COLOR_RESET}"
    fi

    echo "$private_key"
}

check_node_domain() {
    local domain_url="$1"
    local token="$2"
    local domain="$3"

    local response=$(make_api_request "GET" "http://$domain_url/api/nodes" "$token")

    if [ -z "$response" ]; then
        echo -e "${COLOR_RED}${LANG[ERROR_CHECK_DOMAIN]}${COLOR_RESET}"
        return 1
    fi

    if echo "$response" | jq -e '.response' > /dev/null 2>&1; then
        local existing_domain=$(echo "$response" | jq -r --arg addr "$domain" '.response[] | select(.address == $addr) | .address' 2>/dev/null)
        if [ -n "$existing_domain" ]; then
            echo -e "${COLOR_RED}${LANG[DOMAIN_ALREADY_EXISTS]}: $domain${COLOR_RESET}"
            return 1
        fi
        return 0
    else
        local error_message=$(echo "$response" | jq -r '.message // "Unknown error"')
        echo -e "${COLOR_RED}${LANG[ERROR_CHECK_DOMAIN]}: $error_message${COLOR_RESET}"
        return 1
    fi
}

create_node() {
    local domain_url=$1
    local token=$2
    local config_profile_uuid=$3
    local inbound_uuid=$4
    local node_address="${5:-172.30.0.1}"
    local node_name="${6:-Steal}"

    local node_data=$(cat <<EOF
{
    "name": "$node_name",
    "address": "$node_address",
    "port": 2222,
    "configProfile": {
        "activeConfigProfileUuid": "$config_profile_uuid",
        "activeInbounds": ["$inbound_uuid"]
    },
    "isTrafficTrackingActive": false,
    "trafficLimitBytes": 0,
    "notifyPercent": 0,
    "trafficResetDay": 31,
    "excludedInbounds": [],
    "countryCode": "XX",
    "consumptionMultiplier": 1.0
}
EOF
)

    local node_response=$(make_api_request "POST" "http://$domain_url/api/nodes" "$token" "$node_data")

    if [ -z "$node_response" ]; then
        echo -e "${COLOR_RED}${LANG[ERROR_EMPTY_RESPONSE_NODE]}${COLOR_RESET}"
    fi

    if echo "$node_response" | jq -e '.response.uuid' > /dev/null; then
        printf "${COLOR_GREEN}${LANG[NODE_CREATED]}${COLOR_RESET}\n"
    else
        echo -e "${COLOR_RED}${LANG[ERROR_CREATE_NODE]}${COLOR_RESET}"
    fi
}

get_config_profiles() {
    local domain_url="$1"
    local token="$2"

    local config_response=$(make_api_request "GET" "http://$domain_url/api/config-profiles" "$token")
    if [ -z "$config_response" ] || ! echo "$config_response" | jq -e '.' > /dev/null 2>&1; then
        echo -e "${COLOR_RED}${LANG[ERROR_NO_CONFIGS]}${COLOR_RESET}"
        return 1
    fi

    local profile_uuid=$(echo "$config_response" | jq -r '.response.configProfiles[] | select(.name == "Default-Profile") | .uuid' 2>/dev/null)
    if [ -z "$profile_uuid" ]; then
        echo -e "${COLOR_YELLOW}${LANG[NO_DEFAULT_PROFILE]}${COLOR_RESET}"
        return 0
    fi

    echo "$profile_uuid"
    return 0
}

delete_config_profile() {
    local domain_url="$1"
    local token="$2"
    local profile_uuid="$3"

    if [ -z "$profile_uuid" ]; then
        profile_uuid=$(get_config_profiles "$domain_url" "$token")
        if [ $? -ne 0 ] || [ -z "$profile_uuid" ]; then
            return 0
        fi
    fi

    local delete_response=$(make_api_request "DELETE" "http://$domain_url/api/config-profiles/$profile_uuid" "$token")
    if [ -z "$delete_response" ] || ! echo "$delete_response" | jq -e '.' > /dev/null 2>&1; then
        echo -e "${COLOR_RED}${LANG[ERROR_DELETE_PROFILE]}${COLOR_RESET}"
        return 1
    fi

    return 0
}

create_config_profile() {
    local domain_url=$1
    local token=$2
    local name=$3
    local domain=$4
    local private_key=$5
    local inbound_tag="${6:-Steal}"

    local short_id=$(openssl rand -hex 8)

    local request_body=$(jq -n --arg name "$name" --arg domain "$domain" --arg private_key "$private_key" --arg short_id "$short_id" --arg inbound_tag "$inbound_tag" '{
        name: $name,
        config: {
            log: { loglevel: "warning" },
            dns: {
                queryStrategy: "UseIPv4",
                servers: [{ address: "https://dns.google/dns-query", skipFallback: false }]
            },
            inbounds: [{
                tag: $inbound_tag,
                port: 443,
                protocol: "vless",
                settings: { clients: [], decryption: "none" },
                sniffing: { enabled: true, destOverride: ["http", "tls", "quic"] },
                streamSettings: {
                    network: "tcp",
                    security: "reality",
                    realitySettings: {
                        show: false,
                        xver: 1,
                        dest: "/dev/shm/nginx.sock",
                        spiderX: "",
                        shortIds: [$short_id],
                        privateKey: $private_key,
                        serverNames: [$domain]
                    }
                }
            }],
            outbounds: [
                { tag: "DIRECT", protocol: "freedom" },
                { tag: "BLOCK", protocol: "blackhole" }
            ],
            routing: {
                rules: [
                    { ip: ["geoip:private"], type: "field", outboundTag: "BLOCK" },
                    { type: "field", protocol: ["bittorrent"], outboundTag: "BLOCK" }
                ]
            }
        }
    }')

    local response=$(make_api_request "POST" "http://$domain_url/api/config-profiles" "$token" "$request_body")
    if [ -z "$response" ] || ! echo "$response" | jq -e '.response.uuid' > /dev/null; then
        echo -e "${COLOR_RED}${LANG[ERROR_CREATE_CONFIG_PROFILE]}: $response${COLOR_RESET}"
    fi

    local config_uuid=$(echo "$response" | jq -r '.response.uuid')
    local inbound_uuid=$(echo "$response" | jq -r '.response.inbounds[0].uuid')
    if [ -z "$config_uuid" ] || [ "$config_uuid" = "null" ] || [ -z "$inbound_uuid" ] || [ "$inbound_uuid" = "null" ]; then
        echo -e "${COLOR_RED}${LANG[ERROR_CREATE_CONFIG_PROFILE]}: Invalid UUIDs in response: $response${COLOR_RESET}"
    fi

    echo "$config_uuid $inbound_uuid"
}

create_host() {
    local domain_url=$1
    local token=$2
    local inbound_uuid=$3
    local address=$4
    local config_uuid=$5
    local host_remark="${6:-Steal}"

    local request_body=$(jq -n --arg config_uuid "$config_uuid" --arg inbound_uuid "$inbound_uuid" --arg remark "$host_remark" --arg address "$address" '{
        inbound: {
            configProfileUuid: $config_uuid,
            configProfileInboundUuid: $inbound_uuid
        },
        remark: $remark,
        address: $address,
        port: 443,
        path: "",
        sni: $address,
        host: "",
        alpn: null,
        fingerprint: "chrome",
        allowInsecure: false,
        isDisabled: false,
        securityLayer: "DEFAULT"
    }')

    local response=$(make_api_request "POST" "http://$domain_url/api/hosts" "$token" "$request_body")

    if [ -z "$response" ]; then
        echo -e "${COLOR_RED}${LANG[ERROR_EMPTY_RESPONSE_HOST]}${COLOR_RESET}"
    fi

    if echo "$response" | jq -e '.response.uuid' > /dev/null; then
        echo -e "${COLOR_GREEN}${LANG[HOST_CREATED]}${COLOR_RESET}"
    else
        echo -e "${COLOR_RED}${LANG[ERROR_CREATE_HOST]}${COLOR_RESET}"
    fi
}

get_default_squad() {
    local domain_url=$1
    local token=$2

    local response=$(make_api_request "GET" "http://$domain_url/api/internal-squads" "$token")
    if [ -z "$response" ] || ! echo "$response" | jq -e '.response.internalSquads' > /dev/null 2>&1; then
        echo -e "${COLOR_RED}${LANG[ERROR_GET_SQUAD]}: $response${COLOR_RESET}"
        return 1
    fi

    local squad_uuids=$(echo "$response" | jq -r '.response.internalSquads[].uuid' 2>/dev/null)
    if [ -z "$squad_uuids" ]; then
        echo -e "${COLOR_YELLOW}${LANG[NO_SQUADS_FOUND]}${COLOR_RESET}"
        return 0
    fi

    local valid_uuids=""
    while IFS= read -r uuid; do
        if [ -z "$uuid" ]; then
            continue
        fi
        if [[ $uuid =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]]; then
            valid_uuids+="$uuid\n"
        else
            echo -e "${COLOR_RED}${LANG[INVALID_UUID_FORMAT]}: $uuid${COLOR_RESET}"
        fi
    done <<< "$squad_uuids"

    if [ -z "$valid_uuids" ]; then
        echo -e "${COLOR_YELLOW}${LANG[NO_VALID_SQUADS_FOUND]}${COLOR_RESET}"
        return 0
    fi

    echo -e "$valid_uuids" | sed '/^$/d'
    return 0
}

update_squad() {
    local domain_url=$1
    local token=$2
    local squad_uuid=$3
    local inbound_uuid=$4

    if [[ ! $squad_uuid =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]]; then
        echo -e "${COLOR_RED}${LANG[INVALID_SQUAD_UUID]}: $squad_uuid${COLOR_RESET}"
        return 1
    fi

    if [[ ! $inbound_uuid =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]]; then
        echo -e "${COLOR_RED}${LANG[INVALID_INBOUND_UUID]}: $inbound_uuid${COLOR_RESET}"
        return 1
    fi

    local squad_response=$(make_api_request "GET" "http://$domain_url/api/internal-squads" "$token")
    if [ -z "$squad_response" ] || ! echo "$squad_response" | jq -e '.response.internalSquads' > /dev/null 2>&1; then
        echo -e "${COLOR_RED}${LANG[ERROR_GET_SQUAD]}: $squad_response${COLOR_RESET}"
        return 1
    fi

    local existing_inbounds=$(echo "$squad_response" | jq -r --arg uuid "$squad_uuid" '.response.internalSquads[] | select(.uuid == $uuid) | .inbounds[].uuid' 2>/dev/null)
    if [ -z "$existing_inbounds" ]; then
        existing_inbounds="[]"
    else
        existing_inbounds=$(echo "$existing_inbounds" | jq -R . | jq -s .)
    fi

    local inbounds_array=$(jq -n --argjson existing "$existing_inbounds" --arg new "$inbound_uuid" '$existing + [$new] | unique')

    local request_body=$(jq -n --arg uuid "$squad_uuid" --argjson inbounds "$inbounds_array" '{
        uuid: $uuid,
        inbounds: $inbounds
    }')

    local response=$(make_api_request "PATCH" "http://$domain_url/api/internal-squads" "$token" "$request_body")
    if [ -z "$response" ] || ! echo "$response" | jq -e '.response.uuid' > /dev/null 2>&1; then
        echo -e "${COLOR_RED}${LANG[ERROR_UPDATE_SQUAD]}: $response${COLOR_RESET}"
        return 1
    fi

    return 0
}

_upsert_env_secret() {
    local env_file="$1"
    local key="$2"
    local value="$3"
    local tmp_file found=false line

    [ -f "$env_file" ] || : > "$env_file"
    tmp_file=$(mktemp "${env_file}.tmp.XXXXXX") || return 1
    chmod 600 "$tmp_file"

    while IFS= read -r line || [ -n "$line" ]; do
        if [[ "$line" == "${key}="* ]]; then
            printf '%s=%s\n' "$key" "$value" >> "$tmp_file"
            found=true
        else
            printf '%s\n' "$line" >> "$tmp_file"
        fi
    done < "$env_file"

    if [ "$found" != true ]; then
        printf '\n%s=%s\n' "$key" "$value" >> "$tmp_file"
    fi

    mv -f "$tmp_file" "$env_file"
    chmod 600 "$env_file"
}

_configure_subscription_token_reference() {
    local compose_file="$1"

    [ -f "$compose_file" ] || return 1

    if grep -q 'REMNAWAVE_API_TOKEN=' "$compose_file"; then
        sed -i 's|REMNAWAVE_API_TOKEN=.*|REMNAWAVE_API_TOKEN=${REMNAWAVE_API_TOKEN}|' "$compose_file"
    else
        echo -e "${COLOR_RED}${LANG[ERROR_CREATE_API_TOKEN]}: REMNAWAVE_API_TOKEN is absent in docker-compose.yml${COLOR_RESET}" >&2
        return 1
    fi

    grep -Fq 'REMNAWAVE_API_TOKEN=${REMNAWAVE_API_TOKEN}' "$compose_file"
}

create_api_token() {
    local domain_url="$1"
    local token="$2"
    local target_dir="$3"
    local token_name="${4:-subscription-page}"
    local max_attempts="${5:-12}"
    local retry_delay="${6:-5}"
    local attempt body http_code api_token token_data request_name
    local curl_rc curl_error body_file error_file api_message
    local backend_state backend_health backend_restarts backend_oom

    [ -n "$token" ] || {
        echo -e "${COLOR_RED}${LANG[ERROR_CREATE_API_TOKEN]}: admin JWT is empty${COLOR_RESET}" >&2
        return 1
    }
    [ -f "$target_dir/.env" ] || {
        echo -e "${COLOR_RED}${LANG[ERROR_CREATE_API_TOKEN]}: $target_dir/.env not found${COLOR_RESET}" >&2
        return 1
    }

    # The Subpage starts with an intentionally empty token in a fresh install.
    # Stop it while the token is being created: this avoids an unhealthy retry
    # loop and reduces RAM pressure on small VPS instances.
    (
        cd "$target_dir" || exit 0
        docker compose stop remnawave-subscription-page >/dev/null 2>&1 || true
    )

    request_name="$token_name"

    for ((attempt=1; attempt<=max_attempts; attempt++)); do
        # Remnawave Panel v3 expects name/expiresInDays/scopes.  The previous
        # tokenName-only payload belongs to an older API contract and can make
        # current backends close the request without returning an HTTP body.
        token_data=$(jq -nc --arg name "$request_name" \
            '{name:$name,expiresInDays:365,scopes:["*"]}') || return 1

        body_file=$(mktemp) || return 1
        error_file=$(mktemp) || {
            rm -f "$body_file"
            return 1
        }

        http_code=$(curl -sS --http1.1 --connect-timeout 5 --max-time 30 \
            -o "$body_file" \
            -w '%{http_code}' \
            -X POST "http://$domain_url/api/tokens" \
            -H "Authorization: Bearer $token" \
            -H 'Content-Type: application/json' \
            -H 'X-Forwarded-For: 127.0.0.1' \
            -H 'X-Forwarded-Proto: https' \
            -H 'X-Remnawave-Client-Type: browser' \
            -d "$token_data" 2>"$error_file")
        curl_rc=$?
        body=$(cat "$body_file" 2>/dev/null || true)
        curl_error=$(cat "$error_file" 2>/dev/null || true)
        rm -f "$body_file" "$error_file"

        if [ "$curl_rc" -eq 0 ] && [[ "$http_code" =~ ^20[01]$ ]] && \
           printf '%s' "$body" | jq -e . >/dev/null 2>&1; then
            api_token=$(printf '%s' "$body" | jq -r '
                (.response.token //
                 .response.apiToken //
                 .response.apiKey //
                 .token //
                 .apiToken //
                 .apiKey //
                 empty) |
                if type == "object" then
                    (.token // .value // .apiToken // .apiKey // empty)
                else
                    .
                end
            ' 2>/dev/null)

            if [ -n "$api_token" ] && [ "$api_token" != "null" ] && [ "${#api_token}" -ge 20 ]; then
                _upsert_env_secret "$target_dir/.env" "REMNAWAVE_API_TOKEN" "$api_token" || {
                    unset api_token
                    echo -e "${COLOR_RED}${LANG[ERROR_CREATE_API_TOKEN]}: unable to write .env${COLOR_RESET}" >&2
                    return 1
                }
                _configure_subscription_token_reference "$target_dir/docker-compose.yml" || {
                    unset api_token
                    return 1
                }
                unset api_token body
                echo -e "${COLOR_GREEN}${LANG[API_TOKEN_ADDED]}${COLOR_RESET}" >&2
                return 0
            fi
        fi

        # A previous interrupted installation may already have created this
        # name. API token values are displayed only once, therefore create a
        # new uniquely named token instead of trying to reuse an unknown value.
        if [ "$http_code" = "409" ]; then
            request_name="${token_name}-$(date +%Y%m%d%H%M%S)-${attempt}"
        fi

        # Authentication errors are permanent; retrying the same JWT is useless.
        if [ "$http_code" = "401" ] || [ "$http_code" = "403" ]; then
            break
        fi

        if [ "$attempt" -lt "$max_attempts" ]; then
            if [ "$curl_rc" -ne 0 ]; then
                backend_state=$(docker inspect -f '{{.State.Status}}' remnawave 2>/dev/null || echo unknown)
                backend_health=$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' remnawave 2>/dev/null || echo unknown)
                backend_restarts=$(docker inspect -f '{{.RestartCount}}' remnawave 2>/dev/null || echo unknown)
                backend_oom=$(docker inspect -f '{{.State.OOMKilled}}' remnawave 2>/dev/null || echo unknown)
                echo -e "${COLOR_YELLOW}${LANG[API_TOKEN_RETRY]} ${attempt}/${max_attempts} (curl ${curl_rc}, HTTP 000; backend=${backend_state}/${backend_health}, restarts=${backend_restarts}, oom=${backend_oom})${COLOR_RESET}" >&2
                [ -n "$curl_error" ] && echo "curl: $curl_error" >&2
            else
                echo -e "${COLOR_YELLOW}${LANG[API_TOKEN_RETRY]} ${attempt}/${max_attempts} (HTTP ${http_code})${COLOR_RESET}" >&2
                if printf '%s' "$body" | jq -e . >/dev/null 2>&1; then
                    api_message=$(printf '%s' "$body" | jq -r '.message // .error // .errorCode // empty' 2>/dev/null)
                    [ -n "$api_message" ] && echo "API: $api_message" >&2
                fi
            fi
            sleep "$retry_delay"
        fi
    done

    api_message=""
    if [ "$curl_rc" -ne 0 ]; then
        api_message="curl ${curl_rc}: ${curl_error:-empty reply from server}"
    elif printf '%s' "$body" | jq -e . >/dev/null 2>&1; then
        api_message=$(printf '%s' "$body" | jq -r '.message // .error // .errorCode // empty' 2>/dev/null)
    fi
    [ -n "$api_message" ] || api_message="HTTP ${http_code:-000}"
    echo -e "${COLOR_RED}${LANG[ERROR_CREATE_API_TOKEN]}: ${api_message}${COLOR_RESET}" >&2

    # Preserve the relevant diagnostics in the installer output. Secrets are
    # not logged.
    docker inspect remnawave \
        --format 'backend: status={{.State.Status}} health={{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}} restarts={{.RestartCount}} oom={{.State.OOMKilled}} exit={{.State.ExitCode}}' \
        >&2 2>/dev/null || true
    docker logs --tail=80 remnawave >&2 2>/dev/null || true
    return 1
}

verify_subscription_page_runtime() {
    local target_dir="$1"
    local max_attempts="${2:-24}"
    local delay="${3:-5}"
    local attempt state health token_present

    (
        cd "$target_dir" || exit 1
        docker compose config -q && \
        docker compose up -d --force-recreate --no-deps remnawave-subscription-page
    ) >/dev/null 2>&1 || {
        echo -e "${COLOR_RED}${LANG[SUBPAGE_START_FAILED]}${COLOR_RESET}" >&2
        return 1
    }

    for ((attempt=1; attempt<=max_attempts; attempt++)); do
        state=$(docker inspect -f '{{.State.Status}}' remnawave-subscription-page 2>/dev/null || true)
        health=$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' remnawave-subscription-page 2>/dev/null || true)
        token_present=$(docker inspect remnawave-subscription-page \
            --format '{{range .Config.Env}}{{println .}}{{end}}' 2>/dev/null | \
            awk -F= '/^REMNAWAVE_API_TOKEN=/{if (length($2) >= 20) print "yes"}')

        if [ "$state" = "running" ] && [ "$token_present" = "yes" ] && { [ "$health" = "healthy" ] || [ "$health" = "none" ]; }; then
            echo -e "${COLOR_GREEN}${LANG[SUBPAGE_TOKEN_READY]}${COLOR_RESET}" >&2
            return 0
        fi

        if [ "$state" = "exited" ] || [ "$state" = "dead" ]; then
            break
        fi
        sleep "$delay"
    done

    echo -e "${COLOR_RED}${LANG[SUBPAGE_HEALTH_TIMEOUT]}${COLOR_RESET}" >&2
    docker logs --tail=80 remnawave-subscription-page >&2 2>/dev/null || true
    return 1
}
