#!/bin/bash
# MetaMod Auto-Update Script
# Downloads and installs MetaMod from GitHub Releases

source /utils/logging.sh
source /utils/updater_common.sh

get_metamod_release() {
    local repo="alliedmodders/metamod-source"
    local api_url="https://api.github.com/repos/${repo}/releases"

    curl -4 -fsSL --connect-timeout 15 --max-time 60 "$api_url" 2>/dev/null | jq -r '
        [
            .[]
            | select(.tag_name | startswith("2.0."))
            | {
                version: .tag_name,
                is_prerelease: .prerelease,
                asset_name: (
                    first(
                        .assets[]?
                        | select(.name | test("^mmsource-.*-linux\\.tar\\.gz$"))
                        | .name
                    ) // ""
                ),
                asset_url: (
                    first(
                        .assets[]?
                        | select(.name | test("^mmsource-.*-linux\\.tar\\.gz$"))
                        | .browser_download_url
                    ) // ""
                )
            }
            | select(.asset_url != "")
        ]
        | first
        | @base64
    '
}

update_metamod() {
    local OUTPUT_DIR="./game/csgo/addons"

    if [ ! -d "$OUTPUT_DIR/metamod" ]; then
        log_message "Installing Metamod..." "info"
    fi

    local release_b64
    release_b64="$(get_metamod_release)"

    if [ -z "$release_b64" ] || [ "$release_b64" = "null" ]; then
        log_message "Failed to fetch Metamod release from GitHub" "error"
        return 1
    fi

    local release_json
    release_json="$(echo "$release_b64" | base64 -d 2>/dev/null)"

    local github_tag
    local asset_name
    local full_url

    github_tag="$(echo "$release_json" | jq -r '.version // empty')"
    asset_name="$(echo "$release_json" | jq -r '.asset_name // empty')"
    full_url="$(echo "$release_json" | jq -r '.asset_url // empty')"

    if [ -z "$github_tag" ] || [ -z "$asset_name" ] || [ -z "$full_url" ]; then
        log_message "Invalid Metamod release data from GitHub" "error"
        log_message "Release data: $release_json" "debug"
        return 1
    fi

    local new_version
    new_version="$(echo "$asset_name" | grep -oP 'git\d+' || true)"

    if [ -z "$new_version" ]; then
        new_version="$github_tag"
    fi

    local current_version
    current_version="$(get_current_version "Metamod")"

    if [ "$current_version" = "$new_version" ]; then
        log_message "Metamod is up-to-date ($current_version)" "info"
        return 0
    fi

    log_message "Update available for Metamod: $new_version (current: ${current_version:-none})" "info"
    log_message "GitHub asset: $asset_name" "debug"
    log_message "Download URL: $full_url" "debug"

    mkdir -p "$OUTPUT_DIR"
    rm -rf "$TEMP_DIR/metamod"
    rm -f "$TEMP_DIR/metamod.tar.gz"

    if handle_download_and_extract "$full_url" "$TEMP_DIR/metamod.tar.gz" "$TEMP_DIR/metamod" "tar.gz"; then
        if [ ! -d "$TEMP_DIR/metamod/addons" ]; then
            log_message "Metamod archive does not contain addons directory" "error"
            return 1
        fi

        cp -rf "$TEMP_DIR/metamod/addons/." "$OUTPUT_DIR/" && \
        update_version_file "Metamod" "$new_version" && \
        log_message "Metamod updated to $new_version from GitHub release $github_tag" "success"
        return 0
    fi

    return 1
}

main() {
    mkdir -p "$TEMP_DIR"
    update_metamod
    return $?
}

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    main "$@"
fi