#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$ROOT/docker/scripts/steamcmd.sh"
source "$ROOT/docker/scripts/shared_install.sh"
test_dir="$(mktemp -d)"
trap 'rm -rf "$test_dir"' EXIT
log_message() { printf '%s\n' "$1" >> "$test_dir/log"; }
record() { printf '%s\n' "$1" >> "$test_dir/calls"; }
clean_old_logs() { record clean; }
sync_files() { record sync; }
sync_cfg_files() { record cfg; }
install_steamcmd() { record install; }

fixture_shared() {
    SYNC_LOCATION="$test_dir/shared"
    SRCDS_APPID=730
    mkdir -p "$SYNC_LOCATION/.neva-maintenance" "$SYNC_LOCATION/steamapps" \
        "$SYNC_LOCATION/game/bin/linuxsteamrt64" "$SYNC_LOCATION/game/csgo/cfg" \
        "$SYNC_LOCATION/.steam/sdk32" "$SYNC_LOCATION/.steam/sdk64"
    printf 'sdk32\n' > "$SYNC_LOCATION/.steam/sdk32/steamclient.so"
    printf 'sdk64\n' > "$SYNC_LOCATION/.steam/sdk64/steamclient.so"
    printf 'Prepared by SMS\n' > "$SYNC_LOCATION/.neva-provisioned"
    touch "$SYNC_LOCATION/.neva-maintenance/cs2.lock" "$SYNC_LOCATION/.neva-maintenance/start-guard.sh"
    printf 'game\n' > "$SYNC_LOCATION/game/bin/linuxsteamrt64/cs2"
    chmod +x "$SYNC_LOCATION/game/bin/linuxsteamrt64/cs2"
    printf 'content\n' > "$SYNC_LOCATION/game/csgo/pak01_dir.vpk"
    printf 'gameinfo\n' > "$SYNC_LOCATION/game/csgo/gameinfo.gi"
    printf 'default\n' > "$SYNC_LOCATION/game/csgo/cfg/default.cfg"
    cat > "$SYNC_LOCATION/steamapps/appmanifest_730.acf" <<'EOF'
"AppState"
{
    "appid" "730"
    "StateFlags" "4"
    "buildid" "12345"
}
EOF
}

fixture_steam() {
    fixture_shared
    mv "$SYNC_LOCATION/game" "$test_dir/game"
    mv "$SYNC_LOCATION/steamapps" "$test_dir/steamapps"
    unset SYNC_LOCATION
    cd "$test_dir"
    mkdir -p steamcmd/linux32 steamcmd/linux64
    touch steamcmd/linux32/steamclient.so steamcmd/linux64/steamclient.so
    export TEST_STEAM_DIR="$test_dir"
    cat > steamcmd/steamcmd.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
count=0
[[ ! -f "$TEST_STEAM_DIR/attempts" ]] || read -r count < "$TEST_STEAM_DIR/attempts"
count=$((count + 1))
printf '%s\n' "$count" > "$TEST_STEAM_DIR/attempts"
printf '%s\n' "$@" > "$TEST_STEAM_DIR/argv"
printf 'login secret: %s beta secret: %s\n' "${SRCDS_LOGIN_PASS:-}" "${SRCDS_BETAPASS:-}"
touch "$TEST_STEAM_DIR/partial-mutation"
if [[ "${TEST_STEAM_INVALID:-0}" == 1 ]]; then
    rm "$TEST_STEAM_DIR/steamapps/appmanifest_730.acf"
fi
if [[ "${TEST_STEAM_HANG:-0}" == 1 ]]; then
    [[ "${TEST_STEAM_IGNORE_TERM:-0}" != 1 ]] || trap '' TERM
    sleep 30
fi
if (( count <= ${TEST_STEAM_FAILURES:-0} )); then
    exit 8
fi
EOF
    chmod +x steamcmd/steamcmd.sh
    SRCDS_APPID=730
    STEAMCMD_UPDATE_BACKOFF=0
    STEAMCMD_UPDATE_TIMEOUT=5
    STEAMCMD_UPDATE_DEADLINE=20
    STEAMCMD_UPDATE_ATTEMPTS=3
}

shared_skip() {
    fixture_shared
    SRCDS_STOP_UPDATE=1
    install_steamcmd() { echo 'managed mode installed SteamCMD' >&2; exit 1; }
    update_game_files() { echo 'managed mode updated CS2' >&2; exit 1; }
    sync_files() {
        # The exclusive host maintenance writer is already excluded during sync.
        if flock --exclusive --nonblock "$SYNC_LOCATION/.neva-maintenance/cs2.lock" true; then
            echo 'sync ran without the shared lock' >&2
            exit 1
        fi
        record sync
    }
    prepare_game_files
    [[ "$(cat "$test_dir/calls")" == $'sync\ncfg\nclean' ]]
    bash -c ': <&8'  # The game child inherits the lock descriptor.
    if flock --exclusive --nonblock "$SYNC_LOCATION/.neva-maintenance/cs2.lock" true; then
        exit 1
    fi
    exec 8<&-
    flock --exclusive --nonblock "$SYNC_LOCATION/.neva-maintenance/cs2.lock" true
}

