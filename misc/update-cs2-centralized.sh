#!/bin/bash
# KitsuneLab CS2 Centralized Update Script (PELican Edition)
# Updates shared CS2 directory and (optionally) restarts Pelican servers.
#
# Key safety feature (NEW):
#   - Can refuse to update if ANY listed server is running.
#   - Optional wait mode to wait until all servers stop.
#
# Usage:
#   ./update-cs2-centralized-pelican.sh [--simulate] [--wait-all-off]
#
# Version: 1.0.21-pelican-safe

set -euo pipefail

# ============================================================================
# CONFIGURATION - Edit these values for your setup
# ============================================================================

APP_ID="730"

# Shared CS2 directory (centralized)
CS2_DIR="/srv/cs2-shared"

# SteamCMD installation directory
STEAMCMD_DIR="/root/steamcmd"

# Pelican panel base URL
PELican_PANEL_URL="https://pelican.domain.ru"

# Pelican Client API key (pacc_...), recommended: keep empty and use file below
PELican_CLIENT_API_KEY=""

# If key is not set above, read it from this file (one line)
PELican_CLIENT_API_KEY_FILE="/pelican-data/client_api_key"

# Pelican server identifiers to manage (short ids from panel URLs), spaces or commas
PELican_SERVER_IDS="cbc9faa8,abcd1234"

# Enable automatic restart after update (true/false)
AUTO_RESTART_SERVERS="false"

# Validate game files integrity during update (true/false)
VALIDATE_INSTALL="false"

# If true: DO NOT update unless ALL servers are OFF.
# If false: update proceeds even if servers are running (NOT recommended).
REQUIRE_ALL_SERVERS_OFF="true"

# If true and REQUIRE_ALL_SERVERS_OFF=true:
#   wait (poll) until all servers are off, instead of exiting immediately.
WAIT_UNTIL_ALL_OFF="false"

# Poll interval (seconds) for wait mode
WAIT_POLL_INTERVAL="30"

# Maximum wait time (seconds) in wait mode, 0 = infinite
WAIT_MAX_SECONDS="0"

# ============================================================================
# DO NOT EDIT BELOW THIS LINE UNLESS YOU KNOW WHAT YOU'RE DOING
# ============================================================================

SIMULATE_MODE=false
ORIGINAL_ARGS=("$@")

# Styling / Colors
if [[ -t 1 ]] && [[ -z "${NO_COLOR:-}" ]]; then
    BOLD="\033[1m"; DIM="\033[2m"
    RED="\033[31m"; GREEN="\033[32m"; YELLOW="\033[33m"
    BLUE="\033[34m"; MAGENTA="\033[35m"; CYAN="\033[36m"; GRAY="\033[90m"
    RESET="\033[0m"
else
    BOLD=""; DIM=""; RED=""; GREEN=""; YELLOW=""; BLUE=""; MAGENTA=""; CYAN=""; GRAY=""; RESET=""
fi

log_info()    { echo -e "ℹ ${BOLD}${CYAN}INFO${RESET}  $*" >&2; }
log_ok()      { echo -e "✓ ${BOLD}${GREEN}DONE${RESET}  $*" >&2; }
log_warn()    { echo -e "⚠ ${BOLD}${YELLOW}WARN${RESET}  $*" >&2; }
log_error()   { echo -e "✗ ${BOLD}${RED}ERROR${RESET} $*" >&2; }
section()     { echo -e "\n${BOLD}${MAGENTA}==>${RESET} ${BOLD}$*${RESET}\n" >&2; }
headline()    {
    local title="$1"
    echo -e "${BOLD}${BLUE}──────────────────────────────────────────────────────${RESET}" >&2
    echo -e "${BOLD}${BLUE} ${title}${RESET}" >&2
    echo -e "${BOLD}${BLUE}──────────────────────────────────────────────────────${RESET}\n" >&2
}

# ============================================================================
# VALIDATION
# ============================================================================

