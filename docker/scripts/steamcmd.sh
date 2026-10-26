#!/usr/bin/env bash

# A marker alone (or SteamCMD exit 0 alone) does not prove a complete installation.
verified_cs2_build() {
    local root="$1" app_id state build
    local manifest="$root/steamapps/appmanifest_730.acf"
    if [[ ! -f "$manifest" || ! -s "$manifest" ||
          ! -f "$root/game/bin/linuxsteamrt64/cs2" || ! -s "$root/game/bin/linuxsteamrt64/cs2" ||
          ! -x "$root/game/bin/linuxsteamrt64/cs2" ||
          ! -f "$root/game/csgo/pak01_dir.vpk" || ! -s "$root/game/csgo/pak01_dir.vpk" ]]; then
        return 1
    fi
    app_id=$(awk -F '"' '$2 == "appid" { print $4 }' "$manifest") || return 1
    state=$(awk -F '"' '$2 == "StateFlags" { print $4 }' "$manifest") || return 1
    build=$(awk -F '"' '$2 == "buildid" { print $4 }' "$manifest") || return 1
    [[ "$app_id" == 730 && "$state" == 4 && "$build" =~ ^[1-9][0-9]*$ ]] || return 1
    printf '%s\n' "$build"
}

# Called in an explicit conditional: nap.sh enables errexit in the entrypoint.
# Never echo argv or raw SteamCMD output: both can contain login/beta credentials.
steamcmd_run_bounded() {
    local phase="$1"
    shift
    local attempts="${STEAMCMD_UPDATE_ATTEMPTS:-3}"
    local attempt_timeout="${STEAMCMD_UPDATE_TIMEOUT:-600}"
    local deadline="${STEAMCMD_UPDATE_DEADLINE:-1800}"
    local backoff="${STEAMCMD_UPDATE_BACKOFF:-5}"
    local value
    for value in "$attempts" "$attempt_timeout" "$deadline" "$backoff"; do
        if [[ ! "$value" =~ ^(0|[1-9][0-9]{0,3})$ ]]; then
            log_message "Invalid SteamCMD retry configuration" "error"
            return 64
        fi
    done
    if (( attempts < 1 || attempts > 10 || attempt_timeout < 1 || attempt_timeout > 3600 ||
          deadline < 2 || deadline > 7200 || backoff > 300 )); then
        log_message "SteamCMD retry configuration is out of range" "error"
        return 64
    fi
    if ! command -v timeout >/dev/null 2>&1; then
        log_message "SteamCMD requires the timeout utility" "error"
        return 69
    fi

    local started=$SECONDS attempt remaining window delay status=1
    for (( attempt=1; attempt<=attempts; attempt++ )); do
        remaining=$((deadline - (SECONDS - started)))
        # Reserve one second for timeout's final SIGKILL of a stuck process group.
        if (( remaining <= 1 )); then
            log_message "SteamCMD ${phase} deadline reached; start rejected" "error"
            return 124
        fi
        window=$attempt_timeout
        (( window < remaining )) || window=$((remaining - 1))
        log_message "SteamCMD ${phase}: attempt ${attempt}/${attempts}, timeout ${window}s" "info"
        # Redirect the group too: Bash can print a command diagnostic after SIGKILL.
        if { timeout --signal=TERM --kill-after=1s "${window}s" ./steamcmd/steamcmd.sh "$@"; } >/dev/null 2>&1; then
            log_message "SteamCMD ${phase} completed" "success"
            return 0
        else
            status=$?
        fi
        log_message "SteamCMD ${phase} attempt ${attempt} failed (exit=${status})" "warning"
        (( attempt < attempts )) || break
        remaining=$((deadline - (SECONDS - started)))
        delay=$((backoff * (1 << (attempt - 1))))
        (( delay <= 300 )) || delay=300
        if (( remaining <= delay + 1 )); then
            log_message "SteamCMD ${phase} deadline reached; start rejected" "error"
            return 124
        fi
        if (( delay > 0 )); then
            log_message "Retrying SteamCMD ${phase} in ${delay}s" "warning"
            sleep "$delay" || return $?
        fi
    done
    log_message "SteamCMD ${phase} failed; start rejected (no fallback after update)" "error"
    return "$status"
}

update_game_files() {
    [[ -n "${SRCDS_APPID:-}" ]] || return 0
    local -a arguments=(+force_install_dir /home/container +login)
    if [[ -n "${SRCDS_LOGIN:-}" ]]; then
        arguments+=("$SRCDS_LOGIN" "${SRCDS_LOGIN_PASS:-}")
    else
        arguments+=(anonymous)
    fi
    arguments+=(+app_update "$SRCDS_APPID")
    if [[ -n "${SRCDS_BETAID:-}" ]]; then
        arguments+=(-beta "$SRCDS_BETAID")
        if [[ -n "${SRCDS_BETAPASS:-}" ]]; then
            arguments+=(-betapassword "$SRCDS_BETAPASS")
        fi
    fi
    if [[ "${SRCDS_VALIDATE:-0}" == 1 ]]; then
        log_message "Validation enabled: this may replace custom configurations" "warning"
        arguments+=(validate)
    fi
    arguments+=(+quit)
    steamcmd_run_bounded update "${arguments[@]}" || return $?
    if [[ "$SRCDS_APPID" == 730 ]] && ! verified_cs2_build . >/dev/null; then
        log_message "SteamCMD returned success but CS2 installation is incomplete; start rejected" "error"
        return 1
    fi
    mkdir -p ./.steam/sdk32 ./.steam/sdk64 || return $?
    cp -f ./steamcmd/linux32/steamclient.so ./.steam/sdk32/steamclient.so || return $?
    cp -f ./steamcmd/linux64/steamclient.so ./.steam/sdk64/steamclient.so || return $?
}