invalid_shared() {
    fixture_shared
    case "$3" in
        marker) rm "$SYNC_LOCATION/.neva-provisioned" ;;
        empty-marker) : > "$SYNC_LOCATION/.neva-provisioned" ;;
        lock) rm "$SYNC_LOCATION/.neva-maintenance/cs2.lock" ;;
        blocked) touch "$SYNC_LOCATION/.neva-maintenance/blocked" ;;
        state) sed -i 's/"StateFlags" "4"/"StateFlags" "6"/' "$SYNC_LOCATION/steamapps/appmanifest_730.acf" ;;
        build) sed -i 's/"buildid" "12345"/"buildid" "0"/' "$SYNC_LOCATION/steamapps/appmanifest_730.acf" ;;
        executable) : > "$SYNC_LOCATION/game/bin/linuxsteamrt64/cs2" ;;
        vpk) : > "$SYNC_LOCATION/game/csgo/pak01_dir.vpk" ;;
        sdk) : > "$SYNC_LOCATION/.steam/sdk64/steamclient.so" ;;
        branch) SRCDS_BETAID=unsupported ;;
        locked) exec 7< "$SYNC_LOCATION/.neva-maintenance/cs2.lock"; flock --exclusive --nonblock 7 ;;
    esac
    if prepare_game_files; then
        echo "invalid shared installation accepted ($3)" >&2
        exit 1
    else
        [[ $? == 75 ]]
    fi
    [[ ! -e "$test_dir/calls" ]] # No sync/local mutation/SteamCMD after invalid shared state.
}

actual_sync() {
    fixture_shared
    # Source the real sync functions using this test's logger, not /utils.
    # shellcheck source=/dev/null
    source <(sed '/^source /d' "$ROOT/docker/scripts/sync.sh")
    mkdir -p "$test_dir/slot/game/csgo/cfg"
    printf 'custom\n' > "$test_dir/slot/game/csgo/cfg/default.cfg"
    sync_files "$test_dir/slot"
    sync_cfg_files "$test_dir/slot"
    [[ -L "$test_dir/slot/game/csgo/pak01_dir.vpk" ]]
    [[ "$(cat "$test_dir/slot/game/csgo/cfg/default.cfg")" == custom ]]
    [[ -s "$test_dir/slot/game/bin/linuxsteamrt64/cs2" ]]
    [[ -s "$test_dir/slot/.steam/sdk64/steamclient.so" ]]
    [[ ! -e "$test_dir/slot/.neva-maintenance" && ! -e "$test_dir/slot/.neva-provisioned" ]]
}

sync_failure() {
    fixture_shared
    # shellcheck source=/dev/null
    source <(sed '/^source /d' "$ROOT/docker/scripts/sync.sh")
    mkdir -p "$test_dir/slot/game/csgo/cfg"
    case "$3" in
        rsync) rsync() { return 23; } ;;
        link) mkdir "$test_dir/slot/game/csgo/pak01_dir.vpk" ;;
        gameinfo) ln -s "$test_dir/missing/gameinfo" "$test_dir/slot/game/csgo/gameinfo.gi" ;;
        cfg) ln -s "$test_dir/missing/config" "$test_dir/slot/game/csgo/cfg/default.cfg" ;;
        find) find() { return 17; } ;;
    esac
    local status
    if [[ "$3" == cfg ]]; then
        if sync_cfg_files "$test_dir/slot"; then exit 1; else status=$?; fi
    else
        if sync_files "$test_dir/slot"; then exit 1; else status=$?; fi
    fi
    [[ "$status" != 0 ]]
}

managed_sync_failure() {
    fixture_shared
    sync_files() { record sync; return 23; }
    if prepare_game_files; then exit 1; else [[ $? == 23 ]]; fi
    [[ "$(cat "$test_dir/calls")" == sync ]]
}

nonmanaged_update() {
    fixture_steam
    SYNC_LOCATION="$test_dir/legacy-sync"
    export TEST_STEAM_FAILURES=1
    # First failure must be captured even with the exact global strict-mode options.
    trap 'echo "unexpected ERR trap" >&2; exit 99' ERR
    prepare_game_files
    [[ "$(cat "$test_dir/attempts")" == 2 ]]
    [[ "$(cat "$test_dir/calls")" == $'sync\ncfg\ninstall\nclean' ]]
    [[ -f .steam/sdk32/steamclient.so && -f .steam/sdk64/steamclient.so ]]
}