validate_config() {
    local errors=0

    if [[ ! "$CS2_DIR" =~ ^/[a-zA-Z0-9/_-]+$ ]]; then
        log_error "Invalid CS2_DIR path: $CS2_DIR"
        ((errors++))
    fi

    if [[ ! "$STEAMCMD_DIR" =~ ^/[a-zA-Z0-9/_-]+$ ]]; then
        log_error "Invalid STEAMCMD_DIR path: $STEAMCMD_DIR"
        ((errors++))
    fi

    if [[ ! "$APP_ID" =~ ^[0-9]+$ ]]; then
        log_error "Invalid APP_ID: $APP_ID (must be numeric)"
        ((errors++))
    fi

    if [ "$AUTO_RESTART_SERVERS" = "true" ] || [ "$REQUIRE_ALL_SERVERS_OFF" = "true" ]; then
        if [ -z "${PELican_SERVER_IDS// /}" ]; then
            log_error "PELican_SERVER_IDS must be set (comma/space separated server IDs)"
            ((errors++))
        fi
        if [ -z "${PELican_PANEL_URL// /}" ]; then
            log_error "PELican_PANEL_URL must be set"
            ((errors++))
        fi
        if ! command -v curl >/dev/null 2>&1; then
            log_error "curl is required but not installed"
            ((errors++))
        fi
    fi

    if [ $errors -gt 0 ]; then
        log_error "Configuration validation failed with $errors error(s)"
        exit 1
    fi

    log_ok "Configuration validated successfully"
}

# ============================================================================
# LOCKING
# ============================================================================

acquire_lock() {
    local lockfile="/var/lock/cs2-update.lock"
    mkdir -p "$(dirname "$lockfile")" 2>/dev/null || true

    exec 200>"$lockfile"
    if ! flock -n 200; then
        log_error "Another CS2 update instance is already running"
        exit 1
    fi
    log_ok "Acquired update lock"
}

release_lock() {
    local lockfile="/var/lock/cs2-update.lock"
    flock -u 200 2>/dev/null || true
    rm -f "$lockfile" 2>/dev/null || true
}

# ============================================================================
# STEAMCMD helpers (kept from original)
# ============================================================================

