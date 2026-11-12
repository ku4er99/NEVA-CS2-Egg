#!/bin/bash
# Common utility functions for all updater scripts

# Configuration
VERSION_FILE="${EGG_DIR:-/home/container/egg}/versions.txt"
TEMP_DIR="./temps"

# Read a release document. Exit 2 denotes invalid configuration, not an outage.
get_github_release_document() {
    local repo="$1"
    local pinned_tag="${2:-}"
    local token="${3:-}"
    local tag_prefix="${4:-}"
    local required_asset="${5:-}"
    local url="https://api.github.com/repos/$repo/releases"
    local response status response_headers http_status reset
    local -a headers=()

    if [ "${RELEASE_FREEZE:-0}" = "1" ] && [ -z "$pinned_tag" ]; then
        log_message "RELEASE_FREEZE=1 requires a pinned release tag for $repo" "error" >&2
        return 2
    fi
    if [ -n "$pinned_tag" ] && [ "$pinned_tag" != "latest" ]; then
        url="$url/tags/$(printf '%s' "$pinned_tag" | jq -sRr @uri)"
        log_message "Using pinned release $pinned_tag for $repo" "debug" >&2
    elif [ -n "$tag_prefix" ] || { [ "$pinned_tag" != "latest" ] && [ "${PRERELEASE:-0}" = "1" ]; }; then
        log_message "Checking releases (prereleases enabled) for $repo" "debug" >&2
    else
        url="$url/latest"
        log_message "Checking latest stable release for $repo" "debug" >&2
    fi

    [ -z "$token" ] || headers=(-H "Authorization: Bearer ${token}")
    response_headers="$(mktemp)" || return 1
    # Never print credentials, response bodies or curl's command line on failure.
    if response="$(curl -4 -fsSL --connect-timeout 5 --max-time 15 -D "$response_headers" \
        "${headers[@]}" -H 'Accept: application/vnd.github+json' "$url" 2>/dev/null)"; then
        :
    else
        status=$?
        http_status="$(awk '/^HTTP\// {status=$2} END {print status}' "$response_headers")"
        reset="$(awk 'tolower($1) == "x-ratelimit-reset:" {gsub(/\r/, "", $2); print $2}' "$response_headers")"
        rm -f "$response_headers"
        log_message "GitHub release API failed for $repo (HTTP ${http_status:-unavailable}, curl exit $status, rate-limit reset ${reset:-unknown})" "warning" >&2
        return 1
    fi
    rm -f "$response_headers"
    if ! printf '%s' "$response" | jq -ce --arg prefix "$tag_prefix" --arg asset "$required_asset" '
        def usable: select(.tag_name? | type == "string") |
            select(.tag_name | startswith($prefix)) |
            select($asset == "" or any(.assets[]?; .name? | strings | test($asset)));
        (if type == "array" then map(usable) | .[0] else . end) |
        select(type == "object") |
        select((.tag_name | type == "string" and length > 0) and (.assets | type == "array")) |
        usable
    ' 2>/dev/null; then
        log_message "GitHub release API returned invalid metadata for $repo" "warning" >&2
        return 1
    fi
}

