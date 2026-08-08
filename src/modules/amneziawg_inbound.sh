#!/bin/bash
# Module: AmneziaWG 3.0 inbound -> Remnawave/Xray transparent routing
# Requires: remnawave_api.sh loaded before this module.
# Pinned launcher: bivlked/amneziawg-installer v5.24.0 at immutable commit 2c86966f59d54c0fd0bcf66639c537558a1a0c25.

AWGR_DIR="${DIR_REMNAWAVE}amneziawg_remnawave"
AWGR_STATE_FILE="${AWGR_DIR}/state.json"
AWGR_BOOTSTRAP_ENV="${AWGR_DIR}/bootstrap.env"
AWGR_API_HOST="127.0.0.1:3000"
AWGR_VENDOR_DIR="${DIR_REMNAWAVE}vendor/amneziawg-installer"
AWGR_INSTALLER="${AWGR_VENDOR_DIR}/install_amneziawg.sh"
AWGR_TPROXY_SCRIPT="/usr/local/sbin/remnawave-awg3-tproxy"
AWGR_RESUME_SCRIPT="/usr/local/sbin/remnawave-awg3-resume"
AWGR_TPROXY_UNIT="/etc/systemd/system/remnawave-awg3-tproxy.service"
AWGR_BOOTSTRAP_UNIT="/etc/systemd/system/remnawave-awg3-bootstrap.service"
AWGR_SYSCTL_FILE="/etc/sysctl.d/99-remnawave-awg3-tproxy.conf"
AWGR_AWG_CONFIG="/root/awg/awgsetup_cfg.init"
AWGR_AWG_SERVER_CONFIG="/etc/amnezia/amneziawg/awg0.conf"
AWGR_UPSTREAM_VERSION="5.24.0"
AWGR_UPSTREAM_COMMIT="2c86966f59d54c0fd0bcf66639c537558a1a0c25"

# The menu script can be updated from GitHub without copying the repository's
# vendor/ directory.  Keep the pinned launcher self-healing so menu item 13
# works after both a fresh `bash <(curl ...)` install and an in-place update.
awgr_ensure_pinned_installer() {
    if [ -x "$AWGR_INSTALLER" ] \
        && grep -Fq "UPSTREAM_VERSION=\"${AWGR_UPSTREAM_VERSION}\"" "$AWGR_INSTALLER" 2>/dev/null \
        && grep -Fq "UPSTREAM_COMMIT=\"${AWGR_UPSTREAM_COMMIT}\"" "$AWGR_INSTALLER" 2>/dev/null; then
        return 0
    fi

    mkdir -p "$AWGR_VENDOR_DIR" || return 1
    local tmp="${AWGR_INSTALLER}.tmp.$$"
    umask 077
    cat > "$tmp" <<'AWGR_PINNED_LAUNCHER'
#!/bin/bash
# Pinned launcher for bivlked/amneziawg-installer v5.24.0.
# Commit: 2c86966f59d54c0fd0bcf66639c537558a1a0c25
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

AWG_BRANCH="$UPSTREAM_COMMIT" bash "$tmp" "$@"
AWGR_PINNED_LAUNCHER

    chmod 700 "$tmp" || { rm -f "$tmp"; return 1; }
    mv -f "$tmp" "$AWGR_INSTALLER" || { rm -f "$tmp"; return 1; }
    return 0
}

awgr_error() { echo -e "${COLOR_RED}$*${COLOR_RESET}"; }
awgr_warn()  { echo -e "${COLOR_YELLOW}$*${COLOR_RESET}"; }
awgr_ok()    { echo -e "${COLOR_GREEN}$*${COLOR_RESET}"; }
awgr_info()  { echo -e "${COLOR_WHITE}$*${COLOR_RESET}"; }

awgr_valid_port() {
    [[ "$1" =~ ^[0-9]+$ ]] && [ "$1" -ge 1 ] && [ "$1" -le 65535 ]
}

awgr_valid_table() {
    [[ "$1" =~ ^[0-9]+$ ]] && [ "$1" -ge 1 ] && [ "$1" -le 4294967295 ]
}

awgr_safe_name() {
    printf '%s' "$1" | tr -cs '[:alnum:]_-' '_' | cut -c1-40
}

# Optional client endpoint hostname. The upstream AWG installer supports
# --endpoint=FQDN and writes that value into generated client configurations.
# We validate it before making any Remnawave/profile changes and additionally
# require its A record to point to this VPS public IPv4 address.
awgr_valid_fqdn() {
    local host="${1%.}"
    [ -n "$host" ] && [ "${#host}" -le 253 ] || return 1
    [[ "$host" == *.* ]] || return 1
    [[ "$host" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ ]] || return 1
    local label
    local -a _awgr_labels=()
    IFS='.' read -r -a _awgr_labels <<< "$host"
    for label in "${_awgr_labels[@]}"; do
        [ -n "$label" ] && [ "${#label}" -le 63 ] || return 1
        [[ "$label" =~ ^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?$ ]] || return 1
    done
}

awgr_is_public_ipv4() {
    python3 - "$1" <<'PYIP' >/dev/null 2>&1
import ipaddress, sys
try:
    ip = ipaddress.ip_address(sys.argv[1])
except ValueError:
    raise SystemExit(1)
raise SystemExit(0 if ip.version == 4 and ip.is_global else 1)
PYIP
}

awgr_public_ipv4() {
    local candidate url

    # Prefer the address selected by the host routing table; on a normal VPS it
    # is the public address and avoids depending on an external HTTP service.
    candidate=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for (i=1;i<=NF;i++) if ($i=="src") {print $(i+1); exit}}')
    if [ -n "$candidate" ] && awgr_is_public_ipv4 "$candidate"; then
        printf '%s\n' "$candidate"
        return 0
    fi

    for url in https://api.ipify.org https://ipv4.icanhazip.com https://ifconfig.me/ip; do
        candidate=$(curl -4fsS --connect-timeout 5 --max-time 8 "$url" 2>/dev/null | tr -d '[:space:]' || true)
        if [ -n "$candidate" ] && awgr_is_public_ipv4 "$candidate"; then
            printf '%s\n' "$candidate"
            return 0
        fi
    done
    return 1
}

awgr_resolve_ipv4() {
    python3 - "$1" <<'PYDNS'
import ipaddress
import socket
import sys

host = sys.argv[1]
try:
    infos = socket.getaddrinfo(host, None, socket.AF_INET, socket.SOCK_DGRAM)
except socket.gaierror:
    raise SystemExit(1)

addresses = []
for info in infos:
    addr = info[4][0]
    try:
        ip = ipaddress.ip_address(addr)
    except ValueError:
        continue
    if ip.version == 4 and addr not in addresses:
        addresses.append(addr)

if not addresses:
    raise SystemExit(1)
print("\n".join(addresses))
PYDNS
}

awgr_response_ok() {
    local response="$1"
    [ -n "$response" ] || return 1
    echo "$response" | jq -e . >/dev/null 2>&1 || return 1
    if echo "$response" | jq -e '(.statusCode? // 0) >= 400 or (.errorCode? != null)' >/dev/null 2>&1; then
        return 1
    fi
    return 0
}

awgr_api() {
    local method="$1"
    local path="$2"
    local data="${3:-}"
    make_api_request "$method" "http://${AWGR_API_HOST}${path}" "$token" "$data"
}

awgr_module_version() {
    modinfo -F version amneziawg 2>/dev/null | head -n1
}

awgr_kernel_at_least_67() {
    local release major minor
    release="$(uname -r)"
    major="${release%%.*}"
    release="${release#*.}"
    minor="${release%%.*}"
    [[ "$major" =~ ^[0-9]+$ && "$minor" =~ ^[0-9]+$ ]] || return 1
    [ "$major" -gt 6 ] || { [ "$major" -eq 6 ] && [ "$minor" -ge 7 ]; }
}

awgr_host_supports_awg3() {
    local arch
    arch="$(uname -m)"
    case "$arch" in
        x86_64|amd64) ;;
        *) return 1 ;;
    esac
    awgr_kernel_at_least_67
}

awgr_state_schema_version() {
    [ -s "$AWGR_STATE_FILE" ] || { printf '0\n'; return 0; }
    jq -r '.version // 0' "$AWGR_STATE_FILE" 2>/dev/null || printf '0\n'
}

awgr_legacy_runtime_exists() {
    [ -e /etc/systemd/system/remnawave-awg2-tproxy.service ] \
        || [ -e /etc/systemd/system/remnawave-awg2-bootstrap.service ] \
        || [ -e /usr/local/sbin/remnawave-awg2-tproxy ] \
        || [ -e /usr/local/sbin/remnawave-awg2-resume ] \
        || iptables -w 2 -t mangle -S REMNA_AWG2 >/dev/null 2>&1
}

awgr_require_current_state_schema() {
    local version
    version="$(awgr_state_schema_version)"
    if [ "$version" != "4" ]; then
        awgr_error "$(printf "${LANG[AWGR_LEGACY_STATE_DETECTED]}" "$version")"
        return 1
    fi
    return 0
}

awgr_require_awg3_before_create() {
    local module_version
    if systemctl is-active --quiet awg-quick@awg0.service && ip link show awg0 >/dev/null 2>&1; then
        module_version="$(awgr_module_version)"
        if [[ "$module_version" != 3.* ]]; then
            awgr_error "$(printf "${LANG[AWGR_EXISTING_NOT_AWG3]}" "${module_version:-unknown}")"
            return 1
        fi
        return 0
    fi

    if ! awgr_host_supports_awg3; then
        awgr_error "$(printf "${LANG[AWGR_AWG3_HOST_REQUIRED]}" "$(uname -m)" "$(uname -r)")"
        return 1
    fi
    return 0
}