run_with_spinner() {
    local label="$1"; shift
    local cmd=("$@")
    local spin=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')
    local i=0
    local start_ts=$(date +%s)
    local log_file="/tmp/cs2-update.$$.$RANDOM.log"

    "${cmd[@]}" >"$log_file" 2>&1 &
    local pid=$!

    printf "${BOLD}${MAGENTA}%s${RESET}\n" "$label" >&2
    while kill -0 $pid 2>/dev/null; do
        printf "\r${CYAN}%s${RESET} ${DIM}%s${RESET}" "${spin[$i]}" "$label" >&2
        i=$(((i+1)%${#spin[@]}))
        sleep 0.12
    done

    wait $pid
    local ec=$?
    local end_ts=$(date +%s)
    local dur=$((end_ts-start_ts))

    printf "\r" >&2

    if [ $ec -eq 0 ]; then
        log_ok "${label} finished in ${dur}s"
    else
        log_error "${label} failed after ${dur}s (exit $ec)"
        echo "${BOLD}Last 20 lines:${RESET}" >&2
        tail -n 20 "$log_file" >&2 || true
        rm -f "$log_file"
        return $ec
    fi

    rm -f "$log_file"
    return 0
}

ensure_steamcmd_dependencies() {
    if ! dpkg --print-foreign-architectures 2>/dev/null | grep -q "i386"; then
        log_info "Adding i386 architecture..."
        dpkg --add-architecture i386
        apt-get update -qq
    fi

    if ! dpkg -l lib32gcc-s1 2>/dev/null | grep -q "^ii" && \
       ! dpkg -l lib32gcc1 2>/dev/null | grep -q "^ii"; then

        if run_with_spinner "Installing 32-bit libraries (modern)" \
            env DEBIAN_FRONTEND=noninteractive apt-get install -y -q lib32gcc-s1 lib32stdc++6; then
            :
        elif run_with_spinner "Installing 32-bit libraries (legacy)" \
            env DEBIAN_FRONTEND=noninteractive apt-get install -y -q lib32gcc1 lib32stdc++6; then
            :
        else
            log_error "Failed to install 32-bit libraries"
            exit 1
        fi
    fi
}

install_or_reinstall_steamcmd() {
    section "SteamCMD Setup"

    local needs_deps=false
    local needs_install=false

    if ! dpkg --print-foreign-architectures 2>/dev/null | grep -q "i386"; then
        needs_deps=true
    fi

    if ! dpkg -l lib32gcc-s1 2>/dev/null | grep -q "^ii" && \
       ! dpkg -l lib32gcc1 2>/dev/null | grep -q "^ii"; then
        needs_deps=true
    fi

    if [ ! -f "$STEAMCMD_DIR/steamcmd.sh" ] || [ ! -x "$STEAMCMD_DIR/steamcmd.sh" ]; then
        needs_install=true
    elif [ ! -f "$STEAMCMD_DIR/linux32/steamclient.so" ] && [ ! -f "$STEAMCMD_DIR/linux64/steamclient.so" ]; then
        needs_install=true
    fi

    if [ "$needs_deps" = false ] && [ "$needs_install" = false ]; then
        log_ok "SteamCMD health check passed"
        return 0
    fi

    if [ "$needs_deps" = true ]; then
        ensure_steamcmd_dependencies || exit 1
    fi

    if [ "$needs_install" = true ]; then
        log_info "Installing SteamCMD..."
        rm -rf "$STEAMCMD_DIR"
        mkdir -p "$STEAMCMD_DIR"
        curl -sqL 'https://steamcdn-a.akamaihd.net/client/installer/steamcmd_linux.tar.gz' | tar -xz -C "$STEAMCMD_DIR"
        chmod +x "$STEAMCMD_DIR/steamcmd.sh"
        log_ok "SteamCMD installed at $STEAMCMD_DIR"
    fi
}

get_local_version() {
    local manifest="$CS2_DIR/steamapps/appmanifest_$APP_ID.acf"
    if [ -f "$manifest" ]; then
        grep -Po '^\s*"buildid"\s*"\K[^"]+' "$manifest" 2>/dev/null || echo "unknown"
    else
        echo "unknown"
    fi
}

update_cs2() {
    section "CS2 Update"

    local version_before=$(get_local_version)
    mkdir -p "$CS2_DIR"

    local validate_flag=""
    if [ "$VALIDATE_INSTALL" = "true" ]; then
        validate_flag="validate"
    fi

    "$STEAMCMD_DIR/steamcmd.sh" +force_install_dir "$CS2_DIR" +login anonymous +app_update "$APP_ID" $validate_flag +quit

    local version_after=$(get_local_version)

    if [ "$version_before" = "$version_after" ]; then
        log_ok "CS2 is already up to date (version: $version_after)"
    else
        if [ "$version_before" = "unknown" ]; then
            log_ok "CS2 installed successfully (version: ${BOLD}$version_after${RESET})"
        else
            log_ok "CS2 updated successfully: $version_before → ${BOLD}$version_after${RESET}"
        fi
    fi

    mkdir -p "$CS2_DIR/.steam/sdk32" "$CS2_DIR/.steam/sdk64"
    cp -f "$STEAMCMD_DIR/linux32/steamclient.so" "$CS2_DIR/.steam/sdk32/" 2>/dev/null || true
    cp -f "$STEAMCMD_DIR/linux64/steamclient.so" "$CS2_DIR/.steam/sdk64/" 2>/dev/null || true

    chmod -R 755 "$CS2_DIR"

    local size=$(du -sh "$CS2_DIR" 2>/dev/null | cut -f1)
    log_info "CS2 directory size: ${BOLD}$size${RESET}"

    [ "$version_before" != "$version_after" ]
}

# ============================================================================
# Pelican helpers (NEW)
# ============================================================================

get_pelican_client_key() {
    if [ -n "${PELican_CLIENT_API_KEY:-}" ]; then
        echo "$PELican_CLIENT_API_KEY"
        return 0
    fi

    if [ -f "$PELican_CLIENT_API_KEY_FILE" ]; then
        local key
        key=$(cat "$PELican_CLIENT_API_KEY_FILE" 2>/dev/null | tr -d '\r\n' || true)
        if [ -n "$key" ]; then
            echo "$key"
            return 0
        fi
    fi

    return 1
}

pelican_resources_state() {
    local server_id="$1"
    local token="$2"
    local url="${PELican_PANEL_URL%/}/api/client/servers/${server_id}/resources"

    # Expect JSON like: { "attributes": { "current_state": "running" ... } }
    local body
    body=$(curl -sS \
        -H "Authorization: Bearer ${token}" \
        -H "Accept: application/json" \
        "$url" 2>/dev/null || true)

    if [ -z "$body" ]; then
        echo "unknown"
        return 0
    fi

    # Very simple JSON extraction without jq:
    # find "current_state":"...".
    local state
    state=$(echo "$body" | sed -n 's/.*"current_state"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n1)

    if [ -z "$state" ]; then
        echo "unknown"
    else
        echo "$state"
    fi
}

pelican_restart_server() {
    local server_id="$1"
    local token="$2"
    local url="${PELican_PANEL_URL%/}/api/client/servers/${server_id}/power"

    local response http_code
    response=$(curl -sS -w "\n%{http_code}" \
        -X POST "$url" \
        -H "Authorization: Bearer ${token}" \
        -H "Accept: application/json" \
        -H "Content-Type: application/json" \
        --data '{"signal":"restart"}' \
        2>/dev/null || echo "error\n000")

    http_code=$(echo "$response" | tail -n1)
    if [ "$http_code" = "204" ] || [ "$http_code" = "202" ] || [ "$http_code" = "200" ]; then
        return 0
    fi

    local body
    body=$(echo "$response" | sed '$d' | head -n 1)
    log_warn "Pelican restart failed for ${server_id} (HTTP $http_code): ${body:0:180}"
    return 1
}

parse_server_ids() {
    local ids="${PELican_SERVER_IDS//,/ }"
    local -a arr=()
    for id in $ids; do
        [ -n "$id" ] && arr+=("$id")
    done
    printf "%s\n" "${arr[@]}"
}

ensure_all_servers_off_or_wait() {
    [ "$REQUIRE_ALL_SERVERS_OFF" != "true" ] && return 0

    local token
    if ! token=$(get_pelican_client_key); then
        log_error "Pelican Client API key not set."
        log_error "Set PELican_CLIENT_API_KEY or put it into $PELican_CLIENT_API_KEY_FILE"
        exit 1
    fi

    local start_ts now elapsed
    start_ts=$(date +%s)

    while true; do
        local running=0
        local total=0

        while IFS= read -r sid; do
            [ -z "$sid" ] && continue
            ((total++)) || true

            local st
            st=$(pelican_resources_state "$sid" "$token")
            if [ "$st" = "running" ] || [ "$st" = "starting" ]; then
                ((running++)) || true
            fi
        done < <(parse_server_ids)

        if [ $total -eq 0 ]; then
            log_warn "No server IDs configured; skipping 'all off' check."
            return 0
        fi

        if [ $running -eq 0 ]; then
            log_ok "All Pelican servers are OFF (safe to update)"
            return 0
        fi

        log_warn "Detected ${BOLD}$running${RESET}/${BOLD}$total${RESET} server(s) RUNNING. Shared-dir update is not safe."

        if [ "$WAIT_UNTIL_ALL_OFF" != "true" ]; then
            log_error "Exiting because REQUIRE_ALL_SERVERS_OFF=true. Stop servers first or enable WAIT_UNTIL_ALL_OFF."
            exit 3
        fi

        # wait mode
        sleep "$WAIT_POLL_INTERVAL"

        if [ "$WAIT_MAX_SECONDS" != "0" ]; then
            now=$(date +%s)
            elapsed=$((now - start_ts))
            if [ $elapsed -ge $WAIT_MAX_SECONDS ]; then
                log_error "Timed out waiting for servers to stop (${WAIT_MAX_SECONDS}s)."
                exit 4
            fi
        fi
    done
}

restart_pelican_servers() {
    section "Restarting Pelican Servers"

    local token
    if ! token=$(get_pelican_client_key); then
        log_error "Pelican Client API key not set."
        exit 1
    fi

    local -a server_array=()
    while IFS= read -r sid; do
        [ -n "$sid" ] && server_array+=("$sid")
    done < <(parse_server_ids)

    if [ ${#server_array[@]} -eq 0 ]; then
        log_info "No Pelican server IDs configured in PELican_SERVER_IDS"
        return 0
    fi

    local count=${#server_array[@]}
    log_info "Restarting ${BOLD}$count${RESET} server(s) via Pelican panel: ${BOLD}${PELican_PANEL_URL}${RESET}"

    local success=0
    local failed=0

    for sid in "${server_array[@]}"; do
        if pelican_restart_server "$sid" "$token"; then
            log_ok "Restarted ${BOLD}$sid${RESET}"
            ((success++)) || true
        else
            ((failed++)) || true
        fi
    done

    if [ $failed -gt 0 ]; then
        log_warn "Restarted $success/$count successfully ($failed failed)"
        return 1
    fi

    log_ok "All servers restarted successfully (${BOLD}$success/$count${RESET})"
    return 0
}

# ============================================================================
# MAIN
# ============================================================================

main() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --simulate)
                SIMULATE_MODE=true
                shift
                ;;
            --wait-all-off)
                WAIT_UNTIL_ALL_OFF="true"
                shift
                ;;
            *)
                log_error "Unknown argument: $1"
                echo ""
                echo "Usage: $0 [--simulate] [--wait-all-off]"
                echo ""
                exit 1
                ;;
        esac
    done

    headline "KitsuneLab CS2 Centralized Update (Pelican Safe)"

    if [ "$SIMULATE_MODE" = "true" ]; then
        log_warn "Running in SIMULATE mode - SteamCMD update will be skipped"
    fi

    section "Pre-flight Checks"
    validate_config
    acquire_lock
    trap release_lock EXIT
    trap 'release_lock; exit 130' SIGINT
    trap 'release_lock; exit 143' SIGTERM

    log_ok "Dependencies satisfied"
    log_info "CS2 Directory: ${BOLD}$CS2_DIR${RESET}"
    log_info "SteamCMD Directory: ${BOLD}$STEAMCMD_DIR${RESET}"
    log_info "Panel URL: ${BOLD}$PELican_PANEL_URL${RESET}"
    log_info "Require all servers off: ${BOLD}$REQUIRE_ALL_SERVERS_OFF${RESET}"
    log_info "Wait until all off: ${BOLD}$WAIT_UNTIL_ALL_OFF${RESET}"

    install_or_reinstall_steamcmd || exit 1

    # SAFETY CHECK (NEW)
    ensure_all_servers_off_or_wait

    local update_occurred=false

    if [ "$SIMULATE_MODE" = "true" ]; then
        section "Simulating CS2 Update"
        log_info "Skipping SteamCMD update (simulate mode)"
        log_ok "Simulated update complete"
        update_occurred=true
    else
        if update_cs2; then
            update_occurred=true
        fi
    fi

    if [ "$update_occurred" = "true" ]; then
        if [ "$AUTO_RESTART_SERVERS" = "true" ]; then
            restart_pelican_servers || true
        else
            log_info "Auto-restart disabled, servers will sync on next restart"
        fi
    else
        log_info "No update available, servers already running latest version"
    fi

    section "Summary"
    log_ok "Completed"
    log_info "Version: ${BOLD}$(get_local_version)${RESET}"
    log_info "Location: ${BOLD}$CS2_DIR${RESET}"
    echo ""
}

main "$@"
