#!/bin/bash
# Module: Automated Remnawave VLESS IN -> VLESS OUT server-side cascade
# Requires: remnawave_api.sh loaded before this module.

CASCADE_DIR="${DIR_REMNAWAVE}cascade_vless"
CASCADE_STATE_FILE="${CASCADE_DIR}/state.json"
CASCADE_API_HOST="127.0.0.1:3000"

cascade_msg() {
    local key="$1"
    shift || true
    local text="${LANG[$key]:-$key}"
    printf "$text\n" "$@"
}

cascade_error() {
    echo -e "${COLOR_RED}$*${COLOR_RESET}"
}

cascade_warn() {
    echo -e "${COLOR_YELLOW}$*${COLOR_RESET}"
}

cascade_ok() {
    echo -e "${COLOR_GREEN}$*${COLOR_RESET}"
}

cascade_requirements() {
    local missing=()
    local cmd
    for cmd in curl jq openssl; do
        command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
    done

    if [ ${#missing[@]} -gt 0 ]; then
        cascade_error "${LANG[CASCADE_MISSING_DEPS]}: ${missing[*]}"
        return 1
    fi

    if [ ! -d /opt/remnawave ]; then
        cascade_error "${LANG[CASCADE_PANEL_REQUIRED]}"
        return 1
    fi

    mkdir -p "$CASCADE_DIR"
    chmod 700 "$CASCADE_DIR"
}

cascade_api() {
    local method="$1"
    local path="$2"
    local data="${3:-}"
    make_api_request "$method" "http://${CASCADE_API_HOST}${path}" "$token" "$data"
}

cascade_response_ok() {
    local response="$1"
    [ -n "$response" ] || return 1
    echo "$response" | jq -e . >/dev/null 2>&1 || return 1
    if echo "$response" | jq -e '(.statusCode? // 0) >= 400 or (.errorCode? != null)' >/dev/null 2>&1; then
        return 1
    fi
    return 0
}

cascade_uuid() {
    if command -v uuidgen >/dev/null 2>&1; then
        uuidgen | tr '[:upper:]' '[:lower:]'
    elif [ -r /proc/sys/kernel/random/uuid ]; then
        cat /proc/sys/kernel/random/uuid
    else
        python3 - <<'PY'
import uuid
print(uuid.uuid4())
PY
    fi
}

cascade_valid_port() {
    [[ "$1" =~ ^[0-9]+$ ]] && [ "$1" -ge 1 ] && [ "$1" -le 65535 ]
}

cascade_safe_name() {
    echo "$1" | tr -cs '[:alnum:]_-' '_' | cut -c1-36
}

cascade_get_nodes() {
    cascade_api GET "/api/nodes"
}

cascade_get_node() {
    cascade_api GET "/api/nodes/$1"
}

cascade_get_profile() {
    cascade_api GET "/api/config-profiles/$1"
}

# Remnawave requires inbound tags to be globally unique, therefore copying an
# active profile can fail even when the clone name itself is valid.  New cascade
# installations update the two selected profiles in place and keep full snapshots
# for rollback.  Support both profile-update API forms used by Panel 3.x builds.
cascade_update_profile() {
    local uuid="$1"
    local name="$2"
    local config="$3"
    local payload response payload_by_uuid response_by_uuid

    payload=$(jq -n \
        --arg uuid "$uuid" \
        --arg name "$name" \
        --argjson config "$config" \
        '{uuid:$uuid,name:$name,config:$config}') || return 1
    response=$(cascade_api PATCH "/api/config-profiles" "$payload")
    if cascade_response_ok "$response"; then
        printf '%s' "$response"
        return 0
    fi

    payload_by_uuid=$(jq -n \
        --arg name "$name" \
        --argjson config "$config" \
        '{name:$name,config:$config}') || return 1
    response_by_uuid=$(cascade_api PATCH "/api/config-profiles/$uuid" "$payload_by_uuid")
    if cascade_response_ok "$response_by_uuid"; then
        printf '%s' "$response_by_uuid"
        return 0
    fi

    printf '%s' "${response_by_uuid:-$response}"
    return 1
}

cascade_restore_profile_snapshot() {
    local node_uuid="$1"
    local profile_uuid="$2"
    local profile_name="$3"
    local config="$4"
    local active_tags="$5"
    local response profile_response active_inbounds

    response=$(cascade_update_profile "$profile_uuid" "$profile_name" "$config") || return 1
    profile_response=$(cascade_get_profile "$profile_uuid")
    cascade_response_ok "$profile_response" || return 1
    active_inbounds=$(cascade_map_active_tags "$profile_response" "$active_tags")
    jq -e 'type == "array"' >/dev/null 2>&1 <<< "$active_inbounds" || return 1
    cascade_assign_profile "$node_uuid" "$profile_uuid" "$active_inbounds"
}

cascade_apply_profile_snapshot() {
    local node_uuid="$1"
    local profile_uuid="$2"
    local profile_name="$3"
    local config="$4"
    local active_tags="$5"
    local extra_tag="${6:-}"
    local response profile_response active_inbounds extra_uuid

    response=$(cascade_update_profile "$profile_uuid" "$profile_name" "$config") || {
        [ -n "$response" ] && cascade_error "$response"
        return 1
    }
    profile_response=$(cascade_get_profile "$profile_uuid")
    cascade_response_ok "$profile_response" || return 1
    active_inbounds=$(cascade_map_active_tags "$profile_response" "$active_tags")
    jq -e 'type == "array"' >/dev/null 2>&1 <<< "$active_inbounds" || return 1

    if [ -n "$extra_tag" ]; then
        extra_uuid=$(echo "$profile_response" | jq -r --arg tag "$extra_tag" '.response.inbounds[]? | select(.tag == $tag) | .uuid' | head -n1)
        [ -n "$extra_uuid" ] || return 1
        active_inbounds=$(jq -c --arg uuid "$extra_uuid" '. + [$uuid] | map(select(length > 0)) | unique' <<< "$active_inbounds")
        CASCADE_APPLIED_EXTRA_UUID="$extra_uuid"
    else
        CASCADE_APPLIED_EXTRA_UUID=""
    fi

    cascade_assign_profile "$node_uuid" "$profile_uuid" "$active_inbounds" || return 1
    CASCADE_APPLIED_ACTIVE_INBOUNDS="$active_inbounds"
    CASCADE_APPLIED_PROFILE_RESPONSE="$profile_response"
}

cascade_verify_profile_assignment() {
    local node_uuid="$1"
    local profile_uuid="$2"
    local inbound_uuids="$3"
    local attempt node_response current_profile current_inbounds expected actual

    expected=$(jq -c 'map(select(type == "string" and length > 0)) | unique | sort' <<< "$inbound_uuids") || return 1

    # The bulk profile-modification endpoint may complete asynchronously and may
    # answer with HTTP 204 (empty body). Verify the state instead of treating an
    # empty response as an error.
    for attempt in 1 2 3 4 5 6 7 8 9 10; do
        node_response=$(cascade_get_node "$node_uuid")
        if cascade_response_ok "$node_response"; then
            current_profile=$(jq -r '.response.configProfile.activeConfigProfileUuid // empty' <<< "$node_response")
            current_inbounds=$(jq -c '[.response.configProfile.activeInbounds[]?.uuid] | map(select(type == "string" and length > 0)) | unique | sort' <<< "$node_response")
            if [ "$current_profile" = "$profile_uuid" ]; then
                actual="$current_inbounds"
                if jq -e --argjson expected "$expected" --argjson actual "$actual" '$expected == $actual' >/dev/null 2>&1 <<< '{}'; then
                    return 0
                fi
            fi
        fi
        sleep 0.25
    done

    return 1
}

cascade_assign_profile() {
    local node_uuid="$1"
    local profile_uuid="$2"
    local inbound_uuids="$3"
    local payload response

    payload=$(jq -n \
        --arg node "$node_uuid" \
        --arg profile "$profile_uuid" \
        --argjson inbounds "$inbound_uuids" \
        '{uuids:[$node], configProfile:{activeConfigProfileUuid:$profile, activeInbounds:$inbounds}}') || return 1

    response=$(cascade_api POST "/api/nodes/bulk-actions/profile-modification" "$payload")

    # Some Remnawave versions return JSON here, while others return 204 No
    # Content. A non-empty API error is still fatal. For an empty/success-shaped
    # response, verify the node's actual assignment before continuing.
    if [ -n "$response" ] && ! cascade_response_ok "$response"; then
        cascade_error "Remnawave profile-modification API: $response"
        return 1
    fi

    if cascade_verify_profile_assignment "$node_uuid" "$profile_uuid" "$inbound_uuids"; then
        return 0
    fi

    cascade_error "Remnawave profile-modification was not confirmed on node $node_uuid."
    return 1
}

cascade_restart_node() {
    local node_uuid="$1"
    local response
    response=$(cascade_api POST "/api/nodes/${node_uuid}/actions/restart" '{"forceRestart":false}')
    cascade_response_ok "$response"
}

cascade_delete_resource() {
    local path="$1"
    local response
    response=$(cascade_api DELETE "$path")
    if [ -z "$response" ]; then
        return 0
    fi
    cascade_response_ok "$response"
}

cascade_map_active_tags() {
    local profile_response="$1"
    local tags_json="$2"
    echo "$profile_response" | jq -c --argjson tags "$tags_json" \
        '[.response.inbounds[]? | select(.tag as $tag | ($tags | index($tag)) != null) | .uuid]'
}

cascade_select_node() {
    local nodes_response="$1"
    local prompt="$2"
    local exclude_uuid="${3:-}"
    local rows=()
    local i=1
    local uuid name address connected disabled

    CASCADE_SELECTED_NODE_UUID=""

    while IFS=$'\t' read -r uuid name address connected disabled; do
        [ -n "$uuid" ] || continue
        [ "$uuid" = "$exclude_uuid" ] && continue
        rows+=("$uuid")
        printf "${COLOR_YELLOW}%d.${COLOR_RESET} %s  ${COLOR_GRAY}[%s, %s]%s${COLOR_RESET}\n" \
            "$i" "$name" "$address" \
            "$([ "$connected" = "true" ] && echo "online" || echo "offline")" \
            "$([ "$disabled" = "true" ] && echo ", disabled" || true)"
        i=$((i + 1))
    done < <(echo "$nodes_response" | jq -r '.response[] | [.uuid,.name,.address,(.isConnected|tostring),(.isDisabled|tostring)] | @tsv')

    if [ ${#rows[@]} -eq 0 ]; then
        return 1
    fi

    local choice
    reading "$prompt" choice
    if ! [[ "$choice" =~ ^[0-9]+$ ]] || [ "$choice" -lt 1 ] || [ "$choice" -gt ${#rows[@]} ]; then
        cascade_error "${LANG[INVALID_CHOICE]}"
        return 1
    fi

    CASCADE_SELECTED_NODE_UUID="${rows[$((choice - 1))]}"
}

cascade_choose_entry_tags() {
    local node_response="$1"
    local tags=()
    local i=1
    local tag uuid

    CASCADE_SELECTED_ENTRY_TAGS_JSON=""

    echo -e "${COLOR_GREEN}${LANG[CASCADE_SELECT_ENTRY_INBOUNDS]}${COLOR_RESET}"
    while IFS=$'\t' read -r tag uuid; do
        [ -n "$tag" ] || continue
        tags+=("$tag")
        printf "${COLOR_YELLOW}%d.${COLOR_RESET} %s ${COLOR_GRAY}[%s]${COLOR_RESET}\n" "$i" "$tag" "$uuid"
        i=$((i + 1))
    done < <(echo "$node_response" | jq -r '.response.configProfile.activeInbounds[]? | [.tag,.uuid] | @tsv')

    if [ ${#tags[@]} -eq 0 ]; then
        cascade_error "${LANG[CASCADE_NO_ACTIVE_INBOUNDS]}"
        return 1
    fi

    echo -e "${COLOR_YELLOW}0.${COLOR_RESET} ${LANG[CASCADE_ALL_ACTIVE_INBOUNDS]}"
    local choice
    reading "${LANG[CASCADE_ENTRY_INBOUND_PROMPT]}" choice

    if [ "$choice" = "0" ]; then
        CASCADE_SELECTED_ENTRY_TAGS_JSON=$(printf '%s\n' "${tags[@]}" | jq -R . | jq -sc .)
        return 0
    fi

    local selected=()
    local part
    IFS=',' read -ra parts <<< "$choice"
    for part in "${parts[@]}"; do
        part="${part//[[:space:]]/}"
        if ! [[ "$part" =~ ^[0-9]+$ ]] || [ "$part" -lt 1 ] || [ "$part" -gt ${#tags[@]} ]; then
            cascade_error "${LANG[INVALID_CHOICE]}"
            return 1
        fi
        selected+=("${tags[$((part - 1))]}")
    done

    CASCADE_SELECTED_ENTRY_TAGS_JSON=$(printf '%s\n' "${selected[@]}" | awk '!seen[$0]++' | jq -R . | jq -sc .)
}

cascade_build_exit_config() {
    local original_config="$1"
    local bridge_tag="$2"
    local bridge_port="$3"
    local private_key="$4"
    local short_id="$5"
    local reality_target="$6"
    local reality_sni="$7"

    jq -c \
        --arg tag "$bridge_tag" \
        --argjson port "$bridge_port" \
        --arg privateKey "$private_key" \
        --arg shortId "$short_id" \
        --arg target "$reality_target" \
        --arg sni "$reality_sni" '
        .inbounds = ((.inbounds // []) | map(select(.tag != $tag)) + [{
            tag: $tag,
            listen: "0.0.0.0",
            port: $port,
            protocol: "vless",
            settings: {clients: [], decryption: "none"},
            sniffing: {enabled: true, destOverride: ["http","tls","quic"], routeOnly: true},
            streamSettings: {
                network: "raw",
                security: "reality",
                realitySettings: {
                    show: false,
                    xver: 0,
                    target: $target,
                    shortIds: [$shortId],
                    privateKey: $privateKey,
                    serverNames: [$sni]
                }
            }
        }])
        | .outbounds = (.outbounds // [])
        | if ([.outbounds[]?.tag] | index("DIRECT")) == null then .outbounds += [{tag:"DIRECT",protocol:"freedom"}] else . end
        | if ([.outbounds[]?.tag] | index("BLOCK")) == null then .outbounds += [{tag:"BLOCK",protocol:"blackhole"}] else . end
        | .routing = (.routing // {rules:[]})
        | .routing.rules = (.routing.rules // [])
    ' <<< "$original_config"
}

cascade_build_entry_config() {
    local original_config="$1"
    local outbound_tag="$2"
    local exit_address="$3"
    local bridge_port="$4"
    local service_vless_uuid="$5"
    local public_key="$6"
    local short_id="$7"
    local reality_sni="$8"
    local entry_tags_json="$9"
    local routing_mode="${10}"

    local config
    config=$(jq -c \
        --arg tag "$outbound_tag" \
        --arg address "$exit_address" \
        --argjson port "$bridge_port" \
        --arg userUuid "$service_vless_uuid" \
        --arg publicKey "$public_key" \
        --arg shortId "$short_id" \
        --arg sni "$reality_sni" '
        .outbounds = ((.outbounds // []) | map(select(.tag != $tag)) + [{
            tag: $tag,
            protocol: "vless",
            settings: {
                vnext: [{
                    address: $address,
                    port: $port,
                    users: [{id: $userUuid, encryption: "none", level: 0}]
                }]
            },
            streamSettings: {
                network: "raw",
                security: "reality",
                realitySettings: {
                    serverName: $sni,
                    fingerprint: "chrome",
                    password: $publicKey,
                    shortId: $shortId,
                    spiderX: ""
                }
            },
            mux: {enabled: false}
        }])
        | if ([.outbounds[]?.tag] | index("DIRECT")) == null then .outbounds += [{tag:"DIRECT",protocol:"freedom"}] else . end
        | if ([.outbounds[]?.tag] | index("BLOCK")) == null then .outbounds += [{tag:"BLOCK",protocol:"blackhole"}] else . end
        | .routing = (.routing // {rules:[]})
        | .routing.rules = ((.routing.rules // []) | map(select(((.ruleTag // "") | startswith("REMNA_CASCADE_")) | not)))
    ' <<< "$original_config") || return 1

    # Xray applies the first matching routing rule. Keep security/API guards first,
    # then insert cascade rules before generic catch-all rules already in the profile.
    if [ "$routing_mode" = "ru_direct" ]; then
        config=$(jq -c \
            --arg out "$outbound_tag" \
            --argjson tags "$entry_tags_json" '
            ([.outbounds[]? | select(.protocol == "blackhole") | .tag] | map(select(type == "string" and length > 0))) as $blackholeTags
            | def cascade_guard:
                (.outboundTag // "") as $outTag
                | ($outTag == "BLOCK") or
                  (($blackholeTags | index($outTag)) != null) or
                  (((.inboundTag // []) | map(ascii_downcase | contains("api")) | any));
            (.routing.rules // []) as $rules
            | ($rules | map(select(cascade_guard))) as $guards
            | ($rules | map(select(cascade_guard | not))) as $rest
            | .routing.rules = ($guards + [
                {type:"field",ruleTag:"REMNA_CASCADE_RU_IP",inboundTag:$tags,ip:["geoip:ru"],outboundTag:"DIRECT"},
                {type:"field",ruleTag:"REMNA_CASCADE_RU_DOMAIN",inboundTag:$tags,domain:["geosite:category-ru"],outboundTag:"DIRECT"},
                {type:"field",ruleTag:"REMNA_CASCADE_DEFAULT",inboundTag:$tags,network:"tcp,udp",outboundTag:$out}
            ] + $rest)
        ' <<< "$config") || return 1
    else
        config=$(jq -c \
            --arg out "$outbound_tag" \
            --argjson tags "$entry_tags_json" '
            ([.outbounds[]? | select(.protocol == "blackhole") | .tag] | map(select(type == "string" and length > 0))) as $blackholeTags
            | def cascade_guard:
                (.outboundTag // "") as $outTag
                | ($outTag == "BLOCK") or
                  (($blackholeTags | index($outTag)) != null) or
                  (((.inboundTag // []) | map(ascii_downcase | contains("api")) | any));
            (.routing.rules // []) as $rules
            | ($rules | map(select(cascade_guard))) as $guards
            | ($rules | map(select(cascade_guard | not))) as $rest
            | .routing.rules = ($guards + [
                {type:"field",ruleTag:"REMNA_CASCADE_DEFAULT",inboundTag:$tags,network:"tcp,udp",outboundTag:$out}
            ] + $rest)
        ' <<< "$config") || return 1
    fi

    echo "$config"
}

cascade_partial_cleanup() {
    local original_entry_node_uuid="$1"
    local original_entry_profile_uuid="$2"
    local original_entry_inbounds="$3"
    local original_exit_node_uuid="$4"
    local original_exit_profile_uuid="$5"
    local original_exit_inbounds="$6"
    local entry_assigned="$7"
    local exit_assigned="$8"
    local entry_profile_uuid="$9"
    local exit_profile_uuid="${10}"
    local service_user_uuid="${11}"
    local squad_uuid="${12}"

    cascade_warn "${LANG[CASCADE_ROLLBACK]}"

    if [ "$entry_assigned" = "true" ]; then
        cascade_assign_profile "$original_entry_node_uuid" "$original_entry_profile_uuid" "$original_entry_inbounds" >/dev/null 2>&1 || true
    fi
    if [ "$exit_assigned" = "true" ]; then
        cascade_assign_profile "$original_exit_node_uuid" "$original_exit_profile_uuid" "$original_exit_inbounds" >/dev/null 2>&1 || true
    fi

    [ -n "$service_user_uuid" ] && cascade_delete_resource "/api/users/$service_user_uuid" >/dev/null 2>&1 || true
    [ -n "$squad_uuid" ] && cascade_delete_resource "/api/internal-squads/$squad_uuid" >/dev/null 2>&1 || true
    [ -n "$entry_profile_uuid" ] && cascade_delete_resource "/api/config-profiles/$entry_profile_uuid" >/dev/null 2>&1 || true
    [ -n "$exit_profile_uuid" ] && cascade_delete_resource "/api/config-profiles/$exit_profile_uuid" >/dev/null 2>&1 || true
}

cascade_partial_cleanup_in_place() {
    local entry_modified="$1"
    local exit_modified="$2"
    local entry_node_uuid="$3"
    local entry_profile_uuid="$4"
    local entry_profile_name="$5"
    local entry_original_config="$6"
    local entry_original_tags="$7"
    local exit_node_uuid="$8"
    local exit_profile_uuid="$9"
    local exit_profile_name="${10}"
    local exit_original_config="${11}"
    local exit_original_tags="${12}"
    local service_user_uuid="${13}"
    local squad_uuid="${14}"

    cascade_warn "${LANG[CASCADE_ROLLBACK]}"

    [ -n "$service_user_uuid" ] && cascade_delete_resource "/api/users/$service_user_uuid" >/dev/null 2>&1 || true
    [ -n "$squad_uuid" ] && cascade_delete_resource "/api/internal-squads/$squad_uuid" >/dev/null 2>&1 || true

    if [ "$entry_modified" = "true" ]; then
        cascade_restore_profile_snapshot "$entry_node_uuid" "$entry_profile_uuid" "$entry_profile_name" "$entry_original_config" "$entry_original_tags" >/dev/null 2>&1 || true
        cascade_restart_node "$entry_node_uuid" >/dev/null 2>&1 || true
    fi
    if [ "$exit_modified" = "true" ]; then
        cascade_restore_profile_snapshot "$exit_node_uuid" "$exit_profile_uuid" "$exit_profile_name" "$exit_original_config" "$exit_original_tags" >/dev/null 2>&1 || true
        cascade_restart_node "$exit_node_uuid" >/dev/null 2>&1 || true
    fi
}

create_vless_cascade() {
    cascade_requirements || return 1

    if [ -e "$CASCADE_STATE_FILE" ]; then
        cascade_warn "${LANG[CASCADE_ALREADY_EXISTS]}"
        return 1
    fi

    load_api_module >/dev/null 2>&1 || true
    get_panel_token || return 1

    local nodes_response
    nodes_response=$(cascade_get_nodes)
    if ! cascade_response_ok "$nodes_response" || [ "$(echo "$nodes_response" | jq '.response | length')" -lt 2 ]; then
        cascade_error "${LANG[CASCADE_NEED_TWO_NODES]}"
        return 1
    fi

    echo -e "\n${COLOR_GREEN}${LANG[CASCADE_SELECT_ENTRY_NODE]}${COLOR_RESET}"
    local entry_node_uuid
    cascade_select_node "$nodes_response" "${LANG[CASCADE_NODE_PROMPT]}" || return 1
    entry_node_uuid="$CASCADE_SELECTED_NODE_UUID"

    echo -e "\n${COLOR_GREEN}${LANG[CASCADE_SELECT_EXIT_NODE]}${COLOR_RESET}"
    local exit_node_uuid
    cascade_select_node "$nodes_response" "${LANG[CASCADE_NODE_PROMPT]}" "$entry_node_uuid" || return 1
    exit_node_uuid="$CASCADE_SELECTED_NODE_UUID"

    local entry_node_response exit_node_response
    entry_node_response=$(cascade_get_node "$entry_node_uuid")
    exit_node_response=$(cascade_get_node "$exit_node_uuid")
    cascade_response_ok "$entry_node_response" || { cascade_error "${LANG[CASCADE_NODE_READ_ERROR]}"; return 1; }
    cascade_response_ok "$exit_node_response" || { cascade_error "${LANG[CASCADE_NODE_READ_ERROR]}"; return 1; }

    local entry_profile_uuid exit_profile_uuid
    entry_profile_uuid=$(echo "$entry_node_response" | jq -r '.response.configProfile.activeConfigProfileUuid // empty')
    exit_profile_uuid=$(echo "$exit_node_response" | jq -r '.response.configProfile.activeConfigProfileUuid // empty')
    if [ -z "$entry_profile_uuid" ] || [ -z "$exit_profile_uuid" ]; then
        cascade_error "${LANG[CASCADE_PROFILE_REQUIRED]}"
        return 1
    fi
    if [ "$entry_profile_uuid" = "$exit_profile_uuid" ]; then
        cascade_error "${LANG[CASCADE_SHARED_PROFILE_ERROR]}"
        return 1
    fi

    local entry_name exit_name exit_default_address
    entry_name=$(echo "$entry_node_response" | jq -r '.response.name')
    exit_name=$(echo "$exit_node_response" | jq -r '.response.name')
    exit_default_address=$(echo "$exit_node_response" | jq -r '.response.address')

    local entry_tags_json
    cascade_choose_entry_tags "$entry_node_response" || return 1
    entry_tags_json="$CASCADE_SELECTED_ENTRY_TAGS_JSON"

    local exit_address
    reading "$(printf "${LANG[CASCADE_EXIT_ADDRESS_PROMPT]}" "$exit_default_address")" exit_address
    exit_address="${exit_address:-$exit_default_address}"
    [ -n "$exit_address" ] || { cascade_error "${LANG[CASCADE_INVALID_ADDRESS]}"; return 1; }

    local bridge_port
    reading "${LANG[CASCADE_PORT_PROMPT]}" bridge_port
    bridge_port="${bridge_port:-8443}"
    cascade_valid_port "$bridge_port" || { cascade_error "${LANG[CASCADE_INVALID_PORT]}"; return 1; }

    local reality_sni reality_target
    reading "${LANG[CASCADE_SNI_PROMPT]}" reality_sni
    reality_sni="${reality_sni:-www.cloudflare.com}"
    reading "$(printf "${LANG[CASCADE_TARGET_PROMPT]}" "${reality_sni}:443")" reality_target
    reality_target="${reality_target:-${reality_sni}:443}"

    echo -e "\n${COLOR_GREEN}${LANG[CASCADE_ROUTING_MODE]}${COLOR_RESET}"
    echo -e "${COLOR_YELLOW}1.${COLOR_RESET} ${LANG[CASCADE_ROUTE_ALL]}"
    echo -e "${COLOR_YELLOW}2.${COLOR_RESET} ${LANG[CASCADE_ROUTE_RU_DIRECT]}"
    local route_choice routing_mode
    reading "${LANG[CASCADE_ROUTING_PROMPT]}" route_choice
    case "$route_choice" in
        2) routing_mode="ru_direct" ;;
        *) routing_mode="all" ;;
    esac

    local entry_profile_response exit_profile_response
    entry_profile_response=$(cascade_get_profile "$entry_profile_uuid")
    exit_profile_response=$(cascade_get_profile "$exit_profile_uuid")
    cascade_response_ok "$entry_profile_response" || { cascade_error "${LANG[CASCADE_PROFILE_READ_ERROR]}"; return 1; }
    cascade_response_ok "$exit_profile_response" || { cascade_error "${LANG[CASCADE_PROFILE_READ_ERROR]}"; return 1; }

    local entry_profile_name exit_profile_name entry_original_config exit_original_config
    entry_profile_name=$(echo "$entry_profile_response" | jq -r '.response.name // "Profile"')
    exit_profile_name=$(echo "$exit_profile_response" | jq -r '.response.name // "Profile"')
    entry_original_config=$(echo "$entry_profile_response" | jq -c '.response.config')
    exit_original_config=$(echo "$exit_profile_response" | jq -c '.response.config')

    if echo "$exit_original_config" | jq -e --argjson port "$bridge_port" '.inbounds[]? | select(.port == $port)' >/dev/null; then
        cascade_error "$(printf "${LANG[CASCADE_PORT_IN_USE]}" "$bridge_port")"
        return 1
    fi

    local key_response private_key public_key short_id
    key_response=$(cascade_api GET "/api/system/tools/x25519/generate")
    cascade_response_ok "$key_response" || { cascade_error "${LANG[CASCADE_KEYGEN_ERROR]}"; return 1; }
    private_key=$(echo "$key_response" | jq -r '.response.keypairs[0].privateKey // empty')
    public_key=$(echo "$key_response" | jq -r '.response.keypairs[0].publicKey // empty')
    short_id=$(openssl rand -hex 8)
    [ -n "$private_key" ] && [ -n "$public_key" ] || { cascade_error "${LANG[CASCADE_KEYGEN_ERROR]}"; return 1; }

    local stamp bridge_tag outbound_tag
    stamp=$(date +%Y%m%d%H%M%S)
    bridge_tag="BRIDGE_VLESS_IN_${stamp}"
    outbound_tag="VLESS_OUT_${stamp}"

    local original_entry_inbounds original_exit_inbounds original_entry_tags original_exit_tags
    original_entry_inbounds=$(echo "$entry_node_response" | jq -c '[.response.configProfile.activeInbounds[]?.uuid]')
    original_exit_inbounds=$(echo "$exit_node_response" | jq -c '[.response.configProfile.activeInbounds[]?.uuid]')
    original_entry_tags=$(echo "$entry_node_response" | jq -c '[.response.configProfile.activeInbounds[]?.tag]')
    original_exit_tags=$(echo "$exit_node_response" | jq -c '[.response.configProfile.activeInbounds[]?.tag]')

    local exit_config entry_config
    exit_config=$(cascade_build_exit_config "$exit_original_config" "$bridge_tag" "$bridge_port" "$private_key" "$short_id" "$reality_target" "$reality_sni") || {
        cascade_error "${LANG[CASCADE_CONFIG_BUILD_ERROR]}"; return 1;
    }

    local exit_modified=false entry_modified=false
    local squad_uuid="" service_user_uuid="" service_vless_uuid="" bridge_inbound_uuid=""

    if ! cascade_apply_profile_snapshot "$exit_node_uuid" "$exit_profile_uuid" "$exit_profile_name" "$exit_config" "$original_exit_tags" "$bridge_tag"; then
        cascade_error "${LANG[CASCADE_EXIT_PROFILE_UPDATE_ERROR]}"
        cascade_restore_profile_snapshot "$exit_node_uuid" "$exit_profile_uuid" "$exit_profile_name" "$exit_original_config" "$original_exit_tags" >/dev/null 2>&1 || true
        return 1
    fi
    exit_modified=true
    bridge_inbound_uuid="$CASCADE_APPLIED_EXTRA_UUID"

    local squad_name squad_payload squad_response
    squad_name="Cascade Bridge ${stamp}"
    squad_payload=$(jq -n --arg name "$squad_name" --arg inbound "$bridge_inbound_uuid" '{name:$name,inbounds:[$inbound]}')
    squad_response=$(cascade_api POST "/api/internal-squads" "$squad_payload")
    if ! cascade_response_ok "$squad_response"; then
        cascade_error "${LANG[CASCADE_SQUAD_CREATE_ERROR]}: $squad_response"
        cascade_partial_cleanup_in_place "$entry_modified" "$exit_modified" "$entry_node_uuid" "$entry_profile_uuid" "$entry_profile_name" "$entry_original_config" "$original_entry_tags" "$exit_node_uuid" "$exit_profile_uuid" "$exit_profile_name" "$exit_original_config" "$original_exit_tags" "$service_user_uuid" "$squad_uuid"
        return 1
    fi
    squad_uuid=$(echo "$squad_response" | jq -r '.response.uuid // empty')
    [ -n "$squad_uuid" ] || {
        cascade_error "${LANG[CASCADE_RESOURCE_ID_ERROR]}"
        cascade_partial_cleanup_in_place "$entry_modified" "$exit_modified" "$entry_node_uuid" "$entry_profile_uuid" "$entry_profile_name" "$entry_original_config" "$original_entry_tags" "$exit_node_uuid" "$exit_profile_uuid" "$exit_profile_name" "$exit_original_config" "$original_exit_tags" "$service_user_uuid" "$squad_uuid"
        return 1
    }

    local service_username user_payload user_response
    service_username=$(cascade_safe_name "cascade_bridge_${stamp}")
    service_vless_uuid=$(cascade_uuid)
    user_payload=$(jq -n \
        --arg username "$service_username" \
        --arg vless "$service_vless_uuid" \
        --arg squad "$squad_uuid" \
        '{username:$username,status:"ACTIVE",vlessUuid:$vless,trafficLimitBytes:0,trafficLimitStrategy:"NO_RESET",expireAt:"2099-12-31T23:59:59.000Z",description:"Service user for automated VLESS server-side cascade",activeInternalSquads:[$squad]}')
    user_response=$(cascade_api POST "/api/users" "$user_payload")
    if ! cascade_response_ok "$user_response"; then
        cascade_error "${LANG[CASCADE_USER_CREATE_ERROR]}: $user_response"
        cascade_partial_cleanup_in_place "$entry_modified" "$exit_modified" "$entry_node_uuid" "$entry_profile_uuid" "$entry_profile_name" "$entry_original_config" "$original_entry_tags" "$exit_node_uuid" "$exit_profile_uuid" "$exit_profile_name" "$exit_original_config" "$original_exit_tags" "$service_user_uuid" "$squad_uuid"
        return 1
    fi
    service_user_uuid=$(echo "$user_response" | jq -r '.response.uuid // empty')
    service_vless_uuid=$(echo "$user_response" | jq -r '.response.vlessUuid // empty')
    if [ -z "$service_user_uuid" ] || [ -z "$service_vless_uuid" ]; then
        cascade_error "${LANG[CASCADE_RESOURCE_ID_ERROR]}"
        cascade_partial_cleanup_in_place "$entry_modified" "$exit_modified" "$entry_node_uuid" "$entry_profile_uuid" "$entry_profile_name" "$entry_original_config" "$original_entry_tags" "$exit_node_uuid" "$exit_profile_uuid" "$exit_profile_name" "$exit_original_config" "$original_exit_tags" "$service_user_uuid" "$squad_uuid"
        return 1
    fi

    entry_config=$(cascade_build_entry_config "$entry_original_config" "$outbound_tag" "$exit_address" "$bridge_port" "$service_vless_uuid" "$public_key" "$short_id" "$reality_sni" "$entry_tags_json" "$routing_mode") || {
        cascade_error "${LANG[CASCADE_CONFIG_BUILD_ERROR]}"
        cascade_partial_cleanup_in_place "$entry_modified" "$exit_modified" "$entry_node_uuid" "$entry_profile_uuid" "$entry_profile_name" "$entry_original_config" "$original_entry_tags" "$exit_node_uuid" "$exit_profile_uuid" "$exit_profile_name" "$exit_original_config" "$original_exit_tags" "$service_user_uuid" "$squad_uuid"
        return 1
    }

    if ! cascade_apply_profile_snapshot "$entry_node_uuid" "$entry_profile_uuid" "$entry_profile_name" "$entry_config" "$original_entry_tags"; then
        cascade_error "${LANG[CASCADE_ENTRY_PROFILE_UPDATE_ERROR]}"
        cascade_restore_profile_snapshot "$entry_node_uuid" "$entry_profile_uuid" "$entry_profile_name" "$entry_original_config" "$original_entry_tags" >/dev/null 2>&1 || true
        cascade_partial_cleanup_in_place "$entry_modified" "$exit_modified" "$entry_node_uuid" "$entry_profile_uuid" "$entry_profile_name" "$entry_original_config" "$original_entry_tags" "$exit_node_uuid" "$exit_profile_uuid" "$exit_profile_name" "$exit_original_config" "$original_exit_tags" "$service_user_uuid" "$squad_uuid"
        return 1
    fi
    entry_modified=true

    local state
    state=$(jq -n \
        --arg createdAt "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        --arg entryNodeUuid "$entry_node_uuid" --arg entryNodeName "$entry_name" \
        --arg exitNodeUuid "$exit_node_uuid" --arg exitNodeName "$exit_name" \
        --arg entryProfileUuid "$entry_profile_uuid" --arg entryProfileName "$entry_profile_name" \
        --arg exitProfileUuid "$exit_profile_uuid" --arg exitProfileName "$exit_profile_name" \
        --argjson originalEntryConfig "$entry_original_config" --argjson originalExitConfig "$exit_original_config" \
        --argjson entryIntegrationConfig "$entry_config" --argjson exitIntegrationConfig "$exit_config" \
        --argjson originalEntryInbounds "$original_entry_inbounds" --argjson originalExitInbounds "$original_exit_inbounds" \
        --arg bridgeInboundUuid "$bridge_inbound_uuid" --arg bridgeInboundTag "$bridge_tag" \
        --arg outboundTag "$outbound_tag" \
        --arg squadUuid "$squad_uuid" --arg squadName "$squad_name" \
        --arg serviceUserUuid "$service_user_uuid" --arg serviceUsername "$service_username" \
        --arg serviceVlessUuid "$service_vless_uuid" \
        --arg exitAddress "$exit_address" --argjson bridgePort "$bridge_port" \
        --arg realitySni "$reality_sni" --arg realityTarget "$reality_target" \
        --arg publicKey "$public_key" --arg shortId "$short_id" \
        --arg routingMode "$routing_mode" --argjson entryInboundTags "$entry_tags_json" \
        --argjson originalEntryTags "$original_entry_tags" --argjson originalExitTags "$original_exit_tags" \
        '{version:3,enabled:true,profileMode:"in_place",createdAt:$createdAt,
          entry:{nodeUuid:$entryNodeUuid,nodeName:$entryNodeName,originalProfileUuid:$entryProfileUuid,cascadeProfileUuid:$entryProfileUuid,profileName:$entryProfileName,originalConfig:$originalEntryConfig,integrationConfig:$entryIntegrationConfig,originalActiveInbounds:$originalEntryInbounds,originalActiveTags:$originalEntryTags,inboundTags:$entryInboundTags,outboundTag:$outboundTag},
          exit:{nodeUuid:$exitNodeUuid,nodeName:$exitNodeName,originalProfileUuid:$exitProfileUuid,cascadeProfileUuid:$exitProfileUuid,profileName:$exitProfileName,originalConfig:$originalExitConfig,integrationConfig:$exitIntegrationConfig,originalActiveInbounds:$originalExitInbounds,originalActiveTags:$originalExitTags,address:$exitAddress,port:$bridgePort,bridgeInboundUuid:$bridgeInboundUuid,bridgeInboundTag:$bridgeInboundTag,realitySni:$realitySni,realityTarget:$realityTarget,publicKey:$publicKey,shortId:$shortId},
          service:{squadUuid:$squadUuid,squadName:$squadName,userUuid:$serviceUserUuid,username:$serviceUsername,vlessUuid:$serviceVlessUuid},routingMode:$routingMode}')

    umask 077
    local state_tmp="${CASCADE_STATE_FILE}.tmp.$$"
    if ! jq -e 'type == "object" and .version == 3' >/dev/null 2>&1 <<< "$state" \
        || ! printf '%s\n' "$state" > "$state_tmp" \
        || ! jq -e . "$state_tmp" >/dev/null 2>&1 \
        || ! chmod 600 "$state_tmp" \
        || ! mv -f "$state_tmp" "$CASCADE_STATE_FILE"; then
        rm -f "$state_tmp"
        cascade_error "${LANG[CASCADE_STATE_WRITE_ERROR]}"
        cascade_partial_cleanup_in_place "$entry_modified" "$exit_modified" "$entry_node_uuid" "$entry_profile_uuid" "$entry_profile_name" "$entry_original_config" "$original_entry_tags" "$exit_node_uuid" "$exit_profile_uuid" "$exit_profile_name" "$exit_original_config" "$original_exit_tags" "$service_user_uuid" "$squad_uuid"
        return 1
    fi

    cascade_restart_node "$exit_node_uuid" >/dev/null 2>&1 || true
    cascade_restart_node "$entry_node_uuid" >/dev/null 2>&1 || true

    echo -e "\n${COLOR_GREEN}${LANG[CASCADE_CREATED]}${COLOR_RESET}"
    printf "${LANG[CASCADE_SUMMARY]}\n" "$entry_name" "$exit_name" "$exit_address" "$bridge_port"
    echo -e "${COLOR_YELLOW}$(printf "${LANG[CASCADE_FIREWALL_NOTE]}" "$exit_address" "$bridge_port")${COLOR_RESET}"
}

cascade_awg3_dependency_exists() {
    local awg_state="${DIR_REMNAWAVE}amneziawg_remnawave/state.json"
    [ -s "$awg_state" ] || return 1
    [ -s "$CASCADE_STATE_FILE" ] || return 1

    local awg_node awg_out cascade_node cascade_out
    awg_node=$(jq -r '.node.uuid // empty' "$awg_state" 2>/dev/null)
    awg_out=$(jq -r '.xray.outboundTag // empty' "$awg_state" 2>/dev/null)
    cascade_node=$(jq -r '.entry.nodeUuid // empty' "$CASCADE_STATE_FILE" 2>/dev/null)
    cascade_out=$(jq -r '.entry.outboundTag // empty' "$CASCADE_STATE_FILE" 2>/dev/null)

    [ -n "$awg_node" ] && [ -n "$awg_out" ] \
        && [ "$awg_node" = "$cascade_node" ] \
        && [ "$awg_out" = "$cascade_out" ]
}

cascade_guard_awg3_dependency() {
    if cascade_awg3_dependency_exists; then
        cascade_error "${LANG[CASCADE_AWG3_DEPENDENCY]}"
        return 1
    fi
}

cascade_status() {
    cascade_requirements || return 1
    if [ ! -s "$CASCADE_STATE_FILE" ]; then
        cascade_warn "${LANG[CASCADE_NOT_FOUND]}"
        return 1
    fi

    get_panel_token || return 1
    local state version entry_uuid exit_uuid enabled entry_profile exit_profile address port
    state=$(cat "$CASCADE_STATE_FILE")
    version=$(echo "$state" | jq -r '.version // 0')
    entry_uuid=$(echo "$state" | jq -r '.entry.nodeUuid')
    exit_uuid=$(echo "$state" | jq -r '.exit.nodeUuid')
    enabled=$(echo "$state" | jq -r '.enabled')
    entry_profile=$(echo "$state" | jq -r '.entry.cascadeProfileUuid')
    exit_profile=$(echo "$state" | jq -r '.exit.cascadeProfileUuid')
    address=$(echo "$state" | jq -r '.exit.address')
    port=$(echo "$state" | jq -r '.exit.port')

    local entry_node exit_node
    entry_node=$(cascade_get_node "$entry_uuid")
    exit_node=$(cascade_get_node "$exit_uuid")

    echo -e "\n${COLOR_GREEN}${LANG[CASCADE_STATUS_TITLE]}${COLOR_RESET}"
    printf "${LANG[CASCADE_STATUS_ENABLED]}\n" "$enabled"
    printf "${LANG[CASCADE_STATUS_ENTRY]}\n" "$(echo "$state" | jq -r '.entry.nodeName')" "$entry_uuid"
    printf "${LANG[CASCADE_STATUS_EXIT]}\n" "$(echo "$state" | jq -r '.exit.nodeName')" "$address" "$port"
    printf "${LANG[CASCADE_STATUS_MODE]}\n" "$(echo "$state" | jq -r '.routingMode')"

    if [ "$version" -ge 3 ]; then
        local entry_profile_response exit_profile_response outbound_tag bridge_tag active_entry_profile active_exit_profile
        outbound_tag=$(echo "$state" | jq -r '.entry.outboundTag')
        bridge_tag=$(echo "$state" | jq -r '.exit.bridgeInboundTag')
        active_entry_profile=$(echo "$entry_node" | jq -r '.response.configProfile.activeConfigProfileUuid // empty' 2>/dev/null)
        active_exit_profile=$(echo "$exit_node" | jq -r '.response.configProfile.activeConfigProfileUuid // empty' 2>/dev/null)
        entry_profile_response=$(cascade_get_profile "$entry_profile")
        exit_profile_response=$(cascade_get_profile "$exit_profile")

        if cascade_response_ok "$entry_node" && cascade_response_ok "$entry_profile_response" && [ "$active_entry_profile" = "$entry_profile" ]; then
            if [ "$enabled" = "true" ] && echo "$entry_profile_response" | jq -e --arg tag "$outbound_tag" '.response.config.outbounds[]? | select(.tag == $tag)' >/dev/null 2>&1; then
                cascade_ok "${LANG[CASCADE_ENTRY_PROFILE_OK]}"
            elif [ "$enabled" = "false" ] && ! echo "$entry_profile_response" | jq -e --arg tag "$outbound_tag" '.response.config.outbounds[]? | select(.tag == $tag)' >/dev/null 2>&1; then
                cascade_ok "${LANG[CASCADE_ENTRY_DISABLED_OK]}"
            else
                cascade_warn "${LANG[CASCADE_ENTRY_PROFILE_MISMATCH]}"
            fi
        else
            cascade_warn "${LANG[CASCADE_ENTRY_NODE_UNAVAILABLE]}"
        fi

        if cascade_response_ok "$exit_node" && cascade_response_ok "$exit_profile_response" \
            && [ "$active_exit_profile" = "$exit_profile" ] \
            && echo "$exit_profile_response" | jq -e --arg tag "$bridge_tag" '.response.config.inbounds[]? | select(.tag == $tag)' >/dev/null 2>&1; then
            cascade_ok "${LANG[CASCADE_EXIT_PROFILE_OK]}"
        else
            cascade_warn "${LANG[CASCADE_EXIT_PROFILE_MISMATCH]}"
        fi
    else
        if cascade_response_ok "$entry_node"; then
            local active_entry_profile
            active_entry_profile=$(echo "$entry_node" | jq -r '.response.configProfile.activeConfigProfileUuid // empty')
            if [ "$enabled" = "true" ] && [ "$active_entry_profile" = "$entry_profile" ]; then
                cascade_ok "${LANG[CASCADE_ENTRY_PROFILE_OK]}"
            elif [ "$enabled" = "false" ] && [ "$active_entry_profile" = "$(echo "$state" | jq -r '.entry.originalProfileUuid')" ]; then
                cascade_ok "${LANG[CASCADE_ENTRY_DISABLED_OK]}"
            else
                cascade_warn "${LANG[CASCADE_ENTRY_PROFILE_MISMATCH]}"
            fi
        else
            cascade_warn "${LANG[CASCADE_ENTRY_NODE_UNAVAILABLE]}"
        fi

        if cascade_response_ok "$exit_node" && [ "$(echo "$exit_node" | jq -r '.response.configProfile.activeConfigProfileUuid // empty')" = "$exit_profile" ]; then
            cascade_ok "${LANG[CASCADE_EXIT_PROFILE_OK]}"
        else
            cascade_warn "${LANG[CASCADE_EXIT_PROFILE_MISMATCH]}"
        fi
    fi

    if timeout 4 bash -c "</dev/tcp/${address}/${port}" >/dev/null 2>&1; then
        cascade_ok "$(printf "${LANG[CASCADE_PORT_REACHABLE]}" "$address" "$port")"
    else
        cascade_warn "$(printf "${LANG[CASCADE_PORT_UNREACHABLE]}" "$address" "$port")"
    fi
}

cascade_write_enabled_state() {
    local enabled="$1"
    local tmp="${CASCADE_STATE_FILE}.tmp.$$"

    if ! jq --argjson enabled "$enabled" '.enabled=$enabled' "$CASCADE_STATE_FILE" > "$tmp" \
        || ! jq -e 'type == "object" and ((.version == 2) or (.version == 3))' "$tmp" >/dev/null 2>&1 \
        || ! chmod 600 "$tmp" \
        || ! mv -f "$tmp" "$CASCADE_STATE_FILE"; then
        rm -f "$tmp"
        return 1
    fi
}

cascade_disable() {
    cascade_requirements || return 1
    [ -s "$CASCADE_STATE_FILE" ] || { cascade_warn "${LANG[CASCADE_NOT_FOUND]}"; return 1; }
    cascade_guard_awg3_dependency || return 1
    get_panel_token || return 1

    local state version
    state=$(cat "$CASCADE_STATE_FILE")
    version=$(echo "$state" | jq -r '.version // 0')

    if [ "$version" -ge 3 ]; then
        local node profile name original_config original_tags integration_config
        node=$(echo "$state" | jq -r '.entry.nodeUuid')
        profile=$(echo "$state" | jq -r '.entry.originalProfileUuid')
        name=$(echo "$state" | jq -r '.entry.profileName')
        original_config=$(echo "$state" | jq -c '.entry.originalConfig')
        original_tags=$(echo "$state" | jq -c '.entry.originalActiveTags // []')
        integration_config=$(echo "$state" | jq -c '.entry.integrationConfig')

        if ! cascade_restore_profile_snapshot "$node" "$profile" "$name" "$original_config" "$original_tags"; then
            cascade_error "${LANG[CASCADE_DISABLE_ERROR]}"
            return 1
        fi

        if ! cascade_write_enabled_state false; then
            cascade_apply_profile_snapshot "$node" "$profile" "$name" "$integration_config" "$original_tags" >/dev/null 2>&1 || true
            cascade_restart_node "$node" >/dev/null 2>&1 || true
            cascade_error "${LANG[CASCADE_STATE_WRITE_ERROR]}"
            return 1
        fi

        cascade_restart_node "$node" >/dev/null 2>&1 || true
        cascade_ok "${LANG[CASCADE_DISABLED]}"
        return 0
    fi

    local node original_profile original_inbounds cascade_profile original_active_tags
    node=$(echo "$state" | jq -r '.entry.nodeUuid')
    original_profile=$(echo "$state" | jq -r '.entry.originalProfileUuid')
    original_inbounds=$(echo "$state" | jq -c '.entry.originalActiveInbounds')
    cascade_profile=$(echo "$state" | jq -r '.entry.cascadeProfileUuid')
    original_active_tags=$(echo "$state" | jq -c '.entry.originalActiveTags // []')

    if ! cascade_assign_profile "$node" "$original_profile" "$original_inbounds"; then
        cascade_error "${LANG[CASCADE_DISABLE_ERROR]}"
        return 1
    fi

    if ! cascade_write_enabled_state false; then
        local profile_response cascade_inbounds
        profile_response=$(cascade_get_profile "$cascade_profile")
        if cascade_response_ok "$profile_response"; then
            cascade_inbounds=$(cascade_map_active_tags "$profile_response" "$original_active_tags")
            cascade_assign_profile "$node" "$cascade_profile" "$cascade_inbounds" >/dev/null 2>&1 || true
        fi
        cascade_restart_node "$node" >/dev/null 2>&1 || true
        cascade_error "${LANG[CASCADE_STATE_WRITE_ERROR]}"
        return 1
    fi

    cascade_restart_node "$node" >/dev/null 2>&1 || true
    cascade_ok "${LANG[CASCADE_DISABLED]}"
}

cascade_enable() {
    cascade_requirements || return 1
    [ -s "$CASCADE_STATE_FILE" ] || { cascade_warn "${LANG[CASCADE_NOT_FOUND]}"; return 1; }
    cascade_guard_awg3_dependency || return 1
    get_panel_token || return 1

    local state version
    state=$(cat "$CASCADE_STATE_FILE")
    version=$(echo "$state" | jq -r '.version // 0')

    if [ "$version" -ge 3 ]; then
        local node profile name original_config original_tags integration_config
        node=$(echo "$state" | jq -r '.entry.nodeUuid')
        profile=$(echo "$state" | jq -r '.entry.originalProfileUuid')
        name=$(echo "$state" | jq -r '.entry.profileName')
        original_config=$(echo "$state" | jq -c '.entry.originalConfig')
        original_tags=$(echo "$state" | jq -c '.entry.originalActiveTags // []')
        integration_config=$(echo "$state" | jq -c '.entry.integrationConfig')

        if ! cascade_apply_profile_snapshot "$node" "$profile" "$name" "$integration_config" "$original_tags"; then
            cascade_error "${LANG[CASCADE_ENABLE_ERROR]}"
            cascade_restore_profile_snapshot "$node" "$profile" "$name" "$original_config" "$original_tags" >/dev/null 2>&1 || true
            return 1
        fi

        if ! cascade_write_enabled_state true; then
            cascade_restore_profile_snapshot "$node" "$profile" "$name" "$original_config" "$original_tags" >/dev/null 2>&1 || true
            cascade_restart_node "$node" >/dev/null 2>&1 || true
            cascade_error "${LANG[CASCADE_STATE_WRITE_ERROR]}"
            return 1
        fi

        cascade_restart_node "$node" >/dev/null 2>&1 || true
        cascade_ok "${LANG[CASCADE_ENABLED]}"
        return 0
    fi

    local node cascade_profile profile_response cascade_inbounds original_active_tags original_profile original_inbounds
    node=$(echo "$state" | jq -r '.entry.nodeUuid')
    cascade_profile=$(echo "$state" | jq -r '.entry.cascadeProfileUuid')
    original_active_tags=$(echo "$state" | jq -c '.entry.originalActiveTags // []')
    original_profile=$(echo "$state" | jq -r '.entry.originalProfileUuid')
    original_inbounds=$(echo "$state" | jq -c '.entry.originalActiveInbounds')

    profile_response=$(cascade_get_profile "$cascade_profile")
    cascade_response_ok "$profile_response" || { cascade_error "${LANG[CASCADE_PROFILE_READ_ERROR]}"; return 1; }
    cascade_inbounds=$(cascade_map_active_tags "$profile_response" "$original_active_tags")
    if [ "$(echo "$cascade_inbounds" | jq 'length')" -eq 0 ]; then
        cascade_error "${LANG[CASCADE_INBOUND_MAPPING_ERROR]}"
        return 1
    fi

    if ! cascade_assign_profile "$node" "$cascade_profile" "$cascade_inbounds"; then
        cascade_error "${LANG[CASCADE_ENABLE_ERROR]}"
        return 1
    fi

    if ! cascade_write_enabled_state true; then
        cascade_assign_profile "$node" "$original_profile" "$original_inbounds" >/dev/null 2>&1 || true
        cascade_restart_node "$node" >/dev/null 2>&1 || true
        cascade_error "${LANG[CASCADE_STATE_WRITE_ERROR]}"
        return 1
    fi

    cascade_restart_node "$node" >/dev/null 2>&1 || true
    cascade_ok "${LANG[CASCADE_ENABLED]}"
}

remove_vless_cascade() {
    cascade_requirements || return 1
    [ -s "$CASCADE_STATE_FILE" ] || { cascade_warn "${LANG[CASCADE_NOT_FOUND]}"; return 1; }
    cascade_guard_awg3_dependency || return 1

    echo -e "${COLOR_RED}${LANG[CASCADE_REMOVE_CONFIRM]}${COLOR_RESET}"
    local confirm
    read -r confirm
    if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
        cascade_warn "${LANG[CASCADE_REMOVE_CANCELLED]}"
        return 0
    fi

    get_panel_token || return 1
    local state version
    state=$(cat "$CASCADE_STATE_FILE")
    version=$(echo "$state" | jq -r '.version // 0')

    if [ "$version" -ge 3 ]; then
        local entry_node exit_node entry_profile exit_profile entry_name exit_name entry_config exit_config entry_tags exit_tags
        entry_node=$(echo "$state" | jq -r '.entry.nodeUuid')
        exit_node=$(echo "$state" | jq -r '.exit.nodeUuid')
        entry_profile=$(echo "$state" | jq -r '.entry.originalProfileUuid')
        exit_profile=$(echo "$state" | jq -r '.exit.originalProfileUuid')
        entry_name=$(echo "$state" | jq -r '.entry.profileName')
        exit_name=$(echo "$state" | jq -r '.exit.profileName')
        entry_config=$(echo "$state" | jq -c '.entry.originalConfig')
        exit_config=$(echo "$state" | jq -c '.exit.originalConfig')
        entry_tags=$(echo "$state" | jq -c '.entry.originalActiveTags // []')
        exit_tags=$(echo "$state" | jq -c '.exit.originalActiveTags // []')

        cascade_restore_profile_snapshot "$entry_node" "$entry_profile" "$entry_name" "$entry_config" "$entry_tags" || {
            cascade_error "${LANG[CASCADE_RESTORE_ENTRY_ERROR]}"
            return 1
        }
        cascade_restore_profile_snapshot "$exit_node" "$exit_profile" "$exit_name" "$exit_config" "$exit_tags" || {
            cascade_error "${LANG[CASCADE_RESTORE_EXIT_ERROR]}"
            return 1
        }

        cascade_restart_node "$entry_node" >/dev/null 2>&1 || true
        cascade_restart_node "$exit_node" >/dev/null 2>&1 || true
        cascade_delete_resource "/api/users/$(echo "$state" | jq -r '.service.userUuid')" || cascade_warn "${LANG[CASCADE_DELETE_USER_WARN]}"
        cascade_delete_resource "/api/internal-squads/$(echo "$state" | jq -r '.service.squadUuid')" || cascade_warn "${LANG[CASCADE_DELETE_SQUAD_WARN]}"
        rm -f "$CASCADE_STATE_FILE"
        cascade_ok "${LANG[CASCADE_REMOVED]}"
        return 0
    fi

    local entry_node exit_node original_entry_profile original_exit_profile original_entry_inbounds original_exit_inbounds
    entry_node=$(echo "$state" | jq -r '.entry.nodeUuid')
    exit_node=$(echo "$state" | jq -r '.exit.nodeUuid')
    original_entry_profile=$(echo "$state" | jq -r '.entry.originalProfileUuid')
    original_exit_profile=$(echo "$state" | jq -r '.exit.originalProfileUuid')
    original_entry_inbounds=$(echo "$state" | jq -c '.entry.originalActiveInbounds')
    original_exit_inbounds=$(echo "$state" | jq -c '.exit.originalActiveInbounds')

    cascade_assign_profile "$entry_node" "$original_entry_profile" "$original_entry_inbounds" || {
        cascade_error "${LANG[CASCADE_RESTORE_ENTRY_ERROR]}"
        return 1
    }
    cascade_assign_profile "$exit_node" "$original_exit_profile" "$original_exit_inbounds" || {
        cascade_error "${LANG[CASCADE_RESTORE_EXIT_ERROR]}"
        return 1
    }

    cascade_restart_node "$entry_node" >/dev/null 2>&1 || true
    cascade_restart_node "$exit_node" >/dev/null 2>&1 || true

    cascade_delete_resource "/api/users/$(echo "$state" | jq -r '.service.userUuid')" || cascade_warn "${LANG[CASCADE_DELETE_USER_WARN]}"
    cascade_delete_resource "/api/internal-squads/$(echo "$state" | jq -r '.service.squadUuid')" || cascade_warn "${LANG[CASCADE_DELETE_SQUAD_WARN]}"
    cascade_delete_resource "/api/config-profiles/$(echo "$state" | jq -r '.entry.cascadeProfileUuid')" || cascade_warn "${LANG[CASCADE_DELETE_ENTRY_PROFILE_WARN]}"
    cascade_delete_resource "/api/config-profiles/$(echo "$state" | jq -r '.exit.cascadeProfileUuid')" || cascade_warn "${LANG[CASCADE_DELETE_EXIT_PROFILE_WARN]}"

    rm -f "$CASCADE_STATE_FILE"
    cascade_ok "${LANG[CASCADE_REMOVED]}"
}

show_vless_cascade_menu() {
    echo -e "\n${COLOR_GREEN}${LANG[CASCADE_MENU_TITLE]}${COLOR_RESET}"
    echo -e "${COLOR_YELLOW}1. ${LANG[CASCADE_MENU_CREATE]}${COLOR_RESET}"
    echo -e "${COLOR_YELLOW}2. ${LANG[CASCADE_MENU_STATUS]}${COLOR_RESET}"
    echo -e "${COLOR_YELLOW}3. ${LANG[CASCADE_MENU_DISABLE]}${COLOR_RESET}"
    echo -e "${COLOR_YELLOW}4. ${LANG[CASCADE_MENU_ENABLE]}${COLOR_RESET}"
    echo -e "${COLOR_YELLOW}5. ${LANG[CASCADE_MENU_REMOVE]}${COLOR_RESET}"
    echo -e "${COLOR_YELLOW}0. ${LANG[EXIT]}${COLOR_RESET}"
    echo -e ""
}

manage_vless_cascade() {
    show_vless_cascade_menu
    local option
    reading "${LANG[CASCADE_PROMPT_ACTION]}" option
    case "$option" in
        1) create_vless_cascade ;;
        2) cascade_status ;;
        3) cascade_disable ;;
        4) cascade_enable ;;
        5) remove_vless_cascade ;;
        0) return 0 ;;
        *) cascade_error "${LANG[CASCADE_INVALID_CHOICE]}"; return 1 ;;
    esac
}
