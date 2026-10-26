#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT
mkdir -p "$TEST_ROOT/utils" "$TEST_ROOT/home/game/csgo/addons/counterstrikesharp/plugins"
sed "s|/utils/|$TEST_ROOT/utils/|g" "$ROOT/docker/scripts/updaters/nap.sh" > "$TEST_ROOT/nap.sh"
cp "$ROOT/docker/utils/logging.sh" "$ROOT/docker/utils/updater_common.sh" "$TEST_ROOT/utils/"
cd "$TEST_ROOT/home"
source "$TEST_ROOT/nap.sh"
NAP_ENABLED=1
NAP_GH_TOKEN=fixture
NAP_GH_REPO=fixture/nap
NAP_RELEASE_TAG=latest
RELEASE_FREEZE=1
NAP_LOCAL_ARCHIVE=/tmp/cs2_ds/.neva-releases/stale.zip
# Assert actual API route and return an up-to-date fixture release, avoiding network.
curl() {
  test "${*: -1}" = "https://api.github.com/repos/fixture/nap/releases/latest"
  local out="" previous="" arg
  for arg in "$@"; do
    if [[ "$previous" == "-o" ]]; then out="$arg"; fi
    previous="$arg"
  done
  printf '%s' '{"tag_name":"v-fixture","assets":[{"name":"NEVA.CS2.NevaAdminPlugin-linux-x64.zip","id":123}]}' > "$out"
}
get_current_version() { printf '%s' 'v-fixture:123'; }
write_nap_config() { :; }
write_sponsorboards_placements() { :; }
mkdir -p "./game/csgo/addons/counterstrikesharp/plugins/NEVA.CS2.NevaAdminPlugin"
update_nap
test -z "$NAP_LOCAL_ARCHIVE"
# Exact local releases need no checksum and compare by release tag.
NAP_RELEASE_TAG=v-fixture
NAP_LOCAL_ARCHIVE=/tmp/cs2_ds/.neva-releases/fixture.zip
get_current_version() { printf '%s' 'v-fixture:local'; }
# Mock only the permitted cache file's existence, avoiding writes to host cache.
mkdir -p "$TEST_ROOT/home/game/csgo/addons/counterstrikesharp/plugins/NEVA.CS2.NevaAdminPlugin"
touch "$TEST_ROOT/home/game/csgo/addons/counterstrikesharp/plugins/NEVA.CS2.NevaAdminPlugin/NEVA.CS2.NevaAdminPlugin.dll"
# Check path policy rejects nonexistent archives without needing checksum tools.
if update_nap; then echo "nonexistent local archive accepted" >&2; exit 1; fi
echo "NAP release tests passed"