# Outputs JSON: {version, asset_url, asset_name, is_prerelease}.
get_github_release() {
    local repo="$1" asset_pattern="${2:-.*}" pinned_tag="${3:-}"
    local document status
    if document="$(get_github_release_document "$repo" "$pinned_tag")"; then
        :
    else
        status=$?
        return "$status"
    fi
    if ! printf '%s' "$document" | jq -ce --arg p "$asset_pattern" '
        {
            version: .tag_name,
            is_prerelease: .prerelease,
            asset_url: (first(.assets[] | select(.name | test($p)) | .browser_download_url) // ""),
            asset_name: (first(.assets[] | select(.name | test($p)) | .name) // "")
        } | select(.asset_url != "" and .asset_name != "")
    ' 2>/dev/null; then
        log_message "GitHub release has no usable asset for $repo" "warning" >&2
        return 1
    fi
}

has_nonempty_file() {
    local path
    for path in "$@"; do
        if [ -f "$path" ] && [ -s "$path" ]; then return 0; fi
    done
    return 1
}

nonempty_files() {
    local path
    for path in "$@"; do
        [ -f "$path" ] && [ -s "$path" ] || return 1
    done
}

dotnet_runtime_files_present() {
    local root="$1"
    has_nonempty_file "$root"/host/fxr/*/libhostfxr.so &&
    has_nonempty_file "$root"/shared/Microsoft.NETCore.App/*/libcoreclr.so &&
    has_nonempty_file "$root"/shared/Microsoft.NETCore.App/*/libhostpolicy.so
}

# A version marker alone (or an empty installation directory) is not runnable.
addon_files_present() {
    local addon="$1" root="${2:-./game/csgo/addons}"
    case "$addon" in
        Metamod)
            nonempty_files "$root/metamod/bin/linuxsteamrt64/libserver.so" \
                "$root/metamod/bin/linuxsteamrt64/metamod.2.cs2.so" ;;
        CSS)
            nonempty_files "$root/counterstrikesharp/bin/linuxsteamrt64/counterstrikesharp.so" \
                "$root/counterstrikesharp/api/CounterStrikeSharp.API.dll" \
                "$root/counterstrikesharp/api/CounterStrikeSharp.API.runtimeconfig.json" \
                "$root/metamod/counterstrikesharp.vdf" &&
            dotnet_runtime_files_present "$root/counterstrikesharp/dotnet" ;;
        MultiAddonManager)
            has_nonempty_file "$root/multiaddonmanager/bin/multiaddonmanager.so" \
                "$root/multiaddonmanager/bin/linuxsteamrt64/multiaddonmanager.so" &&
            nonempty_files "$root/metamod/multiaddonmanager.vdf" ;;
        NevaAdminPlugin)
            nonempty_files "$root/counterstrikesharp/plugins/NEVA.CS2.NevaAdminPlugin/NEVA.CS2.NevaAdminPlugin.dll" \
                "$root/counterstrikesharp/plugins/NEVA.CS2.NevaAdminPlugin/NEVA.CS2.NevaAdminPlugin.deps.json" ;;
        Swiftly)
            nonempty_files "$root/swiftlys2/bin/linuxsteamrt64/libserver.so" \
                "$root/swiftlys2/bin/linuxsteamrt64/swiftlys2.so" \
                "$root/swiftlys2/bin/linuxsteamrt64/libhostfxr.so" \
                "$root/swiftlys2/bin/managed/SwiftlyS2.Core.dll" &&
            dotnet_runtime_files_present "$root/swiftlys2/bin/managed/dotnet" ;;
        ModSharp)
            nonempty_files ./game/sharp/bin/linuxsteamrt64/libserver.so \
                ./game/sharp/bin/libmodsharp.so ./game/sharp/core/Sharp.Core.dll \
                ./game/sharp/runtime/dotnet && dotnet_runtime_files_present ./game/sharp/runtime ;;
        *) return 1 ;;
    esac
}

use_installed_addon() {
    local status="$1" addon="$2" requested="${3:-latest}" current
    [ "$status" -ne 2 ] || return 1
    current="$(get_current_version "$addon")"
    if [ -n "$current" ] && addon_files_present "$addon" "${4:-./game/csgo/addons}"; then
        log_message "GitHub unavailable for $addon (requested ${requested:-latest}); using installed $current" "warning"
        return 0
    fi
    log_message "GitHub unavailable for $addon and no complete recorded local installation is available" "error"
    return 1
}

# Get current version from version file
get_current_version() {
    local addon="$1"
    if [ ! -f "$VERSION_FILE" ]; then
        echo ""
        return 0
    fi

    local line=""
    line="$(grep -m1 "^${addon}=" "$VERSION_FILE" 2>/dev/null || true)"
    if [ -z "$line" ]; then
        echo ""
        return 0
    fi

    echo "${line#*=}"
}

# Update version file
update_version_file() {
    local addon="$1"
    local new_version="$2"

    # Create directory if it doesn't exist
    mkdir -p "$(dirname "$VERSION_FILE")"

    if [ -f "$VERSION_FILE" ] && grep -q "^${addon}=" "$VERSION_FILE" 2>/dev/null; then
        sed -i "s/^$addon=.*/$addon=$new_version/" "$VERSION_FILE"
    else
        echo "$addon=$new_version" >> "$VERSION_FILE"
    fi
}

# Centralized download and extract function
handle_download_and_extract() {
    local url="$1"
    local output_file="$2"
    local extract_dir="$3"
    local file_type="$4"  # "zip" or "tar.gz"

    log_message "Downloading from: $url" "debug"

    # Download with timeout and retry
    local max_retries=3
    local retry=0
    while [ $retry -lt $max_retries ]; do
        if curl -4 -fsSL --connect-timeout 15 -o "$output_file" "$url"; then
            break
        fi
        retry=$((retry + 1))
        log_message "Download failed (attempt $retry/$max_retries)" "warning"
        sleep 5
    done

    if [ $retry -eq $max_retries ]; then
        log_message "Failed to download after $max_retries attempts" "error"
        return 1
    fi

    if [ ! -s "$output_file" ]; then
        log_message "Downloaded file is empty" "error"
        return 1
    fi

    mkdir -p "$extract_dir"

    case $file_type in
        "zip")
            if unzip -Z1 "$output_file" | grep -Eq '(^/|(^|/)\.\.(/|$)|^[[:alpha:]]:)'; then
                log_message "Archive contains an unsafe path" "error"
                return 1
            fi
            unzip -qq -o "$output_file" -d "$extract_dir" || {
                log_message "Failed to extract zip file" "error"
                return 1
            }
            ;;
        "tar.gz")
            if tar -tzf "$output_file" | grep -Eq '(^/|(^|/)\.\.(/|$)|^[[:alpha:]]:)'; then
                log_message "Archive contains an unsafe path" "error"
                return 1
            fi
            tar -xzf "$output_file" -C "$extract_dir" || {
                log_message "Failed to extract tar.gz file" "error"
                return 1
            }
            ;;
    esac

    return 0
}

