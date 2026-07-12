#!/usr/bin/env bash
# MultiAddonManager updater/installer (Metamod plugin)

source /utils/logging.sh
source /utils/updater_common.sh

MAM_REPO="Source2ZE/MultiAddonManager"
MAM_VERSION_KEY="MultiAddonManager"

update_multiaddonmanager() {
    local output_dir="./game/csgo"
    local release_info new_version asset_url asset_name current_version
    local work_dir archive extracted content_root backup_dir

    release_info="$(get_github_release "$MAM_REPO" "(?i).*linux.*(\\.zip|\\.tar\\.gz)$")"
    if [ -z "$release_info" ] || ! echo "$release_info" | jq -e . >/dev/null 2>&1; then
        log_message "Failed to fetch MultiAddonManager release information" "error"
        return 1
    fi

    new_version="$(echo "$release_info" | jq -r '.version // empty')"
    asset_url="$(echo "$release_info" | jq -r '.asset_url // empty')"
    asset_name="$(echo "$release_info" | jq -r '.asset_name // empty')"
    if [ -z "$new_version" ] || [ -z "$asset_url" ] || [ -z "$asset_name" ]; then
        log_message "Latest MultiAddonManager release has no Linux archive" "error"
        return 1
    fi

    current_version="$(get_current_version "$MAM_VERSION_KEY")"
    if [ "$current_version" = "$new_version" ] && [ -d "$output_dir/addons/multiaddonmanager" ]; then
        log_message "MultiAddonManager is up-to-date ($current_version)" "info"
        return 0
    fi

    mkdir -p "$TEMP_DIR"
    work_dir="$(mktemp -d "${TEMP_DIR}/multiaddonmanager.XXXXXX")" || return 1
    archive="$work_dir/$asset_name"
    extracted="$work_dir/extracted"
    backup_dir="$work_dir/backup"

    case "$asset_name" in
        *.zip) local archive_type="zip" ;;
        *.tar.gz|*.tgz) local archive_type="tar.gz" ;;
        *)
            log_message "Unsupported MultiAddonManager archive: $asset_name" "error"
            rm -rf "$work_dir"
            return 1
            ;;
    esac

    if ! handle_download_and_extract "$asset_url" "$archive" "$extracted" "$archive_type"; then
        rm -rf "$work_dir"
        return 1
    fi

    if find "$extracted" -type l -print -quit | grep -q .; then
        log_message "MultiAddonManager archive contains symbolic links; refusing to install" "error"
        rm -rf "$work_dir"
        return 1
    fi

    content_root="$extracted"
    if [ -d "$extracted/game/csgo" ]; then
        content_root="$extracted/game/csgo"
    elif [ -d "$extracted/csgo" ]; then
        content_root="$extracted/csgo"
    fi

    if [ ! -d "$content_root/addons/multiaddonmanager" ] || \
       [ ! -f "$content_root/addons/metamod/multiaddonmanager.vdf" ]; then
        log_message "MultiAddonManager archive has an unexpected layout" "error"
        rm -rf "$work_dir"
        return 1
    fi

    mkdir -p "$backup_dir/addons/metamod"
    [ ! -d "$output_dir/addons/multiaddonmanager" ] || cp -a "$output_dir/addons/multiaddonmanager" "$backup_dir/addons/"
    [ ! -f "$output_dir/addons/metamod/multiaddonmanager.vdf" ] || \
        cp -a "$output_dir/addons/metamod/multiaddonmanager.vdf" "$backup_dir/addons/metamod/"

    mkdir -p "$output_dir/addons/metamod"
    rm -rf "$output_dir/addons/multiaddonmanager"
    if ! cp -a "$content_root/addons/multiaddonmanager" "$output_dir/addons/" || \
       ! cp -a "$content_root/addons/metamod/multiaddonmanager.vdf" "$output_dir/addons/metamod/"; then
        log_message "MultiAddonManager install failed; restoring previous installation" "error"
        rm -rf "$output_dir/addons/multiaddonmanager"
        rm -f "$output_dir/addons/metamod/multiaddonmanager.vdf"
        [ ! -d "$backup_dir/addons/multiaddonmanager" ] || cp -a "$backup_dir/addons/multiaddonmanager" "$output_dir/addons/"
        [ ! -f "$backup_dir/addons/metamod/multiaddonmanager.vdf" ] || \
            cp -a "$backup_dir/addons/metamod/multiaddonmanager.vdf" "$output_dir/addons/metamod/"
        rm -rf "$work_dir"
        return 1
    fi

    update_version_file "$MAM_VERSION_KEY" "$new_version"
    rm -rf "$work_dir"
    log_message "MultiAddonManager updated to $new_version" "success"
}

mam_cfg_escape() {
    printf '%s' "$1" | tr '\r\n' '  ' | sed 's/\\/\\\\/g; s/"/\\"/g'
}

configure_multiaddonmanager() {
    local cfg_dir="./game/csgo/cfg/multiaddonmanager"
    local cfg_file="$cfg_dir/multiaddonmanager.cfg"
    local cfg_tmp="$cfg_file.tmp"

    mkdir -p "$cfg_dir"
    {
        printf 'mm_extra_addons "%s"\n' "$(mam_cfg_escape "${MAM_EXTRA_ADDONS:-3763253081}")"
        printf 'mm_client_extra_addons "%s"\n' "$(mam_cfg_escape "${MAM_CLIENT_EXTRA_ADDONS:-}")"
        printf 'mm_extra_addons_timeout "%s"\n' "$(mam_cfg_escape "${MAM_EXTRA_ADDONS_TIMEOUT:-10}")"
        printf 'mm_addon_connection_timeout "%s"\n' "$(mam_cfg_escape "${MAM_ADDON_CONNECTION_TIMEOUT:-30}")"
        printf 'mm_addon_mount_download "%s"\n' "$(mam_cfg_escape "${MAM_MOUNT_DOWNLOAD:-1}")"
        printf 'mm_cache_clients_with_addons "1"\n'
        printf 'mm_cache_clients_duration "0"\n'
        printf 'mm_block_disconnect_messages "1"\n'
    } > "$cfg_tmp" && mv "$cfg_tmp" "$cfg_file"
}
