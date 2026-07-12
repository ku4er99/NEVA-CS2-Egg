#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT

mkdir -p "$TEST_ROOT/utils" "$TEST_ROOT/home/game/csgo/addons/counterstrikesharp/plugins"
sed "s|/utils/|$TEST_ROOT/utils/|g" "$ROOT/docker/scripts/updaters/nap.sh" > "$TEST_ROOT/nap.sh"
cp "$ROOT/docker/utils/logging.sh" "$TEST_ROOT/utils/"
cp "$ROOT/docker/utils/updater_common.sh" "$TEST_ROOT/utils/"

cd "$TEST_ROOT/home"
# shellcheck source=/dev/null
source "$TEST_ROOT/nap.sh"

plugins_dir="./game/csgo/addons/counterstrikesharp/plugins"
placements="./game/csgo/addons/counterstrikesharp/configs/plugins/NEVA.CS2.NevaAdminPlugin/sponsorboards/placements.json"

# Empty input leaves an existing placements file untouched.
mkdir -p "$(dirname "$placements")"
printf '%s\n' '{"Boards":[{"Id":"existing"}]}' > "$placements"
unset NAP_SB_Placements
write_sponsorboards_placements "$plugins_dir"
grep -q 'existing' "$placements"

# Valid input atomically replaces the file.
export NAP_SB_Placements='{"Boards":[{"Map":"de_mirage","Id":"A","Model":"models/sponsors/de_mirage_a_asus_board.vmdl","X":123.45,"Y":-456.78,"Z":64.0,"Pitch":0.0,"Yaw":90.0,"Roll":0.0,"Scale":0.5}]}'
write_sponsorboards_placements "$plugins_dir"
python3 - "$placements" <<'PY'
import json
import sys
with open(sys.argv[1], encoding="utf-8") as stream:
    document = json.load(stream)
assert document["Boards"][0]["Map"] == "de_mirage"
assert document["Boards"][0]["Scale"] == 0.5
PY

# Invalid non-empty input also preserves the last valid file.
before="$(sha256sum "$placements")"
export NAP_SB_Placements='{"unexpected":[]}'
write_sponsorboards_placements "$plugins_dir"
[ "$before" = "$(sha256sum "$placements")" ]

echo "NAP SponsorBoards placements tests passed"