# Centralized version checking
check_version() {
    local addon="$1"
    local current="${2:-none}"
    local new="$3"

    if [ "$current" != "$new" ]; then
        log_message "Update available for $addon: $new (current: $current)" "info"
        return 0
    fi

    log_message "$addon is up-to-date ($current)" "debug"
    return 1
}

# Add addon path to gameinfo.gi if not already present
# Inserts addons between "Game_LowViolence csgo_lv" and "Game csgo" lines
# Usage: add_to_gameinfo "csgo/addons/metamod"
add_to_gameinfo() {
    local addon_path="$1"
    local GAMEINFO_FILE="/home/container/game/csgo/gameinfo.gi"

    if [ ! -f "$GAMEINFO_FILE" ]; then
        log_message "gameinfo.gi not found at $GAMEINFO_FILE" "error"
        return 1
    fi

    # Check if path already exists
    if grep -q "Game[[:blank:]]*${addon_path}" "$GAMEINFO_FILE"; then
        log_message "${addon_path} already in gameinfo.gi" "debug"
        return 0
    fi

    log_message "Adding ${addon_path} to gameinfo.gi..." "info"

    # Create backup
    cp "$GAMEINFO_FILE" "$GAMEINFO_FILE.bak" 2>/dev/null || {
        log_message "Failed to backup gameinfo.gi" "error"
        return 1
    }

    # Insert addon after "Game_LowViolence" line using sed
    # This ensures addons are grouped together after LV line, with empty line before "Game csgo"
    sed "/Game_LowViolence/a\\
            Game    ${addon_path}" "$GAMEINFO_FILE.bak" > "$GAMEINFO_FILE"

    if [ $? -ne 0 ]; then
        log_message "sed command failed, restoring backup" "error"
        mv "$GAMEINFO_FILE.bak" "$GAMEINFO_FILE"
        return 1
    fi

    # Verify it was actually added
    if grep -q "Game[[:space:]]*${addon_path}" "$GAMEINFO_FILE"; then
        log_message "Added ${addon_path} to gameinfo.gi" "info"
        rm -f "$GAMEINFO_FILE.bak"
        return 0
    else
        log_message "WARNING: ${addon_path} not found after sed insertion, restoring backup" "error"
        mv "$GAMEINFO_FILE.bak" "$GAMEINFO_FILE"
        return 1
    fi
}

# Remove addon path from gameinfo.gi if present
# Usage: remove_from_gameinfo "sharp"
remove_from_gameinfo() {
    local addon_path="$1"
    local GAMEINFO_FILE="/home/container/game/csgo/gameinfo.gi"

    if [ ! -f "$GAMEINFO_FILE" ]; then
        log_message "gameinfo.gi not found at $GAMEINFO_FILE" "debug"
        return 0
    fi

    # Check if path exists
    if ! grep -q "Game[[:blank:]]*${addon_path}" "$GAMEINFO_FILE"; then
        log_message "${addon_path} not found in gameinfo.gi" "debug"
        return 0
    fi

    log_message "Removing ${addon_path} from gameinfo.gi..." "info"

    # Create backup
    cp "$GAMEINFO_FILE" "$GAMEINFO_FILE.bak" 2>/dev/null || {
        log_message "Failed to backup gameinfo.gi" "error"
        return 1
    }

    # Remove the line containing the addon path
    sed "/Game[[:space:]]*${addon_path//\//\\/}/d" "$GAMEINFO_FILE.bak" > "$GAMEINFO_FILE"

    if [ $? -ne 0 ]; then
        log_message "sed command failed, restoring backup" "error"
        mv "$GAMEINFO_FILE.bak" "$GAMEINFO_FILE"
        return 1
    fi

    # Verify it was removed
    if ! grep -q "Game[[:space:]]*${addon_path}" "$GAMEINFO_FILE"; then
        log_message "Removed ${addon_path} from gameinfo.gi" "info"
        rm -f "$GAMEINFO_FILE.bak"
        return 0
    else
        log_message "Failed to remove ${addon_path}, restoring backup" "error"
        mv "$GAMEINFO_FILE.bak" "$GAMEINFO_FILE"
        return 1
    fi
}

