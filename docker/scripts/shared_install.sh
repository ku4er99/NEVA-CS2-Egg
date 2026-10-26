#!/usr/bin/env bash

# /tmp/cs2_ds is the SMS-managed mount contract. Other sync roots opt in by
# carrying either maintenance marker. A damaged managed mount must not silently
# fall back to a per-slot app_update against symlinked shared VPKs.
prepare_shared_install() {
    NEVA_MANAGED_SHARED=0
    local source_dir="${SYNC_LOCATION:-}"
    source_dir="${source_dir%/}"
    [[ -n "$source_dir" ]] || return 0
    if [[ "$source_dir" != /tmp/cs2_ds && ! -e "$source_dir/.neva-provisioned" &&
          ! -L "$source_dir/.neva-provisioned" && ! -e "$source_dir/.neva-maintenance" &&
          ! -L "$source_dir/.neva-maintenance" ]]; then
        return 0
    fi
    NEVA_MANAGED_SHARED=1
    local guard_dir="$source_dir/.neva-maintenance"
    if [[ ! -d "$source_dir" || ! -f "$guard_dir/cs2.lock" ]] ||
       ! command -v flock >/dev/null 2>&1; then
        log_message "Managed shared CS2 guard is missing; start rejected" "error"
        return 75
    fi
    # FD 8 belongs to this entrypoint and is inherited by the game. The existing
    # host start-guard uses FD 9, so it cannot replace or release our early lock.
    if ! exec 8< "$guard_dir/cs2.lock"; then
        log_message "Managed shared CS2 lock is unreadable; start rejected" "error"
        return 75
    fi
    if ! flock --shared --nonblock 8; then
        exec 8<&-
        log_message "Managed shared CS2 is under maintenance; start rejected" "error"
        return 75
    fi
    # Check everything under the lock, including the persistent recovery marker.
    local build
    if [[ -e "$guard_dir/blocked" || -L "$guard_dir/blocked" ||
          ! -f "$source_dir/.neva-provisioned" || ! -s "$source_dir/.neva-provisioned" ||
          ! -f "$guard_dir/start-guard.sh" || ! -r "$guard_dir/start-guard.sh" ||
          ! -f "$source_dir/.steam/sdk64/steamclient.so" || ! -s "$source_dir/.steam/sdk64/steamclient.so" ||
          ! -f "$source_dir/.steam/sdk32/steamclient.so" || ! -s "$source_dir/.steam/sdk32/steamclient.so" ]]; then
        exec 8<&-
        log_message "Managed shared CS2 is incomplete or blocked; start rejected" "error"
        return 75
    fi
    if [[ "${SRCDS_APPID:-730}" != 730 || -n "${SRCDS_BETAID:-}" ]] ||
       ! build=$(verified_cs2_build "$source_dir"); then
        exec 8<&-
        log_message "Managed shared CS2 manifest or requested branch is invalid; start rejected" "error"
        return 75
    fi
    log_message "Using verified managed shared CS2 build ${build}; per-slot SteamCMD skipped" "info"
}

prepare_game_files() {
    prepare_shared_install || return $?
    if [[ "$NEVA_MANAGED_SHARED" == 1 ]]; then
        # STOP_UPDATE disables legacy sync too. Managed slots always need the
        # matching binaries, VPK links and first-use configs from the locked tree.
        sync_files || return $?
        sync_cfg_files || return $?
        clean_old_logs || return $?
    elif [[ "${SRCDS_STOP_UPDATE:-0}" == 0 ]]; then
        sync_files || return $?
        sync_cfg_files || return $?
        install_steamcmd || return $?
        clean_old_logs || return $?
        update_game_files || return $?
    else
        log_message "Updates disabled, skipping VPK sync and SteamCMD" "warning"
    fi
}
