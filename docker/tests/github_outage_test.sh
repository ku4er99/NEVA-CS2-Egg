#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT
export TEST_ROOT
mkdir -p "$TEST_ROOT/utils" "$TEST_ROOT/scripts/updaters"
cp "$ROOT/docker/utils/updater_common.sh" "$TEST_ROOT/utils/"
for updater in "$ROOT/docker/scripts/updaters/"*.sh; do
    sed "s|/utils/|$TEST_ROOT/utils/|g" "$updater" > "$TEST_ROOT/scripts/updaters/$(basename "$updater")"
done
sed -e "s|/utils/|$TEST_ROOT/utils/|g" -e "s|/scripts/|$TEST_ROOT/scripts/|g" \
    "$ROOT/docker/scripts/update.sh" > "$TEST_ROOT/update.sh"
cat > "$TEST_ROOT/utils/logging.sh" <<'SH'
log_message() { printf '%s: %s\n' "${2:-info}" "$1" >&2; }
SH

cat > "$TEST_ROOT/fixtures.sh" <<'SH'
put() { mkdir -p "$(dirname "$1")"; printf 'fixture-runtime\n' > "$1"; }
runtime_fixture() {
    put "$1/host/fxr/10/libhostfxr.so"
    put "$1/shared/Microsoft.NETCore.App/10/libcoreclr.so"
    put "$1/shared/Microsoft.NETCore.App/10/libhostpolicy.so"
}
addon_fixture() {
    local addon="$1" root="$2"
    case "$addon" in
        Metamod)
            put "$root/metamod/bin/linuxsteamrt64/libserver.so"
            put "$root/metamod/bin/linuxsteamrt64/metamod.2.cs2.so" ;;
        CSS)
            put "$root/counterstrikesharp/bin/linuxsteamrt64/counterstrikesharp.so"
            put "$root/counterstrikesharp/api/CounterStrikeSharp.API.dll"
            put "$root/counterstrikesharp/api/CounterStrikeSharp.API.runtimeconfig.json"
            put "$root/metamod/counterstrikesharp.vdf"
            runtime_fixture "$root/counterstrikesharp/dotnet" ;;
        MultiAddonManager)
            put "$root/multiaddonmanager/bin/multiaddonmanager.so"
            put "$root/metamod/multiaddonmanager.vdf" ;;
        NevaAdminPlugin)
            put "$root/counterstrikesharp/plugins/NEVA.CS2.NevaAdminPlugin/NEVA.CS2.NevaAdminPlugin.dll"
            put "$root/counterstrikesharp/plugins/NEVA.CS2.NevaAdminPlugin/NEVA.CS2.NevaAdminPlugin.deps.json" ;;
        Swiftly)
            put "$root/swiftlys2/bin/linuxsteamrt64/libserver.so"
            put "$root/swiftlys2/bin/linuxsteamrt64/swiftlys2.so"
            put "$root/swiftlys2/bin/linuxsteamrt64/libhostfxr.so"
            put "$root/swiftlys2/bin/managed/SwiftlyS2.Core.dll"
            runtime_fixture "$root/swiftlys2/bin/managed/dotnet"
            mkdir -p "$root/swiftlys2/gamedata" ;;
        ModSharp)
            put ./game/sharp/bin/linuxsteamrt64/libserver.so
            put ./game/sharp/bin/libmodsharp.so
            put ./game/sharp/core/Sharp.Core.dll
            put ./game/sharp/runtime/dotnet
            runtime_fixture ./game/sharp/runtime ;;
    esac
}
target_version() {
    case "$1" in
        Metamod) echo git2000 ;;
        NevaAdminPlugin) echo v-new:456 ;;
        ModSharp) echo gitnew ;;
        *) echo v-new ;;
    esac
}
SH

cat > "$TEST_ROOT/run.sh" <<'SH'
#!/usr/bin/env bash
set -Eeuo pipefail
trap 'exit $?' ERR
source "$TEST_ROOT/fixtures.sh"
addon="$1" mode="$2" installation="$3"
mkdir -p game/csgo/addons/counterstrikesharp/plugins egg
export EGG_DIR="$PWD/egg"
source "$TEST_ROOT/update.sh"
for item in Metamod MultiAddonManager CSS NevaAdminPlugin Swiftly ModSharp; do
    if [[ "$installation" != none ]]; then addon_fixture "$item" ./game/csgo/addons; fi
    if [[ "$installation" != unrecorded && "$installation" != none ]]; then
        version=old
        if [[ "$mode" == same || "$mode" == repair || "$mode" == runtime-upgrade ]]; then version="$(target_version "$item")"; fi
        update_version_file "$item" "$version"
    fi