secret_arguments() {
    fixture_steam
    export SRCDS_LOGIN='test user' SRCDS_LOGIN_PASS='login secret $(touch should-not-exist)'
    export SRCDS_BETAID=branch SRCDS_BETAPASS='beta secret;literal'
    SRCDS_VALIDATE=1
    update_game_files
    grep -Fxq "$SRCDS_LOGIN_PASS" "$test_dir/argv"
    grep -Fxq "$SRCDS_BETAPASS" "$test_dir/argv"
    grep -Fxq validate "$test_dir/argv"
    [[ ! -f should-not-exist ]]
    ! grep -Fq "$SRCDS_LOGIN_PASS" "$test_dir/log"
    ! grep -Fq "$SRCDS_BETAPASS" "$test_dir/log"
}

exhausted() {
    fixture_steam
    export TEST_STEAM_FAILURES=9
    if prepare_game_files; then
        echo 'partial failed update accepted' >&2
        exit 1
    else
        [[ $? == 8 ]]
    fi
    [[ "$(cat "$test_dir/attempts")" == 3 ]]
    [[ -f partial-mutation && ! -d .steam ]]
}

retry_backoff() {
    fixture_steam
    STEAMCMD_UPDATE_BACKOFF=2
    export TEST_STEAM_FAILURES=2
    sleep() { record "delay:$1"; }
    update_game_files
    [[ "$(cat "$test_dir/calls")" == $'delay:2\ndelay:4' ]]
    [[ "$(cat "$test_dir/attempts")" == 3 ]]
}

deadline() {
    fixture_steam
    STEAMCMD_UPDATE_TIMEOUT=3
    STEAMCMD_UPDATE_DEADLINE=6
    # Advance the shell's elapsed-time clock without making the suite slow.
    timeout() { record "$3"; SECONDS=$((SECONDS + ${3%s})); return 124; }
    if steamcmd_run_bounded update +app_update 730 +quit; then
        exit 1
    else
        [[ $? == 124 ]]
    fi
    [[ "$(cat "$test_dir/calls")" == $'3s\n2s' ]]
}

real_timeout() {
    fixture_steam
    export TEST_STEAM_HANG=1
    STEAMCMD_UPDATE_ATTEMPTS=1
    STEAMCMD_UPDATE_TIMEOUT=1
    local started=$SECONDS status
    if update_game_files; then
        exit 1
    else
        status=$?
        [[ "$status" == 124 || "$status" == 137 ]]
    fi
    (( SECONDS - started < 5 ))
    [[ ! -d .steam ]]
}

forced_timeout() {
    export TEST_STEAM_IGNORE_TERM=1
    real_timeout
}

incomplete_success() {
    fixture_steam
    export TEST_STEAM_INVALID=1
    if update_game_files; then
        echo 'SteamCMD exit 0 with incomplete manifest accepted' >&2
        exit 1
    else
        [[ $? == 1 ]]
    fi
    [[ ! -d .steam ]]
}

missing_managed_mount() {
    # Tests run in an isolated CI machine; no installation is created at this path.
    [[ ! -e /tmp/cs2_ds ]]
    SYNC_LOCATION=/tmp/cs2_ds
    if prepare_game_files; then
        exit 1
    else
        [[ $? == 75 ]]
    fi
    [[ ! -f "$test_dir/calls" ]]
}

legacy_disabled() {
    SRCDS_STOP_UPDATE=1
    prepare_game_files
    [[ ! -f "$test_dir/calls" ]]
}

entrypoint_contract() {
    grep -Fq 'prepare_game_files || exit $?' "$ROOT/docker/entrypoint.sh"
    ! grep -Fq 'eval ${STEAMCMD}' "$ROOT/docker/entrypoint.sh"
}

if [[ "${1:-}" == --case ]]; then
    "$2" "$@"
    exit 0
fi

for test_case in shared_skip nonmanaged_update secret_arguments exhausted retry_backoff deadline real_timeout forced_timeout incomplete_success missing_managed_mount legacy_disabled entrypoint_contract actual_sync managed_sync_failure; do
    bash "$0" --case "$test_case"
    printf 'PASS %s\n' "$test_case"
done
for invalid in marker empty-marker lock blocked state build executable vpk sdk branch locked; do
    bash "$0" --case invalid_shared "$invalid"
    printf 'PASS invalid_shared/%s\n' "$invalid"
done
for failure in rsync link gameinfo cfg find; do
    bash "$0" --case sync_failure "$failure"
    printf 'PASS sync_failure/%s\n' "$failure"
done