# Ensure MetaMod is always first addon after Game_LowViolence line
# This is critical because MetaMod must load before others as for example SwiftlyS2 if loaded first, metamod cant load
ensure_metamod_first() {
    local GAMEINFO_FILE="/home/container/game/csgo/gameinfo.gi"

    # Check if metamod exists in file
    if ! grep -q "Game.*csgo/addons/metamod" "$GAMEINFO_FILE"; then
        return 0  # No metamod, nothing to reorder
    fi

    # Get line numbers
    local lv_line=$(grep -n "Game_LowViolence" "$GAMEINFO_FILE" | head -n1 | cut -d: -f1)
    local metamod_line=$(grep -n "Game.*csgo/addons/metamod" "$GAMEINFO_FILE" | head -n1 | cut -d: -f1)

    # Check if there are any Game lines between LV and MetaMod
    local has_addons_before=false
    local line_num=$((lv_line + 1))
    while [ $line_num -lt $metamod_line ]; do
        if sed -n "${line_num}p" "$GAMEINFO_FILE" | grep -q "^[[:space:]]*Game[[:space:]]"; then
            has_addons_before=true
            break
        fi
        ((line_num++))
    done

    # If metamod is already first (no Game lines between LV and metamod), done
    if [ "$has_addons_before" = false ]; then
        log_message "MetaMod already in correct position" "debug"
        return 0
    fi

    log_message "Repositioning MetaMod to first position after LowViolence..." "info"

    # Backup
    cp "$GAMEINFO_FILE" "$GAMEINFO_FILE.bak" 2>/dev/null || {
        log_message "Failed to backup gameinfo.gi" "error"
        return 1
    }

    # Remove metamod line wherever it is
    sed '/Game.*csgo\/addons\/metamod/d' "$GAMEINFO_FILE.bak" > "$GAMEINFO_FILE.tmp"

    # Insert metamod right after LowViolence line
    sed '/Game_LowViolence/a\            Game    csgo/addons/metamod' "$GAMEINFO_FILE.tmp" > "$GAMEINFO_FILE"

    # Cleanup temp file
    rm -f "$GAMEINFO_FILE.tmp"

    # Verify
    if grep -q "Game.*csgo/addons/metamod" "$GAMEINFO_FILE"; then
        log_message "MetaMod repositioned successfully" "info"
        rm -f "$GAMEINFO_FILE.bak"
        return 0
    else
        log_message "Failed to reposition MetaMod, restoring backup" "error"
        mv "$GAMEINFO_FILE.bak" "$GAMEINFO_FILE"
        return 1
    fi
}

# Patch RequireLoginForDedicatedServers setting based on ALLOW_TOKENLESS variable
# If ALLOW_TOKENLESS=1 → sets to 0 (allows tokenless)
# If ALLOW_TOKENLESS=0 → sets to 1 (requires token)
patch_tokenless_setting() {
    local GAMEINFO_FILE="/home/container/game/csgo/gameinfo.gi"

    if [ ! -f "$GAMEINFO_FILE" ]; then
        log_message "gameinfo.gi not found, skipping tokenless patch" "debug"
        return 0
    fi

    # Determine desired value based on ALLOW_TOKENLESS variable
    local desired_value
    if [ "${ALLOW_TOKENLESS:-0}" -eq 1 ]; then
        desired_value="0"  # Allow tokenless
    else
        desired_value="1"  # Require token
    fi

    # Check current value
    local current_value=$(grep -oP 'RequireLoginForDedicatedServers"\s+"\K[0-9]+' "$GAMEINFO_FILE" 2>/dev/null)

    # If already correct, skip
    if [ "$current_value" = "$desired_value" ]; then
        log_message "RequireLoginForDedicatedServers already set to $desired_value" "debug"
        return 0
    fi

    # Backup
    cp "$GAMEINFO_FILE" "$GAMEINFO_FILE.bak" 2>/dev/null || {
        log_message "Failed to backup gameinfo.gi" "error"
        return 1
    }

    # Patch the value
    sed -i "s/\(RequireLoginForDedicatedServers\"[[:space:]]*\)\"[0-9]\"/\1\"$desired_value\"/" "$GAMEINFO_FILE"

    # Verify change
    local new_value=$(grep -oP 'RequireLoginForDedicatedServers"\s+"\K[0-9]+' "$GAMEINFO_FILE" 2>/dev/null)
    if [ "$new_value" = "$desired_value" ]; then
        rm -f "$GAMEINFO_FILE.bak"
        return 0
    else
        log_message "Failed to patch RequireLoginForDedicatedServers, restoring backup" "error"
        mv "$GAMEINFO_FILE.bak" "$GAMEINFO_FILE"
        return 1
    fi
}