done
update_version_file DotNet 10.0.0
if [[ "$mode" == runtime-upgrade ]]; then update_version_file DotNet old-runtime; fi
if [[ "$installation" == incomplete ]]; then
    case "$addon" in
        Metamod|all) : > game/csgo/addons/metamod/bin/linuxsteamrt64/metamod.2.cs2.so ;;
        CSS) : > game/csgo/addons/counterstrikesharp/api/CounterStrikeSharp.API.dll ;;
        MultiAddonManager) : > game/csgo/addons/multiaddonmanager/bin/multiaddonmanager.so ;;
        NevaAdminPlugin) : > game/csgo/addons/counterstrikesharp/plugins/NEVA.CS2.NevaAdminPlugin/NEVA.CS2.NevaAdminPlugin.dll ;;
        Swiftly) : > game/csgo/addons/swiftlys2/bin/linuxsteamrt64/swiftlys2.so ;;
        ModSharp) : > game/sharp/bin/libmodsharp.so ;;
    esac
fi
if [[ "$installation" == missing-runtime ]]; then
    case "$addon" in
        CSS) rm game/csgo/addons/counterstrikesharp/dotnet/host/fxr/10/libhostfxr.so ;;
        Swiftly) rm game/csgo/addons/swiftlys2/bin/managed/dotnet/host/fxr/10/libhostfxr.so ;;
        ModSharp) rm game/sharp/runtime/host/fxr/10/libhostfxr.so ;;
    esac
fi
export RELEASE_FREEZE=1 METAMOD_RELEASE_TAG=2.0.0.2000 CSS_RELEASE_TAG=v-new
export MAM_RELEASE_TAG=v-new SWIFTLY_RELEASE_TAG=v-new MODSHARP_RELEASE_TAG=git-new
export NAP_ENABLED=1 NAP_RELEASE_TAG=v-new NAP_GH_REPO=fixture/nap NAP_GH_TOKEN=SECRET-FIXTURE
export NAP_JSON_CONF='{"fixture":true}' NAP_SB_PLACEMENTS='{"Boards":[]}'
if [[ "$mode" == latest ]]; then
    METAMOD_RELEASE_TAG=latest CSS_RELEASE_TAG=latest MAM_RELEASE_TAG=latest
    SWIFTLY_RELEASE_TAG=latest MODSHARP_RELEASE_TAG=latest NAP_RELEASE_TAG=latest