awgr_requirements() {
    if [ "${EUID:-$(id -u)}" -ne 0 ]; then
        awgr_error "${LANG[AWGR_ROOT_REQUIRED]}"
        return 1
    fi

    if [ ! -d /opt/remnawave ]; then
        awgr_error "${LANG[AWGR_PANEL_REQUIRED]}"
        return 1
    fi

    local missing=()
    local cmd
    for cmd in curl jq ip iptables systemctl awk sed grep python3 ss sysctl modprobe docker; do
        command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
    done
    if [ ${#missing[@]} -gt 0 ]; then
        awgr_error "${LANG[AWGR_MISSING_DEPS]}: ${missing[*]}"
        return 1
    fi
    if ! docker compose version >/dev/null 2>&1; then
        awgr_error "${LANG[AWGR_MISSING_DEPS]}: docker compose"
        return 1
    fi

    if ! awgr_ensure_pinned_installer; then
        awgr_error "${LANG[AWGR_VENDOR_MISSING]}: $AWGR_INSTALLER"
        return 1
    fi

    if ! iptables -t mangle -L >/dev/null 2>&1; then
        awgr_error "${LANG[AWGR_IPTABLES_ERROR]}"
        return 1
    fi

    if ! docker inspect remnanode >/dev/null 2>&1; then
        awgr_error "${LANG[AWGR_LOCAL_NODE_REQUIRED]}"
        return 1
    fi

    # AmneziaWG 3.0 requires a real VM because it loads a DKMS kernel module.
    # Fail before changing Remnawave profiles on LXC/OpenVZ/Docker containers.
    if command -v systemd-detect-virt >/dev/null 2>&1; then
        local virt
        virt=$(systemd-detect-virt --container 2>/dev/null || true)
        if [ -n "$virt" ] && [ "$virt" != "none" ]; then
            awgr_error "$(printf "${LANG[AWGR_CONTAINER_UNSUPPORTED]}" "$virt")"
            return 1
        fi
    fi

    if [ -r /etc/os-release ]; then
        local os_id os_version
        os_id=$(awk -F= '$1=="ID" {gsub(/"/,"",$2); print $2}' /etc/os-release)
        os_version=$(awk -F= '$1=="VERSION_ID" {gsub(/"/,"",$2); print $2}' /etc/os-release)
        if [ "$os_id" != "ubuntu" ] || [ "$os_version" != "24.04" ]; then
            awgr_warn "$(printf "${LANG[AWGR_OS_WARNING]}" "${os_id:-unknown}" "${os_version:-unknown}")"
        fi
    fi

    mkdir -p "$AWGR_DIR"
    chmod 700 "$AWGR_DIR"
}

AWGR_DOCKER_COMPOSE_FILE=""
AWGR_DOCKER_SERVICE="remnanode"
AWGR_DOCKER_CAP_ADDED=false
AWGR_SELECTED_MARK="0x66"
AWGR_SELECTED_TABLE=166
AWGR_SELECTED_PRIORITY=10166
AWGR_UFW_RULE_ADDED=false

awgr_select_tproxy_resources() {
    local table priority mark_num mark_hex rules routes
    rules=$(ip -4 rule show 2>/dev/null || true)

    for table in $(seq 166 199); do
        priority=$((10000 + table))
        mark_num=$((0x66 + table - 166))
        printf -v mark_hex '0x%x' "$mark_num"
        routes=$(ip -4 route show table "$table" 2>/dev/null || true)

        # Do not reuse routing resources that belong to another service.
        if echo "$rules" | grep -Eq "^[[:space:]]*${priority}:"; then
            continue
        fi
        if echo "$rules" | grep -Eq "(^|[[:space:]])(lookup|table)[[:space:]]+${table}([[:space:]]|$)"; then
            continue
        fi
        if echo "$rules" | grep -Eiq "fwmark[[:space:]]+${mark_hex}(/0x[[:xdigit:]]+)?([[:space:]]|$)"; then
            continue
        fi
        if [ -n "$routes" ]; then
            continue
        fi

        AWGR_SELECTED_MARK="$mark_hex"
        AWGR_SELECTED_TABLE="$table"
        AWGR_SELECTED_PRIORITY="$priority"
        return 0
    done

    awgr_error "${LANG[AWGR_NO_FREE_POLICY_RESOURCES]}"
    return 1
}

awgr_udp_port_in_use() {
    local port="$1"
    ss -H -lunp 2>/dev/null | awk '{print $5}' | grep -Eq "(^|:)${port}$"
}

awgr_subnet_conflicts() {
    local subnet="$1"
    python3 - "$subnet" <<'PYNETCHECK'
import ipaddress
import subprocess
import sys

wanted = ipaddress.ip_network(sys.argv[1], strict=False)
text = subprocess.run(
    ["ip", "-4", "route", "show", "table", "main"],
    check=False,
    text=True,
    stdout=subprocess.PIPE,
    stderr=subprocess.DEVNULL,
).stdout

for line in text.splitlines():
    fields = line.split()
    if not fields or fields[0] in {"default", "broadcast", "local", "unreachable", "prohibit", "blackhole"}:
        continue
    if "dev" in fields:
        try:
            dev = fields[fields.index("dev") + 1]
        except (ValueError, IndexError):
            dev = ""
        if dev == "awg0":
            continue
    try:
        existing = ipaddress.ip_network(fields[0], strict=False)
    except ValueError:
        continue
    if existing.version == 4 and existing.overlaps(wanted):
        print(line)
        raise SystemExit(0)

raise SystemExit(1)
PYNETCHECK
}

awgr_ensure_ufw_rule() {
    local port="$1"
    AWGR_UFW_RULE_ADDED=false
    command -v ufw >/dev/null 2>&1 || return 0
    LC_ALL=C ufw status 2>/dev/null | grep -q '^Status: active' || return 0

    if LC_ALL=C ufw status 2>/dev/null | grep -Eq "^[[:space:]]*${port}/udp([[:space:]]|$)"; then
        return 0
    fi

    if ufw allow "${port}/udp" comment 'AmneziaWG VPN (Remnawave)' >/dev/null; then
        AWGR_UFW_RULE_ADDED=true
        return 0
    fi

    awgr_error "$(printf "${LANG[AWGR_UFW_ADD_ERROR]}" "$port")"
    return 1
}

awgr_remove_ufw_rule() {
    local port="$1"
    local added="$2"
    [ "$added" = "true" ] || return 0
    command -v ufw >/dev/null 2>&1 || return 0
    ufw --force delete allow "${port}/udp" >/dev/null 2>&1 || true
}

awgr_read_sysctl_value() {
    local key="$1" default_value="$2" value
    value=$(sysctl -n "$key" 2>/dev/null || true)
    if [[ "$value" =~ ^[0-9]+$ ]]; then
        printf '%s' "$value"
    else
        printf '%s' "$default_value"
    fi
}

awgr_restore_host_sysctl() {
    local state_json="${1:-}"
    local restore_forward="${2:-false}"
    [ -n "$state_json" ] || return 0
    echo "$state_json" | jq -e . >/dev/null 2>&1 || return 0

    local previous_src previous_forward
    previous_src=$(echo "$state_json" | jq -r '.host.previousSrcValidMark // empty')
    previous_forward=$(echo "$state_json" | jq -r '.host.previousIpForward // empty')

    if [[ "$previous_src" =~ ^[0-9]+$ ]]; then
        sysctl -w "net.ipv4.conf.all.src_valid_mark=${previous_src}" >/dev/null 2>&1 || true
    fi
    if [ "$restore_forward" = "true" ] && [[ "$previous_forward" =~ ^[0-9]+$ ]]; then
        sysctl -w "net.ipv4.ip_forward=${previous_forward}" >/dev/null 2>&1 || true
    fi
}

awgr_read_existing_awg() {
    local config_file="$AWGR_AWG_CONFIG"
    local server_file="$AWGR_AWG_SERVER_CONFIG"

    if [ -f "$config_file" ]; then
        # shellcheck disable=SC1090
        source "$config_file"
        AWGR_EXISTING_PORT="${AWG_PORT:-}"
        AWGR_EXISTING_SUBNET="${AWG_TUNNEL_SUBNET:-}"
        AWGR_EXISTING_PRESET="${AWG_PRESET:-default}"
        AWGR_EXISTING_SERVER_NAME="${AWG_SERVER_NAME:-Remnawave AWG3 RU}"
        AWGR_EXISTING_ENDPOINT="${AWG_ENDPOINT:-}"
    elif [ -f "$server_file" ]; then
        AWGR_EXISTING_PORT=$(awk -F= '/^[[:space:]]*ListenPort[[:space:]]*=/{gsub(/[[:space:]]/,"",$2); print $2; exit}' "$server_file")
        AWGR_EXISTING_SUBNET=$(awk -F= '/^[[:space:]]*Address[[:space:]]*=/{gsub(/[[:space:]]/,"",$2); print $2; exit}' "$server_file")
        AWGR_EXISTING_PRESET="default"
        AWGR_EXISTING_SERVER_NAME="Remnawave AWG3 RU"
        AWGR_EXISTING_ENDPOINT=""
    else
        return 1
    fi

    awgr_valid_port "$AWGR_EXISTING_PORT" || return 1
    [ -n "$AWGR_EXISTING_SUBNET" ] || return 1
    return 0
}

awgr_detect_node_compose_service() {
    local service
    service=$(docker inspect -f '{{ index .Config.Labels "com.docker.compose.service" }}' remnanode 2>/dev/null || true)
    if [[ "$service" =~ ^[A-Za-z0-9_.-]+$ ]]; then
        AWGR_DOCKER_SERVICE="$service"
    else
        AWGR_DOCKER_SERVICE="remnanode"
    fi
}

awgr_compose_file_has_service() {
    local compose_file="$1"
    local service_name="${2:-$AWGR_DOCKER_SERVICE}"
    python3 - "$compose_file" "$service_name" <<'PYSERVICE'
from pathlib import Path
import re, sys
p = Path(sys.argv[1])
service = sys.argv[2]
try:
    text = p.read_text()
except OSError:
    raise SystemExit(1)
pat = re.compile(r'^\s*' + re.escape(service) + r':\s*(?:#.*)?$', re.M)
raise SystemExit(0 if pat.search(text) else 1)
PYSERVICE
}

awgr_find_node_compose_file() {
    local working_dir config_files candidate
    local service_name="${1:-$AWGR_DOCKER_SERVICE}"
    working_dir=$(docker inspect -f '{{ index .Config.Labels "com.docker.compose.project.working_dir" }}' remnanode 2>/dev/null || true)
    config_files=$(docker inspect -f '{{ index .Config.Labels "com.docker.compose.project.config_files" }}' remnanode 2>/dev/null || true)

    IFS=',' read -ra _awgr_files <<< "$config_files"
    for candidate in "${_awgr_files[@]}"; do
        candidate="${candidate#${candidate%%[![:space:]]*}}"
        candidate="${candidate%${candidate##*[![:space:]]}}"
        [ -n "$candidate" ] || continue
        [[ "$candidate" = /* ]] || candidate="${working_dir%/}/$candidate"
        if [ -f "$candidate" ] && awgr_compose_file_has_service "$candidate" "$service_name"; then
            echo "$candidate"
            return 0
        fi
    done

    for candidate in /opt/remnanode/docker-compose.yml /opt/remnanode/compose.yml /opt/remnawave/docker-compose.yml /opt/remnawave/compose.yml; do
        if [ -f "$candidate" ] && awgr_compose_file_has_service "$candidate" "$service_name"; then
            echo "$candidate"
            return 0
        fi
    done
    return 1
}

awgr_container_has_net_admin() {
    docker inspect -f '{{json .HostConfig.CapAdd}}' remnanode 2>/dev/null | jq -e '
        (. // [])
        | map(ascii_upcase | sub("^CAP_"; ""))
        | index("NET_ADMIN") != null
    ' >/dev/null 2>&1
}

awgr_compose_config_has_net_admin() {
    local compose_file="$1"
    local service_name="${2:-$AWGR_DOCKER_SERVICE}"
    local compose_dir compose_name
    compose_dir=$(dirname "$compose_file")
    compose_name=$(basename "$compose_file")
    (cd "$compose_dir" && docker compose -f "$compose_name" config --format json 2>/dev/null) | jq -e --arg service "$service_name" '
        (.services[$service].cap_add // [])
        | map(ascii_upcase | sub("^CAP_"; ""))
        | index("NET_ADMIN") != null
    ' >/dev/null 2>&1
}

awgr_patch_compose_net_admin() {
    local compose_file="$1"
    local service_name="${2:-$AWGR_DOCKER_SERVICE}"

    # Prefer structural YAML editing when yq v4 is available. This avoids
    # indentation/anchor edge cases in already customized Compose files.
    if command -v yq >/dev/null 2>&1 && yq --version 2>/dev/null | grep -q 'version v4'; then
        local current_caps
        current_caps=$(yq eval ".services.\"${service_name}\".cap_add // [] | .[]" "$compose_file" 2>/dev/null || true)
        if ! grep -Eiq '^(CAP_)?NET_ADMIN$' <<< "$current_caps"; then
            yq eval -i ".services.\"${service_name}\".cap_add = ((.services.\"${service_name}\".cap_add // []) + [\"NET_ADMIN\"])" "$compose_file" || return 1
        fi
        return 0
    fi

    python3 - "$compose_file" "$service_name" <<'PYCOMPOSE'
from pathlib import Path
import re, sys
p = Path(sys.argv[1])
service_name = sys.argv[2]
text = p.read_text()
marker = '# REMNAWAVE_AWG3_NET_ADMIN'
if marker in text:
    raise SystemExit(0)
lines = text.splitlines(True)
service_i = None
service_indent = None
service_re = re.compile(r'^(\s*)' + re.escape(service_name) + r':\s*(?:#.*)?$')
for i, line in enumerate(lines):
    m = service_re.match(line.rstrip('\n'))
    if m:
        service_i, service_indent = i, len(m.group(1)); break
if service_i is None:
    raise SystemExit(f'service {service_name} not found in compose file')
end = len(lines)
for i in range(service_i + 1, len(lines)):
    stripped = lines[i].strip()
    if not stripped or stripped.startswith('#'):
        continue
    indent = len(lines[i]) - len(lines[i].lstrip(' '))
    if indent <= service_indent:
        end = i; break
child_indent = service_indent + 2
cap_i = None
cap_indent = None
for i in range(service_i + 1, end):
    raw = lines[i].rstrip('\n')
    if re.match(r'^\s*cap_add:\s*(?:#.*)?$', raw):
        cap_i = i
        cap_indent = len(lines[i]) - len(lines[i].lstrip(' '))
        break
    inline = re.match(r'^\s*cap_add:\s*(\[.*\])\s*(?:#.*)?$', raw)
    if inline:
        value = inline.group(1).upper().replace('"', '').replace("'", '')
        if re.search(r'(?:^|[\[,\s])NET_ADMIN(?:[\],\s]|$)', value):
            raise SystemExit(0)
        raise SystemExit('inline cap_add is not supported safely; convert it to a YAML list')
if cap_i is not None:
    list_indent = cap_indent + 2
    insert_i = cap_i + 1
    while insert_i < end:
        stripped = lines[insert_i].strip()
        if not stripped or stripped.startswith('#'):
            insert_i += 1; continue
        indent = len(lines[insert_i]) - len(lines[insert_i].lstrip(' '))
        if indent <= cap_indent:
            break
        if re.match(r'^\s*-\s*(?:NET_ADMIN|"NET_ADMIN"|\'NET_ADMIN\')\s*(?:#.*)?$', lines[insert_i].rstrip('\n'), re.I):
            raise SystemExit(0)
        insert_i += 1
    lines.insert(insert_i, ' ' * list_indent + '- NET_ADMIN ' + marker + '\n')
else:
    insert_i = service_i + 1
    for i in range(service_i + 1, end):
        if re.match(r'^\s*(?:network_mode|image):', lines[i]):
            insert_i = i + 1
    block = [
        ' ' * child_indent + 'cap_add: ' + marker + '\n',
        ' ' * (child_indent + 2) + '- NET_ADMIN\n',
    ]
    lines[insert_i:insert_i] = block
p.write_text(''.join(lines))
PYCOMPOSE
}

awgr_unpatch_compose_net_admin() {
    local compose_file="$1"
    [ -f "$compose_file" ] || return 0
    python3 - "$compose_file" <<'PYCOMPOSE'
from pathlib import Path
import re, sys
p = Path(sys.argv[1])
lines = p.read_text().splitlines(True)
marker = 'REMNAWAVE_AWG3_NET_ADMIN'
out=[]
i=0
while i < len(lines):
    line=lines[i]
    if marker in line and re.match(r'^\s*cap_add:', line):
        i += 1
        if i < len(lines) and re.match(r'^\s*-\s*NET_ADMIN\s*(?:#.*)?$', lines[i].rstrip('\n'), re.I):
            i += 1
        continue
    if marker in line and re.match(r'^\s*-\s*NET_ADMIN', line, re.I):
        i += 1
        continue
    out.append(line); i += 1
p.write_text(''.join(out))
PYCOMPOSE
}

awgr_recreate_node_from_compose() {
    local compose_file="$1"
    local service_name="${2:-$AWGR_DOCKER_SERVICE}"
    local compose_dir compose_name project_name
    compose_dir=$(dirname "$compose_file")
    compose_name=$(basename "$compose_file")
    project_name=$(docker inspect -f '{{ index .Config.Labels "com.docker.compose.project" }}' remnanode 2>/dev/null || true)
    if [[ "$project_name" =~ ^[A-Za-z0-9_.-]+$ ]]; then
        (cd "$compose_dir" && docker compose -p "$project_name" -f "$compose_name" up -d --no-deps --force-recreate "$service_name")
    else
        (cd "$compose_dir" && docker compose -f "$compose_name" up -d --no-deps --force-recreate "$service_name")
    fi
}

awgr_ensure_node_net_admin() {
    AWGR_DOCKER_CAP_ADDED=false
    AWGR_DOCKER_COMPOSE_FILE=""
    awgr_detect_node_compose_service
    if awgr_container_has_net_admin; then
        return 0
    fi

    local compose_file backup_file
    compose_file=$(awgr_find_node_compose_file "$AWGR_DOCKER_SERVICE") || {
        awgr_error "${LANG[AWGR_COMPOSE_NOT_FOUND]}"
        return 1
    }
    backup_file="${AWGR_DIR}/$(basename "$compose_file").before-net-admin.$(date +%Y%m%d%H%M%S)"
    cp -a "$compose_file" "$backup_file" || return 1

    if ! awgr_patch_compose_net_admin "$compose_file" "$AWGR_DOCKER_SERVICE"; then
        cp -a "$backup_file" "$compose_file" >/dev/null 2>&1 || true
        awgr_error "${LANG[AWGR_NET_ADMIN_PATCH_ERROR]}"
        return 1
    fi
    if ! awgr_compose_config_has_net_admin "$compose_file" "$AWGR_DOCKER_SERVICE"; then
        cp -a "$backup_file" "$compose_file" >/dev/null 2>&1 || true
        awgr_error "${LANG[AWGR_NET_ADMIN_PATCH_ERROR]}"
        return 1
    fi
    if ! awgr_recreate_node_from_compose "$compose_file" "$AWGR_DOCKER_SERVICE"; then
        cp -a "$backup_file" "$compose_file" >/dev/null 2>&1 || true
        awgr_recreate_node_from_compose "$compose_file" "$AWGR_DOCKER_SERVICE" >/dev/null 2>&1 || true
        awgr_error "${LANG[AWGR_NET_ADMIN_RECREATE_ERROR]}"
        return 1
    fi
    if ! awgr_container_has_net_admin; then
        cp -a "$backup_file" "$compose_file" >/dev/null 2>&1 || true
        awgr_recreate_node_from_compose "$compose_file" "$AWGR_DOCKER_SERVICE" >/dev/null 2>&1 || true
        awgr_error "${LANG[AWGR_NET_ADMIN_MISSING]}"
        return 1
    fi

    rm -f "$backup_file"
    AWGR_DOCKER_CAP_ADDED=true
    AWGR_DOCKER_COMPOSE_FILE="$compose_file"
    awgr_ok "${LANG[AWGR_NET_ADMIN_ADDED]}"
}

awgr_rollback_node_net_admin() {
    local compose_file="${1:-$AWGR_DOCKER_COMPOSE_FILE}"
    local added="${2:-$AWGR_DOCKER_CAP_ADDED}"
    local service_name="${3:-$AWGR_DOCKER_SERVICE}"
    [ "$added" = "true" ] || return 0
    [ -n "$compose_file" ] || return 0
    awgr_unpatch_compose_net_admin "$compose_file" || return 1
    awgr_recreate_node_from_compose "$compose_file" "$service_name"
}

awgr_get_nodes() { awgr_api GET "/api/nodes"; }
awgr_get_node() { awgr_api GET "/api/nodes/$1"; }
awgr_get_profile() { awgr_api GET "/api/config-profiles/$1"; }

awgr_create_profile() {
    local name="$1"
    local config="$2"
    local payload
    payload=$(jq -n --arg name "$name" --argjson config "$config" '{name:$name,config:$config}') || return 1
    awgr_api POST "/api/config-profiles" "$payload"
}

awgr_delete_profile() {
    local uuid="$1"
    [ -n "$uuid" ] || return 0
    local response
    response=$(awgr_api DELETE "/api/config-profiles/$uuid")
    [ -z "$response" ] && return 0
    awgr_response_ok "$response"
}

awgr_assign_profile() {
    local node_uuid="$1"
    local profile_uuid="$2"
    local inbound_uuids="$3"
    local payload response
    payload=$(jq -n \
        --arg node "$node_uuid" \
        --arg profile "$profile_uuid" \
        --argjson inbounds "$inbound_uuids" \
        '{uuids:[$node],configProfile:{activeConfigProfileUuid:$profile,activeInbounds:$inbounds}}') || return 1
    response=$(awgr_api POST "/api/nodes/bulk-actions/profile-modification" "$payload")
    awgr_response_ok "$response"
}

awgr_restart_node() {
    local node_uuid="$1"
    local response
    response=$(awgr_api POST "/api/nodes/${node_uuid}/actions/restart" '{"forceRestart":false}')
    awgr_response_ok "$response"
}

awgr_map_tags_to_uuids() {
    local profile_response="$1"
    local tags_json="$2"
    echo "$profile_response" | jq -c --argjson tags "$tags_json" \
        '[.response.inbounds[]? | select(.tag as $tag | ($tags | index($tag)) != null) | .uuid]'
}

awgr_select_node() {
    local nodes_response="$1"
    local preferred_uuid="${2:-}"
    local uuids=() names=() addresses=()
    local uuid name address connected disabled
    local i=1 preferred_index=""

    while IFS=$'\t' read -r uuid name address connected disabled; do
        [ -n "$uuid" ] || continue
        uuids+=("$uuid")
        names+=("$name")
        addresses+=("$address")
        [ "$uuid" = "$preferred_uuid" ] && preferred_index="$i"
        printf "${COLOR_YELLOW}%d.${COLOR_RESET} %s ${COLOR_GRAY}[%s, %s%s]${COLOR_RESET}\n" \
            "$i" "$name" "$address" \
            "$([ "$connected" = "true" ] && echo online || echo offline)" \
            "$([ "$disabled" = "true" ] && echo ', disabled' || true)"
        i=$((i + 1))
    done < <(echo "$nodes_response" | jq -r '.response[]? | [.uuid,.name,.address,(.isConnected|tostring),(.isDisabled|tostring)] | @tsv')

    [ ${#uuids[@]} -gt 0 ] || return 1

    local prompt choice
    if [ -n "$preferred_index" ]; then
        prompt="$(printf "${LANG[AWGR_NODE_PROMPT_DEFAULT]}" "$preferred_index")"
    else
        prompt="${LANG[AWGR_NODE_PROMPT]}"
    fi
    reading "$prompt" choice
    choice="${choice:-$preferred_index}"

    if ! [[ "$choice" =~ ^[0-9]+$ ]] || [ "$choice" -lt 1 ] || [ "$choice" -gt ${#uuids[@]} ]; then
        awgr_error "${LANG[INVALID_CHOICE]}"
        return 1
    fi

    AWGR_SELECTED_NODE_UUID="${uuids[$((choice - 1))]}"
    AWGR_SELECTED_NODE_NAME="${names[$((choice - 1))]}"
    AWGR_SELECTED_NODE_ADDRESS="${addresses[$((choice - 1))]}"
}

awgr_find_preferred_node_uuid() {
    if [ -s "${DIR_REMNAWAVE}cascade_vless/state.json" ]; then
        jq -r '.entry.nodeUuid // empty' "${DIR_REMNAWAVE}cascade_vless/state.json" 2>/dev/null
    fi
}

awgr_find_preferred_outbound_tag() {
    local node_uuid="$1"
    if [ -s "${DIR_REMNAWAVE}cascade_vless/state.json" ]; then
        jq -r --arg node "$node_uuid" 'select(.entry.nodeUuid == $node) | .entry.outboundTag // empty' \
            "${DIR_REMNAWAVE}cascade_vless/state.json" 2>/dev/null
    fi
}

awgr_select_outbound() {
    local config="$1"
    local preferred_tag="${2:-}"
    local tags=() protocols=()
    local tag protocol
    local i=1 preferred_index=""

    # VLESS first: this is the intended RU -> FL Remnawave cascade path.
    while IFS=$'\t' read -r tag protocol; do
        [ -n "$tag" ] || continue
        tags+=("$tag"); protocols+=("$protocol")
    done < <(echo "$config" | jq -r '.outbounds[]? | select(.protocol == "vless") | [.tag,.protocol] | @tsv')

    # Then local direct/freedom as a supported fallback.
    while IFS=$'\t' read -r tag protocol; do
        [ -n "$tag" ] || continue
        tags+=("$tag"); protocols+=("$protocol")
    done < <(echo "$config" | jq -r '.outbounds[]? | select(.protocol == "freedom") | [.tag,.protocol] | @tsv')

    if [ ${#tags[@]} -eq 0 ]; then
        awgr_error "${LANG[AWGR_NO_OUTBOUND]}"
        return 1
    fi

    echo -e "${COLOR_GREEN}${LANG[AWGR_SELECT_OUTBOUND]}${COLOR_RESET}"
    for ((i=1; i<=${#tags[@]}; i++)); do
        tag="${tags[$((i - 1))]}"
        protocol="${protocols[$((i - 1))]}"
        [ "$tag" = "$preferred_tag" ] && preferred_index="$i"
        printf "${COLOR_YELLOW}%d.${COLOR_RESET} %s ${COLOR_GRAY}[%s]%s${COLOR_RESET}\n" \
            "$i" "$tag" "$protocol" \
            "$([ "$tag" = "$preferred_tag" ] && echo ' recommended' || true)"
    done

    local choice prompt
    if [ -n "$preferred_index" ]; then
        prompt="$(printf "${LANG[AWGR_OUTBOUND_PROMPT_DEFAULT]}" "$preferred_index")"
    else
        prompt="${LANG[AWGR_OUTBOUND_PROMPT]}"
    fi
    reading "$prompt" choice
    choice="${choice:-${preferred_index:-1}}"

    if ! [[ "$choice" =~ ^[0-9]+$ ]] || [ "$choice" -lt 1 ] || [ "$choice" -gt ${#tags[@]} ]; then
        awgr_error "${LANG[INVALID_CHOICE]}"
        return 1
    fi

    AWGR_SELECTED_OUTBOUND_TAG="${tags[$((choice - 1))]}"
    AWGR_SELECTED_OUTBOUND_PROTOCOL="${protocols[$((choice - 1))]}"
}

awgr_direct_tag() {
    local config="$1"
    local tag
    tag=$(echo "$config" | jq -r '.outbounds[]? | select(.protocol == "freedom") | .tag' | head -n1)
    echo "${tag:-DIRECT}"
}

awgr_build_profile_config() {
    local original_config="$1"
    local inbound_tag="$2"
    local tproxy_port="$3"
    local outbound_tag="$4"
    local route_mode="$5"
    local direct_tag="$6"

    local config
    config=$(jq -c \
        --arg inboundTag "$inbound_tag" \
        --argjson port "$tproxy_port" \
        --arg directTag "$direct_tag" '
        .inbounds = ((.inbounds // []) | map(select(.tag != $inboundTag)) + [{
            tag: $inboundTag,
            listen: "0.0.0.0",
            port: $port,
            protocol: "tunnel",
            settings: {allowedNetwork:"tcp,udp",followRedirect:true},
            sniffing: {enabled:true,destOverride:["http","tls","quic"],routeOnly:true},
            streamSettings: {sockopt:{tproxy:"tproxy"}}
        }])
        | .outbounds = (.outbounds // [])
        | if ([.outbounds[]? | select(.protocol == "freedom")] | length) == 0
          then .outbounds += [{tag:$directTag,protocol:"freedom",settings:{domainStrategy:"UseIPv4"}}]
          else . end
        | .routing = (.routing // {})
        | .routing.rules = ((.routing.rules // []) | map(select(((.ruleTag // "") | startswith("REMNA_AWG3_")) | not)))
    ' <<< "$original_config") || return 1

    if [ "$route_mode" = "ru_direct" ] && [ "$outbound_tag" != "$direct_tag" ]; then
        config=$(jq -c \
            --arg inbound "$inbound_tag" \
            --arg out "$outbound_tag" \
            --arg direct "$direct_tag" '
            ([.outbounds[]? | select(.protocol == "blackhole") | .tag] | map(select(type == "string" and length > 0))) as $blackholeTags
            | def awg_guard:
                (.outboundTag // "") as $outTag
                | ($outTag == "BLOCK") or
                  (($blackholeTags | index($outTag)) != null) or
                  (((.inboundTag // []) | map(ascii_downcase | contains("api")) | any));
            (.routing.rules // []) as $rules
            | ($rules | map(select(awg_guard))) as $guards
            | ($rules | map(select(awg_guard | not))) as $rest
            | .routing.rules = ($guards + [
                {type:"field",ruleTag:"REMNA_AWG3_RU_IP",inboundTag:[$inbound],ip:["geoip:ru"],outboundTag:$direct},
                {type:"field",ruleTag:"REMNA_AWG3_RU_DOMAIN",inboundTag:[$inbound],domain:["geosite:category-ru"],outboundTag:$direct},
                {type:"field",ruleTag:"REMNA_AWG3_DEFAULT",inboundTag:[$inbound],network:"tcp,udp",outboundTag:$out}
            ] + $rest)
        ' <<< "$config") || return 1
    else
        config=$(jq -c \
            --arg inbound "$inbound_tag" \
            --arg out "$outbound_tag" '
            ([.outbounds[]? | select(.protocol == "blackhole") | .tag] | map(select(type == "string" and length > 0))) as $blackholeTags
            | def awg_guard:
                (.outboundTag // "") as $outTag
                | ($outTag == "BLOCK") or
                  (($blackholeTags | index($outTag)) != null) or
                  (((.inboundTag // []) | map(ascii_downcase | contains("api")) | any));
            (.routing.rules // []) as $rules
            | ($rules | map(select(awg_guard))) as $guards
            | ($rules | map(select(awg_guard | not))) as $rest
            | .routing.rules = ($guards + [
                {type:"field",ruleTag:"REMNA_AWG3_DEFAULT",inboundTag:[$inbound],network:"tcp,udp",outboundTag:$out}
            ] + $rest)
        ' <<< "$config") || return 1
    fi

    echo "$config"
}

awgr_write_tproxy_runtime() {
    cat > "$AWGR_TPROXY_SCRIPT" <<'SCRIPT' || return 1
#!/bin/bash
set -euo pipefail

STATE_FILE="/usr/local/remnawave_reverse/amneziawg_remnawave/state.json"
CHAIN="REMNA_AWG3"
ACTION="${1:-start}"
IPT=(iptables -w 10)
RESOURCES_CREATED=false

[ -s "$STATE_FILE" ] || { echo "State file not found: $STATE_FILE" >&2; exit 1; }

IFACE=$(jq -r '.host.interface // "awg0"' "$STATE_FILE")
SUBNET=$(jq -r '.awg.subnet' "$STATE_FILE")
PORT=$(jq -r '.xray.tproxyPort' "$STATE_FILE")
MARK=$(jq -r '.host.mark // "0x66"' "$STATE_FILE")
TABLE=$(jq -r '.host.table // 166' "$STATE_FILE")
PRIORITY=$(jq -r '.host.priority // 10166' "$STATE_FILE")

cleanup() {
    local owned=false
    # A unique chain/jump is our ownership marker. Without it, do not touch
    # policy resources that may have been claimed by another service.
    if "${IPT[@]}" -t mangle -S "$CHAIN" >/dev/null 2>&1 \
        || "${IPT[@]}" -t mangle -C PREROUTING -i "$IFACE" -s "$SUBNET" -j "$CHAIN" >/dev/null 2>&1; then
        owned=true
    fi

    while "${IPT[@]}" -t mangle -D PREROUTING -i "$IFACE" -s "$SUBNET" -j "$CHAIN" 2>/dev/null; do :; done
    "${IPT[@]}" -t mangle -F "$CHAIN" 2>/dev/null || true
    "${IPT[@]}" -t mangle -X "$CHAIN" 2>/dev/null || true

    if [ "$owned" = true ] || [ "$RESOURCES_CREATED" = true ]; then
        ip -4 rule del pref "$PRIORITY" fwmark "${MARK}/0xffffffff" table "$TABLE" 2>/dev/null || true
        ip -4 route del local 0.0.0.0/0 dev lo table "$TABLE" 2>/dev/null || true
    fi
}

wait_for_xray() {
    local i
    for i in $(seq 1 60); do
        if ss -H -lntup 2>/dev/null | awk '{print $5}' | grep -Eq "(^|:)${PORT}$"; then
            return 0
        fi
        sleep 1
    done
    echo "Xray TPROXY port ${PORT} is not listening after 60 seconds" >&2
    return 1
}

case "$ACTION" in
    stop|down|remove)
        cleanup
        exit 0
        ;;
    start|up|apply)
        ;;
    *)
        echo "Usage: $0 {start|stop}" >&2
        exit 2
        ;;
esac

trap cleanup ERR
[ -e "/sys/class/net/${IFACE}" ] || { echo "Interface ${IFACE} does not exist" >&2; exit 1; }
wait_for_xray
cleanup
modprobe xt_TPROXY 2>/dev/null || true
modprobe nf_tproxy_ipv4 2>/dev/null || true

# Never overwrite another service's policy-routing resources.
if ip -4 rule show | grep -Eq "^[[:space:]]*${PRIORITY}:"; then
    echo "Policy-rule priority ${PRIORITY} is already occupied" >&2
    exit 1
fi
if [ -n "$(ip -4 route show table "$TABLE" 2>/dev/null || true)" ]; then
    echo "Routing table ${TABLE} is already occupied" >&2
    exit 1
fi

ip -4 route add local 0.0.0.0/0 dev lo table "$TABLE"
RESOURCES_CREATED=true
ip -4 rule add pref "$PRIORITY" fwmark "${MARK}/0xffffffff" table "$TABLE"

"${IPT[@]}" -t mangle -N "$CHAIN"
"${IPT[@]}" -t mangle -A "$CHAIN" -m addrtype --dst-type LOCAL -j RETURN
"${IPT[@]}" -t mangle -A "$CHAIN" -d "$SUBNET" -j RETURN
"${IPT[@]}" -t mangle -A "$CHAIN" -d 0.0.0.0/8 -j RETURN
"${IPT[@]}" -t mangle -A "$CHAIN" -d 10.0.0.0/8 -j RETURN
"${IPT[@]}" -t mangle -A "$CHAIN" -d 100.64.0.0/10 -j RETURN
"${IPT[@]}" -t mangle -A "$CHAIN" -d 127.0.0.0/8 -j RETURN
"${IPT[@]}" -t mangle -A "$CHAIN" -d 169.254.0.0/16 -j RETURN
"${IPT[@]}" -t mangle -A "$CHAIN" -d 172.16.0.0/12 -j RETURN
"${IPT[@]}" -t mangle -A "$CHAIN" -d 192.168.0.0/16 -j RETURN
"${IPT[@]}" -t mangle -A "$CHAIN" -d 224.0.0.0/3 -j RETURN
"${IPT[@]}" -t mangle -A "$CHAIN" -p tcp -j TPROXY --on-ip 0.0.0.0 --on-port "$PORT" --tproxy-mark "${MARK}/0xffffffff"
"${IPT[@]}" -t mangle -A "$CHAIN" -p udp -j TPROXY --on-ip 0.0.0.0 --on-port "$PORT" --tproxy-mark "${MARK}/0xffffffff"
"${IPT[@]}" -t mangle -A PREROUTING -i "$IFACE" -s "$SUBNET" -j "$CHAIN"
trap - ERR
SCRIPT
    chmod 700 "$AWGR_TPROXY_SCRIPT" || return 1

    cat > "$AWGR_TPROXY_UNIT" <<EOF || return 1
[Unit]
Description=Remnawave transparent proxy for AmneziaWG 3.0 clients
After=network-online.target docker.service ufw.service awg-quick@awg0.service
Wants=network-online.target docker.service awg-quick@awg0.service
ConditionPathExists=${AWGR_STATE_FILE}
ConditionPathExists=/sys/class/net/awg0

[Service]
Type=oneshot
ExecStart=${AWGR_TPROXY_SCRIPT} start
ExecStop=${AWGR_TPROXY_SCRIPT} stop
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

    cat > "$AWGR_RESUME_SCRIPT" <<'SCRIPT' || return 1
#!/bin/bash
set -euo pipefail

ENV_FILE="/usr/local/remnawave_reverse/amneziawg_remnawave/bootstrap.env"
STATE_FILE="/usr/local/remnawave_reverse/amneziawg_remnawave/state.json"
UNIT="remnawave-awg3-bootstrap.service"

[ -s "$ENV_FILE" ] || exit 0
# shellcheck disable=SC1090
source "$ENV_FILE"

finish_integration() {
    local module_version
    module_version="$(modinfo -F version amneziawg 2>/dev/null | head -n1)"
    if [[ "$module_version" != 3.* ]]; then
        logger -t remnawave-awg3 "Expected AmneziaWG 3.x, got ${module_version:-unknown}; TPROXY was not enabled"
        return 1
    fi

    systemctl daemon-reload
    systemctl enable --now remnawave-awg3-tproxy.service
    if [ -s "$STATE_FILE" ]; then
        local tmp="${STATE_FILE}.tmp.$$"
        if ! jq --arg moduleVersion "$module_version" '.enabled=true | .bootstrapPending=false | .awg.installedByModule=true | .awg.moduleVersion=$moduleVersion' "$STATE_FILE" > "$tmp" \
            || ! jq -e . "$tmp" >/dev/null 2>&1 \
            || ! chmod 600 "$tmp" \
            || ! mv -f "$tmp" "$STATE_FILE"; then
            rm -f "$tmp"
            systemctl disable --now remnawave-awg3-tproxy.service >/dev/null 2>&1 || true
            logger -t remnawave-awg3 "TPROXY started but integration state could not be saved; TPROXY was stopped"
            return 1
        fi
    else
        systemctl disable --now remnawave-awg3-tproxy.service >/dev/null 2>&1 || true
        logger -t remnawave-awg3 "State file disappeared; TPROXY was stopped"
        return 1
    fi
    systemctl disable "$UNIT" >/dev/null 2>&1 || true
    rm -f "$ENV_FILE"
    logger -t remnawave-awg3 "AmneziaWG ${module_version} installation completed; Remnawave TPROXY enabled"
}

if systemctl is-active --quiet awg-quick@awg0.service && ip link show awg0 >/dev/null 2>&1; then
    finish_integration
    exit 0
fi

args=(
    "--port=${AWG_BOOT_PORT}"
    "--subnet=${AWG_BOOT_SUBNET}"
    "--route-all"
    "--isolation=on"
    "--server-name=${AWG_BOOT_SERVER_NAME}"
    "--yes"
    "--no-tweaks"
    "--disallow-ipv6"
)
if [ "${AWG_BOOT_PRESET:-default}" = "mobile" ]; then
    args+=("--preset=mobile")
fi
if [ -n "${AWG_BOOT_ENDPOINT:-}" ]; then
    args+=("--endpoint=${AWG_BOOT_ENDPOINT}")
fi

bash "$AWG_BOOT_INSTALLER" "${args[@]}"

if systemctl is-active --quiet awg-quick@awg0.service && ip link show awg0 >/dev/null 2>&1; then
    finish_integration
else
    logger -t remnawave-awg3 "Installer returned but awg0 is not active; check journal and /root/awg"
    exit 1
fi
SCRIPT
    chmod 700 "$AWGR_RESUME_SCRIPT" || return 1

    cat > "$AWGR_BOOTSTRAP_UNIT" <<EOF || return 1
[Unit]
Description=Continue AmneziaWG 3.0 installation and enable Remnawave integration
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=${AWGR_RESUME_SCRIPT}
TimeoutStartSec=infinity

[Install]
WantedBy=multi-user.target
EOF

    cat > "$AWGR_SYSCTL_FILE" <<'SYSCTL' || return 1
# Required for AmneziaWG forwarding and marked TPROXY packets.
net.ipv4.ip_forward = 1
net.ipv4.conf.all.src_valid_mark = 1
SYSCTL
    chmod 644 "$AWGR_SYSCTL_FILE" || return 1
    chmod 644 "$AWGR_TPROXY_UNIT" "$AWGR_BOOTSTRAP_UNIT" || return 1

    systemctl daemon-reload || return 1
    sysctl -p "$AWGR_SYSCTL_FILE" >/dev/null 2>&1 || return 1
}

awgr_write_bootstrap_env() {
    local awg_port="$1"
    local awg_subnet="$2"
    local preset="$3"
    local server_name="$4"
    local endpoint="${5:-}"

    umask 077
    {
        printf 'AWG_BOOT_INSTALLER=%q\n' "$AWGR_INSTALLER"
        printf 'AWG_BOOT_PORT=%q\n' "$awg_port"
        printf 'AWG_BOOT_SUBNET=%q\n' "$awg_subnet"
        printf 'AWG_BOOT_PRESET=%q\n' "$preset"
        printf 'AWG_BOOT_SERVER_NAME=%q\n' "$server_name"
        printf 'AWG_BOOT_ENDPOINT=%q\n' "$endpoint"
    } > "$AWGR_BOOTSTRAP_ENV"
    chmod 600 "$AWGR_BOOTSTRAP_ENV"
}

awgr_remove_runtime() {
    local state_json="${1:-}"
    local restore_forward="${2:-false}"
    if [ -z "$state_json" ] && [ -s "$AWGR_STATE_FILE" ]; then
        state_json=$(cat "$AWGR_STATE_FILE")
    fi

    systemctl disable --now remnawave-awg3-bootstrap.service >/dev/null 2>&1 || true
    systemctl disable --now remnawave-awg3-tproxy.service >/dev/null 2>&1 || true
    "$AWGR_TPROXY_SCRIPT" stop >/dev/null 2>&1 || true
    rm -f "$AWGR_TPROXY_UNIT" "$AWGR_BOOTSTRAP_UNIT" "$AWGR_TPROXY_SCRIPT" "$AWGR_RESUME_SCRIPT" "$AWGR_SYSCTL_FILE" "$AWGR_BOOTSTRAP_ENV"
    systemctl daemon-reload >/dev/null 2>&1 || true
    awgr_restore_host_sysctl "$state_json" "$restore_forward"
}

awgr_restore_original_profile() {
    local state="$1"
    local node_uuid original_uuid original_inbounds original_tags original_name original_config
    node_uuid=$(echo "$state" | jq -r '.node.uuid')
    original_uuid=$(echo "$state" | jq -r '.profile.originalUuid')
    original_inbounds=$(echo "$state" | jq -c '.profile.originalActiveInbounds')
    original_tags=$(echo "$state" | jq -c '.profile.originalActiveTags')
    original_name=$(echo "$state" | jq -r '.profile.originalName')
    original_config=$(echo "$state" | jq -c '.profile.originalConfig')

    local profile_response
    profile_response=$(awgr_get_profile "$original_uuid")
    if awgr_response_ok "$profile_response"; then
        awgr_assign_profile "$node_uuid" "$original_uuid" "$original_inbounds"
        return $?
    fi

    awgr_warn "${LANG[AWGR_ORIGINAL_PROFILE_MISSING]}"
    local recovered_name recovered_response recovered_uuid recovered_inbounds
    recovered_name="$(awgr_safe_name "${original_name}-AWG3-Recovered-$(date +%Y%m%d%H%M%S)")"
    recovered_response=$(awgr_create_profile "$recovered_name" "$original_config")
    awgr_response_ok "$recovered_response" || return 1
    recovered_uuid=$(echo "$recovered_response" | jq -r '.response.uuid // empty')
    recovered_inbounds=$(awgr_map_tags_to_uuids "$recovered_response" "$original_tags")
    [ -n "$recovered_uuid" ] && jq -e 'type == "array"' >/dev/null 2>&1 <<< "$recovered_inbounds" || return 1
    awgr_assign_profile "$node_uuid" "$recovered_uuid" "$recovered_inbounds" || return 1

    local tmp="${AWGR_STATE_FILE}.tmp.$$"
    if ! jq --arg uuid "$recovered_uuid" '.profile.originalUuid=$uuid' "$AWGR_STATE_FILE" > "$tmp" \
        || ! jq -e 'type == "object" and .version == 4' "$tmp" >/dev/null 2>&1 \
        || ! chmod 600 "$tmp" \
        || ! mv -f "$tmp" "$AWGR_STATE_FILE"; then
        rm -f "$tmp"
        awgr_error "${LANG[AWGR_STATE_WRITE_ERROR]}"
        return 1
    fi
}

create_amneziawg_remnawave_integration() {
    awgr_requirements || return 1

    if [ -e "$AWGR_STATE_FILE" ]; then
        if [ "$(awgr_state_schema_version)" != "4" ]; then
            awgr_error "$(printf "${LANG[AWGR_LEGACY_STATE_DETECTED]}" "$(awgr_state_schema_version)")"
        else
            awgr_warn "${LANG[AWGR_ALREADY_EXISTS]}"
        fi
        return 1
    fi

    if awgr_legacy_runtime_exists; then
        awgr_error "${LANG[AWGR_LEGACY_RUNTIME_DETECTED]}"
        return 1
    fi

    awgr_require_awg3_before_create || return 1

    load_api_module >/dev/null 2>&1 || true
    get_panel_token || return 1

    local nodes_response preferred_node_uuid
    nodes_response=$(awgr_get_nodes)
    if ! awgr_response_ok "$nodes_response" || [ "$(echo "$nodes_response" | jq '.response | length')" -lt 1 ]; then
        awgr_error "${LANG[AWGR_NO_NODES]}"
        return 1
    fi

    preferred_node_uuid=$(awgr_find_preferred_node_uuid)
    awgr_warn "${LANG[AWGR_LOCAL_NODE_NOTICE]}"
    echo -e "\n${COLOR_GREEN}${LANG[AWGR_SELECT_NODE]}${COLOR_RESET}"
    awgr_select_node "$nodes_response" "$preferred_node_uuid" || return 1

    local node_uuid="$AWGR_SELECTED_NODE_UUID"
    local node_name="$AWGR_SELECTED_NODE_NAME"
    local node_address="$AWGR_SELECTED_NODE_ADDRESS"
    local node_response
    node_response=$(awgr_get_node "$node_uuid")
    awgr_response_ok "$node_response" || { awgr_error "${LANG[AWGR_NODE_READ_ERROR]}"; return 1; }

    local original_profile_uuid
    original_profile_uuid=$(echo "$node_response" | jq -r '.response.configProfile.activeConfigProfileUuid // empty')
    [ -n "$original_profile_uuid" ] || { awgr_error "${LANG[AWGR_PROFILE_REQUIRED]}"; return 1; }

    local profile_response original_name original_config
    profile_response=$(awgr_get_profile "$original_profile_uuid")
    awgr_response_ok "$profile_response" || { awgr_error "${LANG[AWGR_PROFILE_READ_ERROR]}"; return 1; }
    original_name=$(echo "$profile_response" | jq -r '.response.name // "Profile"')
    original_config=$(echo "$profile_response" | jq -c '.response.config')

    local preferred_outbound
    preferred_outbound=$(awgr_find_preferred_outbound_tag "$node_uuid")
    awgr_select_outbound "$original_config" "$preferred_outbound" || return 1
    local outbound_tag="$AWGR_SELECTED_OUTBOUND_TAG"
    local outbound_protocol="$AWGR_SELECTED_OUTBOUND_PROTOCOL"

    local route_mode="all"
    if [ "$outbound_protocol" = "vless" ]; then
        echo -e "\n${COLOR_GREEN}${LANG[AWGR_ROUTING_MODE]}${COLOR_RESET}"
        echo -e "${COLOR_YELLOW}1. ${LANG[AWGR_ROUTE_ALL]}${COLOR_RESET}"
        echo -e "${COLOR_YELLOW}2. ${LANG[AWGR_ROUTE_RU_DIRECT]}${COLOR_RESET}"
        local route_choice
        reading "${LANG[AWGR_ROUTING_PROMPT]}" route_choice
        route_choice="${route_choice:-2}"
        case "$route_choice" in
            1) route_mode="all" ;;
            2) route_mode="ru_direct" ;;
            *) awgr_error "${LANG[INVALID_CHOICE]}"; return 1 ;;
        esac
    fi

    local tproxy_port
    reading "${LANG[AWGR_TPROXY_PORT_PROMPT]}" tproxy_port
    tproxy_port="${tproxy_port:-12345}"
    awgr_valid_port "$tproxy_port" || { awgr_error "${LANG[AWGR_INVALID_PORT]}"; return 1; }
    if echo "$original_config" | jq -e --argjson port "$tproxy_port" '.inbounds[]? | select(.port == $port)' >/dev/null; then
        awgr_error "$(printf "${LANG[AWGR_PROFILE_PORT_IN_USE]}" "$tproxy_port")"
        return 1
    fi
    if ss -H -lntup 2>/dev/null | awk '{print $5}' | grep -Eq "(^|:)$tproxy_port$"; then
        awgr_error "$(printf "${LANG[AWGR_LOCAL_PORT_IN_USE]}" "$tproxy_port")"
        return 1
    fi

    local awg_installed=false awg_port awg_subnet awg_preset="default" awg_server_name awg_endpoint=""
    if systemctl is-active --quiet awg-quick@awg0.service && ip link show awg0 >/dev/null 2>&1; then
        if ! awgr_read_existing_awg; then
            awgr_error "${LANG[AWGR_EXISTING_AWG_CONFIG_ERROR]}"
            return 1
        fi
        awg_installed=true
        awg_port="$AWGR_EXISTING_PORT"
        awg_subnet="$AWGR_EXISTING_SUBNET"
        awg_preset="$AWGR_EXISTING_PRESET"
        awg_server_name="$AWGR_EXISTING_SERVER_NAME"
        awg_endpoint="${AWGR_EXISTING_ENDPOINT:-}"
        awgr_ok "${LANG[AWGR_EXISTING_AWG_FOUND]}"
    elif [ -f "$AWGR_AWG_CONFIG" ] || [ -f "$AWGR_AWG_SERVER_CONFIG" ] || ip link show awg0 >/dev/null 2>&1; then
        awgr_error "${LANG[AWGR_EXISTING_AWG_INACTIVE]}"
        return 1
    else
        reading "${LANG[AWGR_PORT_PROMPT]}" awg_port
        awg_port="${awg_port:-38389}"
        awgr_valid_port "$awg_port" || { awgr_error "${LANG[AWGR_INVALID_PORT]}"; return 1; }
        if awgr_udp_port_in_use "$awg_port"; then
            awgr_error "$(printf "${LANG[AWGR_AWG_PORT_IN_USE]}" "$awg_port")"
            return 1
        fi

        reading "${LANG[AWGR_SUBNET_PROMPT]}" awg_subnet
        awg_subnet="${awg_subnet:-172.16.17.0/24}"
        if ! python3 - "$awg_subnet" <<'PY' >/dev/null 2>&1
import ipaddress,sys
n=ipaddress.ip_network(sys.argv[1], strict=False)
assert n.version == 4 and n.is_private and 16 <= n.prefixlen <= 30
PY
        then
            awgr_error "${LANG[AWGR_INVALID_SUBNET]}"
            return 1
        fi

        echo -e "${COLOR_YELLOW}1. ${LANG[AWGR_PRESET_DEFAULT]}${COLOR_RESET}"
        echo -e "${COLOR_YELLOW}2. ${LANG[AWGR_PRESET_MOBILE]}${COLOR_RESET}"
        local preset_choice
        reading "${LANG[AWGR_PRESET_PROMPT]}" preset_choice
        preset_choice="${preset_choice:-1}"
        case "$preset_choice" in
            1) awg_preset="default" ;;
            2) awg_preset="mobile" ;;
            *) awgr_error "${LANG[INVALID_CHOICE]}"; return 1 ;;
        esac
        awg_server_name="Remnawave AWG3 RU"

        reading "${LANG[AWGR_ENDPOINT_PROMPT]}" awg_endpoint
        awg_endpoint="${awg_endpoint%.}"
        if [ -n "$awg_endpoint" ]; then
            if ! awgr_valid_fqdn "$awg_endpoint"; then
                awgr_error "${LANG[AWGR_ENDPOINT_INVALID]}"
                return 1
            fi

            local awg_public_ip awg_resolved_ips
            if ! awg_public_ip=$(awgr_public_ipv4); then
                awgr_error "${LANG[AWGR_PUBLIC_IP_ERROR]}"
                return 1
            fi
            if ! awg_resolved_ips=$(awgr_resolve_ipv4 "$awg_endpoint"); then
                awgr_error "$(printf "${LANG[AWGR_ENDPOINT_RESOLVE_ERROR]}" "$awg_endpoint")"
                return 1
            fi
            if ! grep -Fqx "$awg_public_ip" <<< "$awg_resolved_ips"; then
                awgr_error "$(printf "${LANG[AWGR_ENDPOINT_MISMATCH]}" "$awg_endpoint" "$(tr '\n' ',' <<< "$awg_resolved_ips" | sed 's/,$//')" "$awg_public_ip")"
                return 1
            fi
            awgr_ok "$(printf "${LANG[AWGR_ENDPOINT_OK]}" "$awg_endpoint" "$awg_public_ip")"
        else
            awgr_info "${LANG[AWGR_ENDPOINT_AUTO]}"
        fi
    fi

    # The installer stores server_address/prefix (for example 10.9.9.1/24),
    # while iptables source matching must use the canonical network CIDR.
    awg_subnet=$(python3 - "$awg_subnet" <<'PYNET'
import ipaddress,sys
print(ipaddress.ip_network(sys.argv[1], strict=False))
PYNET
) || { awgr_error "${LANG[AWGR_INVALID_SUBNET]}"; return 1; }

    if [ "$awg_installed" = false ]; then
        local conflicting_route
        conflicting_route=$(awgr_subnet_conflicts "$awg_subnet" 2>/dev/null || true)
        if [ -n "$conflicting_route" ]; then
            awgr_error "$(printf "${LANG[AWGR_SUBNET_CONFLICT]}" "$awg_subnet" "$conflicting_route")"
            return 1
        fi
    fi

    awgr_select_tproxy_resources || return 1

    local inbound_tag="AWG3_TPROXY_IN"
    local direct_tag
    direct_tag=$(awgr_direct_tag "$original_config")

    local new_config
    new_config=$(awgr_build_profile_config "$original_config" "$inbound_tag" "$tproxy_port" "$outbound_tag" "$route_mode" "$direct_tag") || {
        awgr_error "${LANG[AWGR_CONFIG_BUILD_ERROR]}"
        return 1
    }

    local original_active_inbounds original_active_tags
    original_active_inbounds=$(echo "$node_response" | jq -c '[.response.configProfile.activeInbounds[]? | .uuid]')
    original_active_tags=$(echo "$node_response" | jq -c '[.response.configProfile.activeInbounds[]? | .tag]')

    if ! awgr_ensure_node_net_admin; then
        return 1
    fi

    local new_profile_name new_profile_response new_profile_uuid new_inbound_uuid new_active_inbounds
    new_profile_name="$(awgr_safe_name "${original_name}-AWG3-$(date +%Y%m%d%H%M%S)")"
    new_profile_response=$(awgr_create_profile "$new_profile_name" "$new_config")
    if ! awgr_response_ok "$new_profile_response"; then
        awgr_rollback_node_net_admin >/dev/null 2>&1 || true
        awgr_error "${LANG[AWGR_PROFILE_CREATE_ERROR]}"
        return 1
    fi
    new_profile_uuid=$(echo "$new_profile_response" | jq -r '.response.uuid // empty')
    new_inbound_uuid=$(echo "$new_profile_response" | jq -r --arg tag "$inbound_tag" '.response.inbounds[]? | select(.tag == $tag) | .uuid' | head -n1)
    [ -n "$new_profile_uuid" ] && [ -n "$new_inbound_uuid" ] || {
        awgr_delete_profile "$new_profile_uuid" >/dev/null 2>&1 || true
        awgr_rollback_node_net_admin >/dev/null 2>&1 || true
        awgr_error "${LANG[AWGR_PROFILE_CREATE_ERROR]}"
        return 1
    }

    new_active_inbounds=$(awgr_map_tags_to_uuids "$new_profile_response" "$original_active_tags")
    if ! jq -e 'type == "array"' >/dev/null 2>&1 <<< "$new_active_inbounds"; then
        awgr_delete_profile "$new_profile_uuid" >/dev/null 2>&1 || true
        awgr_rollback_node_net_admin >/dev/null 2>&1 || true
        awgr_error "${LANG[AWGR_PROFILE_CREATE_ERROR]}"
        return 1
    fi
    new_active_inbounds=$(jq -c --arg uuid "$new_inbound_uuid" '. + [$uuid] | map(select(length > 0)) | unique' <<< "$new_active_inbounds")

    if ! awgr_assign_profile "$node_uuid" "$new_profile_uuid" "$new_active_inbounds"; then
        awgr_delete_profile "$new_profile_uuid" >/dev/null 2>&1 || true
        awgr_rollback_node_net_admin >/dev/null 2>&1 || true
        awgr_error "${LANG[AWGR_PROFILE_ASSIGN_ERROR]}"
        return 1
    fi
    awgr_restart_node "$node_uuid" >/dev/null 2>&1 || true

    local created_at state previous_ip_forward previous_src_valid_mark awg_module_version
    created_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    awg_module_version="$(awgr_module_version)"
    previous_ip_forward=$(awgr_read_sysctl_value net.ipv4.ip_forward 0)
    previous_src_valid_mark=$(awgr_read_sysctl_value net.ipv4.conf.all.src_valid_mark 0)
    state=$(jq -n \
        --arg createdAt "$created_at" \
        --arg nodeUuid "$node_uuid" --arg nodeName "$node_name" --arg nodeAddress "$node_address" \
        --arg originalUuid "$original_profile_uuid" --arg originalName "$original_name" --argjson originalConfig "$original_config" \
        --argjson originalActiveInbounds "$original_active_inbounds" --argjson originalActiveTags "$original_active_tags" \
        --arg integrationUuid "$new_profile_uuid" --arg integrationName "$new_profile_name" --argjson integrationActiveInbounds "$new_active_inbounds" \
        --arg inboundUuid "$new_inbound_uuid" --arg inboundTag "$inbound_tag" --argjson tproxyPort "$tproxy_port" \
        --arg outboundTag "$outbound_tag" --arg outboundProtocol "$outbound_protocol" --arg directTag "$direct_tag" --arg routeMode "$route_mode" \
        --arg awgPort "$awg_port" --arg awgSubnet "$awg_subnet" --arg awgPreset "$awg_preset" --arg awgServerName "$awg_server_name" --arg awgEndpoint "$awg_endpoint" \
        --arg awgModuleVersion "$awg_module_version" --argjson awgPreinstalled "$awg_installed" \
        --arg hostMark "$AWGR_SELECTED_MARK" --argjson hostTable "$AWGR_SELECTED_TABLE" --argjson hostPriority "$AWGR_SELECTED_PRIORITY" \
        --argjson previousIpForward "$previous_ip_forward" --argjson previousSrcValidMark "$previous_src_valid_mark" \
        --arg dockerComposeFile "$AWGR_DOCKER_COMPOSE_FILE" --arg dockerService "$AWGR_DOCKER_SERVICE" --argjson dockerCapAdded "$AWGR_DOCKER_CAP_ADDED" \
        '{version:4,createdAt:$createdAt,enabled:false,bootstrapPending:($awgPreinstalled|not),node:{uuid:$nodeUuid,name:$nodeName,address:$nodeAddress},profile:{originalUuid:$originalUuid,originalName:$originalName,originalConfig:$originalConfig,originalActiveInbounds:$originalActiveInbounds,originalActiveTags:$originalActiveTags,integrationUuid:$integrationUuid,integrationName:$integrationName,integrationActiveInbounds:$integrationActiveInbounds},xray:{inboundUuid:$inboundUuid,inboundTag:$inboundTag,tproxyPort:$tproxyPort,outboundTag:$outboundTag,outboundProtocol:$outboundProtocol,directTag:$directTag,routeMode:$routeMode},awg:{interface:"awg0",port:($awgPort|tonumber),subnet:$awgSubnet,preset:$awgPreset,serverName:$awgServerName,endpoint:$awgEndpoint,moduleVersion:$awgModuleVersion,preinstalled:$awgPreinstalled,installedByModule:false},host:{interface:"awg0",mark:$hostMark,table:$hostTable,priority:$hostPriority,ufwRuleAdded:false,previousIpForward:$previousIpForward,previousSrcValidMark:$previousSrcValidMark},docker:{composeFile:$dockerComposeFile,service:$dockerService,netAdminAdded:$dockerCapAdded}}') || {
        awgr_restore_original_profile "$(jq -n --arg node "$node_uuid" --arg profile "$original_profile_uuid" --argjson inbounds "$original_active_inbounds" '{node:{uuid:$node},profile:{originalUuid:$profile,originalActiveInbounds:$inbounds}}')" >/dev/null 2>&1 || true
        awgr_delete_profile "$new_profile_uuid" >/dev/null 2>&1 || true
        awgr_rollback_node_net_admin >/dev/null 2>&1 || true
        awgr_error "${LANG[AWGR_STATE_WRITE_ERROR]}"
        return 1
    }

    umask 077
    local state_tmp="${AWGR_STATE_FILE}.tmp.$$"
    if ! printf '%s\n' "$state" > "$state_tmp" \
        || ! jq -e 'type == "object" and .version == 4' "$state_tmp" >/dev/null 2>&1 \
        || ! chmod 600 "$state_tmp" \
        || ! mv -f "$state_tmp" "$AWGR_STATE_FILE"; then
        rm -f "$state_tmp"
        awgr_restore_original_profile "$state" >/dev/null 2>&1 || true
        awgr_delete_profile "$new_profile_uuid" >/dev/null 2>&1 || true
        awgr_rollback_node_net_admin >/dev/null 2>&1 || true
        awgr_error "${LANG[AWGR_STATE_WRITE_ERROR]}"
        return 1
    fi

    if ! awgr_write_tproxy_runtime; then
        awgr_remove_runtime "$state" "$([ "$awg_installed" = false ] && echo true || echo false)"
        awgr_restore_original_profile "$state" >/dev/null 2>&1 || true
        awgr_delete_profile "$new_profile_uuid" >/dev/null 2>&1 || true
        rm -f "$AWGR_STATE_FILE"
        awgr_rollback_node_net_admin >/dev/null 2>&1 || true
        awgr_error "${LANG[AWGR_RUNTIME_ERROR]}"
        return 1
    fi

    if ! awgr_ensure_ufw_rule "$awg_port"; then
        awgr_remove_runtime "$state" "$([ "$awg_installed" = false ] && echo true || echo false)"
        awgr_restore_original_profile "$state" >/dev/null 2>&1 || true
        awgr_delete_profile "$new_profile_uuid" >/dev/null 2>&1 || true
        rm -f "$AWGR_STATE_FILE"
        awgr_rollback_node_net_admin >/dev/null 2>&1 || true
        return 1
    fi
    if [ "$AWGR_UFW_RULE_ADDED" = true ]; then
        local ufw_tmp="${AWGR_STATE_FILE}.tmp.$$"
        if ! jq '.host.ufwRuleAdded=true' "$AWGR_STATE_FILE" > "$ufw_tmp" \
            || ! jq -e . "$ufw_tmp" >/dev/null 2>&1 \
            || ! chmod 600 "$ufw_tmp" \
            || ! mv -f "$ufw_tmp" "$AWGR_STATE_FILE"; then
            rm -f "$ufw_tmp"
            awgr_remove_ufw_rule "$awg_port" true
            awgr_remove_runtime "$state" "$([ "$awg_installed" = false ] && echo true || echo false)"
            awgr_restore_original_profile "$state" >/dev/null 2>&1 || true
            awgr_delete_profile "$new_profile_uuid" >/dev/null 2>&1 || true
            rm -f "$AWGR_STATE_FILE"
            awgr_rollback_node_net_admin >/dev/null 2>&1 || true
            awgr_error "${LANG[AWGR_STATE_WRITE_ERROR]}"
            return 1
        fi
        state=$(cat "$AWGR_STATE_FILE")
    fi

    if [ "$awg_installed" = true ]; then
        if systemctl enable --now remnawave-awg3-tproxy.service; then
            local tmp="${AWGR_STATE_FILE}.tmp.$$"
            if ! jq '.enabled=true | .bootstrapPending=false' "$AWGR_STATE_FILE" > "$tmp" \
                || ! jq -e . "$tmp" >/dev/null 2>&1 \
                || ! chmod 600 "$tmp" \
                || ! mv -f "$tmp" "$AWGR_STATE_FILE"; then
                rm -f "$tmp"
                awgr_remove_ufw_rule "$awg_port" "$AWGR_UFW_RULE_ADDED"
                awgr_remove_runtime "$state" false
                awgr_restore_original_profile "$state" >/dev/null 2>&1 || true
                awgr_delete_profile "$new_profile_uuid" >/dev/null 2>&1 || true
                rm -f "$AWGR_STATE_FILE"
                awgr_rollback_node_net_admin >/dev/null 2>&1 || true
                awgr_error "${LANG[AWGR_STATE_WRITE_ERROR]}"
                return 1
            fi
            awgr_ok "${LANG[AWGR_CREATED_EXISTING]}"
        else
            awgr_remove_ufw_rule "$awg_port" "$AWGR_UFW_RULE_ADDED"
            awgr_remove_runtime "$state" false
            awgr_restore_original_profile "$state" >/dev/null 2>&1 || true
            awgr_delete_profile "$new_profile_uuid" >/dev/null 2>&1 || true
            rm -f "$AWGR_STATE_FILE"
            awgr_rollback_node_net_admin >/dev/null 2>&1 || true
            awgr_error "${LANG[AWGR_TPROXY_START_ERROR]}"
            return 1
        fi
    else
        if ! awgr_write_bootstrap_env "$awg_port" "$awg_subnet" "$awg_preset" "$awg_server_name" "$awg_endpoint" \
            || ! systemctl enable remnawave-awg3-bootstrap.service >/dev/null 2>&1 \
            || ! systemctl start --no-block remnawave-awg3-bootstrap.service; then
            awgr_remove_ufw_rule "$awg_port" "$AWGR_UFW_RULE_ADDED"
            awgr_remove_runtime "$state" true
            awgr_restore_original_profile "$state" >/dev/null 2>&1 || true
            awgr_delete_profile "$new_profile_uuid" >/dev/null 2>&1 || true
            rm -f "$AWGR_STATE_FILE"
            awgr_rollback_node_net_admin >/dev/null 2>&1 || true
            awgr_error "${LANG[AWGR_BOOTSTRAP_START_ERROR]}"
            return 1
        fi
        awgr_warn "${LANG[AWGR_REBOOT_WARNING]}"
        awgr_ok "${LANG[AWGR_PROFILE_READY]}"
        awgr_info "${LANG[AWGR_BOOTSTRAP_STARTED]}"
    fi

    local endpoint_display="${awg_endpoint:-${LANG[AWGR_ENDPOINT_AUTO_VALUE]}}"
    printf "${LANG[AWGR_SUMMARY]}\n" "$node_name" "$outbound_tag" "$route_mode" "$awg_port" "$awg_subnet" "$endpoint_display" "$tproxy_port"
}

amneziawg_remnawave_status() {
    awgr_requirements || return 1
    [ -s "$AWGR_STATE_FILE" ] || { awgr_warn "${LANG[AWGR_NOT_FOUND]}"; return 1; }
    awgr_require_current_state_schema || return 1

    local state
    state=$(cat "$AWGR_STATE_FILE")
    echo -e "\n${COLOR_GREEN}${LANG[AWGR_STATUS_TITLE]}${COLOR_RESET}"
    printf "${LANG[AWGR_STATUS_ENABLED]}\n" "$(echo "$state" | jq -r '.enabled')"
    printf "${LANG[AWGR_STATUS_NODE]}\n" "$(echo "$state" | jq -r '.node.name')" "$(echo "$state" | jq -r '.node.uuid')"
    printf "${LANG[AWGR_STATUS_ROUTE]}\n" "$(echo "$state" | jq -r '.xray.outboundTag')" "$(echo "$state" | jq -r '.xray.routeMode')"
    printf "${LANG[AWGR_STATUS_PORTS]}\n" "$(echo "$state" | jq -r '.awg.port')" "$(echo "$state" | jq -r '.xray.tproxyPort')"
    local saved_endpoint
    saved_endpoint=$(echo "$state" | jq -r '.awg.endpoint // empty')
    printf "${LANG[AWGR_STATUS_ENDPOINT]}\n" "${saved_endpoint:-${LANG[AWGR_ENDPOINT_AUTO_VALUE]}}"
    local module_version
    module_version="$(awgr_module_version)"
    if [[ "$module_version" == 3.* ]]; then
        awgr_ok "$(printf "${LANG[AWGR_STATUS_MODULE]}" "$module_version")"
    else
        awgr_warn "$(printf "${LANG[AWGR_STATUS_MODULE_UNEXPECTED]}" "${module_version:-unknown}")"
    fi

    if systemctl is-active --quiet awg-quick@awg0.service && ip link show awg0 >/dev/null 2>&1; then
        awgr_ok "${LANG[AWGR_STATUS_AWG_OK]}"
        awg show awg0 2>/dev/null | sed -n '1,24p' || true
    else
        awgr_warn "${LANG[AWGR_STATUS_AWG_WAIT]}"
    fi

    if systemctl is-active --quiet remnawave-awg3-bootstrap.service; then
        awgr_warn "${LANG[AWGR_STATUS_BOOTSTRAP]}"
    fi

    if systemctl is-active --quiet remnawave-awg3-tproxy.service; then
        awgr_ok "${LANG[AWGR_STATUS_TPROXY_OK]}"
    else
        awgr_warn "${LANG[AWGR_STATUS_TPROXY_OFF]}"
    fi

    local table priority mark iface subnet
    table=$(echo "$state" | jq -r '.host.table')
    priority=$(echo "$state" | jq -r '.host.priority')
    mark=$(echo "$state" | jq -r '.host.mark')
    iface=$(echo "$state" | jq -r '.host.interface // "awg0"')
    subnet=$(echo "$state" | jq -r '.awg.subnet')
    ip -4 rule show | grep -Eiq "^[[:space:]]*${priority}:.*fwmark[[:space:]]+${mark}(/0x[[:xdigit:]]+)?([[:space:]]|$).*(lookup|table)[[:space:]]+${table}([[:space:]]|$)" \
        && awgr_ok "${LANG[AWGR_STATUS_RULE_OK]}" \
        || awgr_warn "${LANG[AWGR_STATUS_RULE_MISSING]}"
    ip -4 route show table "$table" 2>/dev/null | grep -q '^local default dev lo' \
        && awgr_ok "${LANG[AWGR_STATUS_ROUTE_OK]}" \
        || awgr_warn "${LANG[AWGR_STATUS_ROUTE_MISSING]}"
    iptables -w 10 -t mangle -C PREROUTING -i "$iface" -s "$subnet" -j REMNA_AWG3 >/dev/null 2>&1 \
        && awgr_ok "${LANG[AWGR_STATUS_IPTABLES_OK]}" \
        || awgr_warn "${LANG[AWGR_STATUS_IPTABLES_MISSING]}"

    local port
    port=$(echo "$state" | jq -r '.xray.tproxyPort')
    ss -H -lntup 2>/dev/null | awk '{print $5}' | grep -Eq "(^|:)$port$" \
        && awgr_ok "$(printf "${LANG[AWGR_STATUS_XRAY_LISTEN]}" "$port")" \
        || awgr_warn "$(printf "${LANG[AWGR_STATUS_XRAY_NOT_LISTEN]}" "$port")"

    if [ -d /opt/remnawave ]; then
        get_panel_token >/dev/null 2>&1 || return 0
        local node_response active_profile expected_profile
        node_response=$(awgr_get_node "$(echo "$state" | jq -r '.node.uuid')")
        expected_profile=$(echo "$state" | jq -r '.profile.integrationUuid')
        active_profile=$(echo "$node_response" | jq -r '.response.configProfile.activeConfigProfileUuid // empty' 2>/dev/null)
        if [ "$active_profile" = "$expected_profile" ]; then
            awgr_ok "${LANG[AWGR_STATUS_PROFILE_OK]}"
        else
            awgr_warn "${LANG[AWGR_STATUS_PROFILE_MISMATCH]}"
        fi
    fi
}

disable_amneziawg_remnawave() {
    awgr_requirements || return 1
    [ -s "$AWGR_STATE_FILE" ] || { awgr_warn "${LANG[AWGR_NOT_FOUND]}"; return 1; }
    awgr_require_current_state_schema || return 1
    get_panel_token || return 1

    local state
    state=$(cat "$AWGR_STATE_FILE")
    systemctl disable --now remnawave-awg3-bootstrap.service >/dev/null 2>&1 || true
    systemctl disable --now remnawave-awg3-tproxy.service >/dev/null 2>&1 || true
    "$AWGR_TPROXY_SCRIPT" stop >/dev/null 2>&1 || true

    if ! awgr_restore_original_profile "$state"; then
        awgr_error "${LANG[AWGR_RESTORE_ERROR]}"
        return 1
    fi
    awgr_restart_node "$(echo "$state" | jq -r '.node.uuid')" >/dev/null 2>&1 || true

    local tmp="${AWGR_STATE_FILE}.tmp.$$"
    if ! jq '.enabled=false | .bootstrapPending=false' "$AWGR_STATE_FILE" > "$tmp" \
        || ! jq -e . "$tmp" >/dev/null 2>&1 \
        || ! chmod 600 "$tmp" \
        || ! mv -f "$tmp" "$AWGR_STATE_FILE"; then
        rm -f "$tmp"
        # Keep state and actual routing consistent by restoring the integration.
        awgr_assign_profile "$(echo "$state" | jq -r '.node.uuid')" "$(echo "$state" | jq -r '.profile.integrationUuid')" "$(echo "$state" | jq -c '.profile.integrationActiveInbounds')" >/dev/null 2>&1 || true
        awgr_restart_node "$(echo "$state" | jq -r '.node.uuid')" >/dev/null 2>&1 || true
        awgr_write_tproxy_runtime >/dev/null 2>&1 || true
        systemctl enable --now remnawave-awg3-tproxy.service >/dev/null 2>&1 || true
        awgr_error "${LANG[AWGR_STATE_WRITE_ERROR]}"
        return 1
    fi
    awgr_ok "${LANG[AWGR_DISABLED]}"
}

enable_amneziawg_remnawave() {
    awgr_requirements || return 1
    [ -s "$AWGR_STATE_FILE" ] || { awgr_warn "${LANG[AWGR_NOT_FOUND]}"; return 1; }
    awgr_require_current_state_schema || return 1
    get_panel_token || return 1

    if ! systemctl is-active --quiet awg-quick@awg0.service; then
        awgr_error "${LANG[AWGR_ENABLE_AWG_REQUIRED]}"
        return 1
    fi

    local state node profile inbounds
    state=$(cat "$AWGR_STATE_FILE")
    node=$(echo "$state" | jq -r '.node.uuid')
    profile=$(echo "$state" | jq -r '.profile.integrationUuid')
    inbounds=$(echo "$state" | jq -c '.profile.integrationActiveInbounds')

    local profile_response
    profile_response=$(awgr_get_profile "$profile")
    awgr_response_ok "$profile_response" || { awgr_error "${LANG[AWGR_INTEGRATION_PROFILE_MISSING]}"; return 1; }

    awgr_assign_profile "$node" "$profile" "$inbounds" || { awgr_error "${LANG[AWGR_PROFILE_ASSIGN_ERROR]}"; return 1; }
    awgr_restart_node "$node" >/dev/null 2>&1 || true
    if ! awgr_write_tproxy_runtime; then
        awgr_restore_original_profile "$state" >/dev/null 2>&1 || true
        awgr_restart_node "$node" >/dev/null 2>&1 || true
        awgr_error "${LANG[AWGR_RUNTIME_ERROR]}"
        return 1
    fi
    sleep 2
    if ! systemctl enable --now remnawave-awg3-tproxy.service; then
        awgr_remove_runtime "$state" false
        awgr_restore_original_profile "$state" >/dev/null 2>&1 || true
        awgr_restart_node "$node" >/dev/null 2>&1 || true
        awgr_error "${LANG[AWGR_TPROXY_START_ERROR]}"
        return 1
    fi

    local tmp="${AWGR_STATE_FILE}.tmp.$$"
    if ! jq '.enabled=true | .bootstrapPending=false' "$AWGR_STATE_FILE" > "$tmp" \
        || ! jq -e . "$tmp" >/dev/null 2>&1 \
        || ! chmod 600 "$tmp" \
        || ! mv -f "$tmp" "$AWGR_STATE_FILE"; then
        rm -f "$tmp"
        awgr_remove_runtime "$state" false
        awgr_restore_original_profile "$state" >/dev/null 2>&1 || true
        awgr_restart_node "$node" >/dev/null 2>&1 || true
        awgr_error "${LANG[AWGR_STATE_WRITE_ERROR]}"
        return 1
    fi
    awgr_ok "${LANG[AWGR_ENABLED]}"
}

remove_amneziawg_remnawave() {
    awgr_requirements || return 1
    [ -s "$AWGR_STATE_FILE" ] || { awgr_warn "${LANG[AWGR_NOT_FOUND]}"; return 1; }
    awgr_require_current_state_schema || return 1

    echo -e "${COLOR_RED}${LANG[AWGR_REMOVE_CONFIRM]}${COLOR_RESET}"
    local confirm
    read -r confirm
    if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
        awgr_warn "${LANG[AWGR_REMOVE_CANCELLED]}"
        return 0
    fi

    get_panel_token || return 1
    local state node integration_uuid installed_by_module docker_compose_file docker_service docker_cap_added awg_port ufw_rule_added
    state=$(cat "$AWGR_STATE_FILE")
    node=$(echo "$state" | jq -r '.node.uuid')
    integration_uuid=$(echo "$state" | jq -r '.profile.integrationUuid')
    installed_by_module=$(echo "$state" | jq -r '.awg.installedByModule')
    docker_compose_file=$(echo "$state" | jq -r '.docker.composeFile // empty')
    docker_service=$(echo "$state" | jq -r '.docker.service // "remnanode"')
    docker_cap_added=$(echo "$state" | jq -r '.docker.netAdminAdded // false')
    awg_port=$(echo "$state" | jq -r '.awg.port')
    ufw_rule_added=$(echo "$state" | jq -r '.host.ufwRuleAdded // false')

    systemctl disable --now remnawave-awg3-bootstrap.service >/dev/null 2>&1 || true
    systemctl disable --now remnawave-awg3-tproxy.service >/dev/null 2>&1 || true
    "$AWGR_TPROXY_SCRIPT" stop >/dev/null 2>&1 || true

    if ! awgr_restore_original_profile "$state"; then
        awgr_error "${LANG[AWGR_RESTORE_ERROR]}"
        return 1
    fi
    awgr_restart_node "$node" >/dev/null 2>&1 || true
    awgr_remove_runtime "$state" false
    awgr_delete_profile "$integration_uuid" || awgr_warn "${LANG[AWGR_DELETE_PROFILE_WARN]}"
    if ! awgr_rollback_node_net_admin "$docker_compose_file" "$docker_cap_added" "$docker_service"; then
        awgr_warn "${LANG[AWGR_NET_ADMIN_REMOVE_WARN]}"
    fi

    local uninstall_awg="n"
    if [ "$installed_by_module" = "true" ]; then
        echo -e "${COLOR_YELLOW}${LANG[AWGR_UNINSTALL_PROMPT]}${COLOR_RESET}"
        read -r uninstall_awg
    fi

    rm -f "$AWGR_STATE_FILE"
    rmdir "$AWGR_DIR" 2>/dev/null || true

    if [[ "$uninstall_awg" = "y" || "$uninstall_awg" = "Y" ]]; then
        bash "$AWGR_INSTALLER" --uninstall --yes || awgr_warn "${LANG[AWGR_UNINSTALL_WARN]}"
        awgr_remove_ufw_rule "$awg_port" "$ufw_rule_added"
        awgr_restore_host_sysctl "$state" true
    elif [ "$ufw_rule_added" = "true" ]; then
        awgr_warn "${LANG[AWGR_UFW_RULE_KEPT]}"
    fi

    awgr_ok "${LANG[AWGR_REMOVED]}"
}

show_amneziawg_remnawave_menu() {
    echo -e "\n${COLOR_GREEN}${LANG[AWGR_MENU_TITLE]}${COLOR_RESET}"
    echo -e "${COLOR_YELLOW}1. ${LANG[AWGR_MENU_CREATE]}${COLOR_RESET}"
    echo -e "${COLOR_YELLOW}2. ${LANG[AWGR_MENU_STATUS]}${COLOR_RESET}"
    echo -e "${COLOR_YELLOW}3. ${LANG[AWGR_MENU_DISABLE]}${COLOR_RESET}"
    echo -e "${COLOR_YELLOW}4. ${LANG[AWGR_MENU_ENABLE]}${COLOR_RESET}"
    echo -e "${COLOR_YELLOW}5. ${LANG[AWGR_MENU_REMOVE]}${COLOR_RESET}"
    echo -e "${COLOR_YELLOW}0. ${LANG[EXIT]}${COLOR_RESET}"
    echo -e ""
}

manage_amneziawg_remnawave() {
    show_amneziawg_remnawave_menu
    local option
    reading "${LANG[AWGR_PROMPT_ACTION]}" option
    case "$option" in
        1) create_amneziawg_remnawave_integration ;;
        2) amneziawg_remnawave_status ;;
        3) disable_amneziawg_remnawave ;;
        4) enable_amneziawg_remnawave ;;
        5) remove_amneziawg_remnawave ;;
        0) return 0 ;;
        *) awgr_error "${LANG[AWGR_INVALID_CHOICE]}"; return 1 ;;
    esac
}
