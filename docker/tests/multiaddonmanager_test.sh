#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT

mkdir -p "$TEST_ROOT/utils" "$TEST_ROOT/scripts/updaters" "$TEST_ROOT/home/game/csgo"
cp "$ROOT/docker/utils/logging.sh" "$TEST_ROOT/utils/"
cp "$ROOT/docker/utils/updater_common.sh" "$TEST_ROOT/utils/"
for updater in "$ROOT/docker/scripts/updaters/"*.sh; do
    sed "s|/utils/|$TEST_ROOT/utils/|g" "$updater" > "$TEST_ROOT/scripts/updaters/$(basename "$updater")"
done
sed -e "s|/utils/|$TEST_ROOT/utils/|g" \
    "$ROOT/docker/scripts/updaters/multiaddonmanager.sh" > "$TEST_ROOT/mam.sh"

cd "$TEST_ROOT/home"
EGG_DIR="$TEST_ROOT/egg"
export EGG_DIR
# shellcheck source=/dev/null
source "$TEST_ROOT/mam.sh"

configure_multiaddonmanager
expected='mm_extra_addons "3763253081"
mm_client_extra_addons ""
mm_extra_addons_timeout "10"
mm_addon_connection_timeout "30"
mm_addon_mount_download "1"
mm_cache_clients_with_addons "1"
mm_cache_clients_duration "0"
mm_block_disconnect_messages "1"'
actual="$(cat game/csgo/cfg/multiaddonmanager/multiaddonmanager.cfg)"
[ "$actual" = "$expected" ]

# Configuration generation is idempotent.
first_hash="$(sha256sum game/csgo/cfg/multiaddonmanager/multiaddonmanager.cfg)"
configure_multiaddonmanager
[ "$first_hash" = "$(sha256sum game/csgo/cfg/multiaddonmanager/multiaddonmanager.cfg)" ]

# The updater installs once and skips a repeated run at the same version.
download_count=0
jq() {
    case "$*" in
        "-e .") cat >/dev/null ;;
        *version*) cat >/dev/null; printf '%s\n' 'v-test' ;;
        *asset_url*) cat >/dev/null; printf '%s\n' 'https://example.invalid/mam.zip' ;;
        *asset_name*) cat >/dev/null; printf '%s\n' 'MultiAddonManager-linux.zip' ;;
        *) return 1 ;;
    esac
}
get_github_release() {
    printf '%s\n' '{"version":"v-test","asset_url":"https://example.invalid/mam.zip","asset_name":"MultiAddonManager-linux.zip"}'
}
handle_download_and_extract() {
    download_count=$((download_count + 1))
    mkdir -p "$3/addons/multiaddonmanager/bin/linuxsteamrt64" "$3/addons/metamod"
    printf 'plugin\n' > "$3/addons/multiaddonmanager/bin/linuxsteamrt64/multiaddonmanager.so"
    printf 'vdf\n' > "$3/addons/metamod/multiaddonmanager.vdf"
}
update_multiaddonmanager
update_multiaddonmanager
[ "$download_count" -eq 1 ]
[ "$(get_current_version MultiAddonManager)" = "v-test" ]

# Disabled MAM must not auto-enable Metamod or generate configuration.
sed -e "s|/utils/|$TEST_ROOT/utils/|g" -e "s|/scripts/|$TEST_ROOT/scripts/|g" \
    "$ROOT/docker/scripts/update.sh" > "$TEST_ROOT/update.sh"
rm -f game/csgo/cfg/multiaddonmanager/multiaddonmanager.cfg
INSTALL_MULTIADDONMANAGER=0 INSTALL_METAMOD=0 CLEANUP_ENABLED=0 NAP_ENABLED=0 \
    bash -c 'source "$1"; ensure_metamod_first(){ :; }; patch_tokenless_setting(){ :; }; update_addons; test "${INSTALL_METAMOD:-0}" = 0; test ! -e game/csgo/cfg/multiaddonmanager/multiaddonmanager.cfg' _ "$TEST_ROOT/update.sh"

# Enabling MAM must enable Metamod before invoking either updater.
order_file="$TEST_ROOT/order"
export order_file
INSTALL_MULTIADDONMANAGER=1 INSTALL_METAMOD=0 CLEANUP_ENABLED=0 NAP_ENABLED=0 \
    bash -c 'source "$1"; update_metamod(){ echo metamod >> "$order_file"; }; add_to_gameinfo(){ :; }; update_multiaddonmanager(){ echo mam >> "$order_file"; }; configure_multiaddonmanager(){ :; }; ensure_metamod_first(){ :; }; patch_tokenless_setting(){ :; }; update_addons; test "$INSTALL_METAMOD" = 1' _ "$TEST_ROOT/update.sh"
[ "$(cat "$order_file")" = $'metamod\nmam' ]

echo "MultiAddonManager tests passed"