fi
curl() {
    local url="${*: -1}" previous='' arg header_file=''
    printf '%s\n' "$url" >> "$PWD/urls"
    for arg in "$@"; do
        if [[ "$previous" == -D ]]; then header_file="$arg"; fi
        previous="$arg"
    done
    case "$mode" in
        403|429|500)
            printf 'HTTP/2 %s\r\nx-ratelimit-reset: 1794486866\r\n' "$mode" > "$header_file"
            return 22 ;;
        timeout) return 28 ;;
        malformed) printf '{broken'; return 0 ;;
        missing) printf '{"message":"Not Found"}'; return 0 ;;
    esac
    local tag=v-new name=addon.zip
    case "$url" in
        *metamod-source*) tag=2.0.0.2000; name=mmsource-2.0.0-git2000-linux.tar.gz ;;
        *CounterStrikeSharp*) name=counterstrikesharp-with-runtime-linux-v-new.zip ;;
        *MultiAddonManager*) name=MultiAddonManager-steamrt3.tar.gz ;;
        *swiftlys2*) name=swiftlys2-linux-with-runtimes.zip ;;
        *modsharp-public*)
            printf '%s' '{"tag_name":"git-new","assets":[{"name":"core-linux.zip","browser_download_url":"https://fixture.invalid/core"},{"name":"core-linux-extensions.zip","browser_download_url":"https://fixture.invalid/extensions"}]}'
            return 0 ;;
        *fixture/nap*) name=NEVA.CS2.NevaAdminPlugin-linux-x64.zip ;;
    esac
    printf '{"tag_name":"%s","assets":[{"name":"%s","id":456,"browser_download_url":"https://fixture.invalid/asset"}]}' "$tag" "$name"
}
handle_download_and_extract() {
    printf download >> "$PWD/downloads"
    [[ "$mode" != same ]]
    if [[ "$mode" == downloadfail ]]; then return 1; fi
    case "$addon" in
        Metamod|CSS|MultiAddonManager|Swiftly) addon_fixture "$addon" "$3/addons" ;;
        ModSharp) addon_fixture ModSharp ./game/csgo/addons ;;
    esac
}
download_private_latest_asset() {
    printf download >> "$PWD/downloads"
    [[ "$mode" != same ]]
    if [[ "$mode" == downloadfail ]]; then return 1; fi
    local fixture="$PWD/nap-archive"
    mkdir -p "$fixture"
    put "$fixture/NEVA.CS2.NevaAdminPlugin.dll"
    put "$fixture/NEVA.CS2.NevaAdminPlugin.deps.json"
    (cd "$fixture"; zip -q "$4" ./*)
}
case "$addon" in
    Metamod) update_metamod ;;
    CSS) update_counterstrikesharp ;;
    MultiAddonManager) update_multiaddonmanager ;;
    NevaAdminPlugin) update_nap ;;
    Swiftly) update_swiftly ;;
    ModSharp) update_modsharp ;;
    all)
        INSTALL_METAMOD=1 INSTALL_MULTIADDONMANAGER=1 INSTALL_CSS=1
        CLEANUP_ENABLED=0 INSTALL_SWIFTLY=0 INSTALL_MODSHARP=0
        add_to_gameinfo() { :; }
        remove_from_gameinfo() { :; }
        ensure_metamod_first() { :; }
        patch_tokenless_setting() { :; }
        update_addons
        test -s game/csgo/cfg/multiaddonmanager/multiaddonmanager.cfg ;;
esac
if [[ "$addon" == NevaAdminPlugin || "$addon" == all ]]; then
    test -s game/csgo/addons/counterstrikesharp/plugins/NEVA.CS2.NevaAdminPlugin/config.json
    test -s game/csgo/addons/counterstrikesharp/configs/plugins/NEVA.CS2.NevaAdminPlugin/sponsorboards/placements.json
fi
printf reached > startup
SH

cases=0
run_case() {
    local addon="$1" mode="$2" installation="$3" expected="$4"
    local dir="$TEST_ROOT/case-$cases"
    cases=$((cases + 1))
    mkdir -p "$dir"
    if (cd "$dir"; bash "$TEST_ROOT/run.sh" "$addon" "$mode" "$installation") > "$dir/log" 2>&1; then
        if [[ "$expected" != pass ]]; then cat "$dir/log"; echo "Unexpected success: $addon $mode $installation" >&2; exit 1; fi
        test -f "$dir/startup"
        if [[ "$mode" == same ]]; then test ! -f "$dir/downloads"; fi
        if [[ "$mode" =~ ^(403|429|500|timeout|malformed|missing)$ ]]; then
            grep -q "using installed old" "$dir/log"
            test ! -f "$dir/downloads"
        else
            if [[ "$mode" != same ]]; then test -s "$dir/downloads"; fi
        fi
    else
        if [[ "$expected" != fail ]]; then cat "$dir/log"; echo "Unexpected failure: $addon $mode $installation" >&2; exit 1; fi
        test ! -f "$dir/startup"
    fi
    if grep -q SECRET-FIXTURE "$dir/log"; then echo "Token leaked" >&2; exit 1; fi
    if [[ "$mode" == latest && "$addon" != Metamod ]]; then grep -q '/releases/latest$' "$dir/urls"; fi
    if [[ "$mode" == same ]]; then grep -q '/releases/tags/' "$dir/urls"; fi
}

for addon in Metamod CSS MultiAddonManager NevaAdminPlugin Swiftly ModSharp; do
    for mode in 403 429 500 timeout malformed missing; do
        run_case "$addon" "$mode" complete pass
    done
    for installation in none unrecorded incomplete; do
        run_case "$addon" 403 "$installation" fail
    done
    run_case "$addon" same complete pass
    run_case "$addon" changed complete pass
    run_case "$addon" changed none pass
    run_case "$addon" repair incomplete pass
    if [[ "$addon" == CSS || "$addon" == Swiftly || "$addon" == ModSharp ]]; then
        run_case "$addon" 403 missing-runtime fail
        run_case "$addon" repair missing-runtime pass
    fi
    run_case "$addon" latest complete pass
    if [[ "$addon" == NevaAdminPlugin ]]; then
        run_case "$addon" downloadfail complete pass
    else
        run_case "$addon" downloadfail complete fail
    fi
done
run_case ModSharp runtime-upgrade complete pass
run_case all 403 complete pass
run_case all 403 none fail
run_case all 403 incomplete fail

# Metamod's release listing must skip newer releases without a Linux archive.
(
    source "$TEST_ROOT/scripts/updaters/metamod.sh"
    RELEASE_FREEZE=0 METAMOD_RELEASE_TAG=''
    curl() {
        printf '%s' '[{"tag_name":"2.0.0.2001","assets":[{"name":"windows.zip"}]},{"tag_name":"2.0.0.2000","assets":[{"name":"mmsource-2.0.0-git2000-linux.tar.gz","browser_download_url":"https://fixture.invalid/archive"}]}]'
    }
    release="$(get_metamod_release | base64 -d)"
    test "$(printf '%s' "$release" | jq -r .version)" = 2.0.0.2000
)
echo "GitHub outage tests passed ($cases startup cases + Metamod Linux selection)"
