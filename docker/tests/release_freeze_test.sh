#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
log_message() { :; }
source "$ROOT/docker/utils/updater_common.sh"

RELEASE_FREEZE=1
if get_github_release "owner/repo" ".*" "" >/dev/null 2>&1; then
    echo "freeze without an explicit tag unexpectedly succeeded" >&2
    exit 1
fi

test_dir="$(mktemp -d)"
export test_dir
trap 'rm -rf "$test_dir"' EXIT
curl() {
    printf '%s' "${*: -1}" > "$test_dir/url"
    printf '%s' '{"tag_name":"v1.2.3","prerelease":false,"assets":[{"name":"addon-linux.zip","browser_download_url":"https://example.invalid/addon.zip"}]}'
}
export -f curl

result="$(get_github_release "owner/repo" "linux\\.zip$" "v1.2.3")"
test "$(printf '%s' "$result" | jq -r .version)" = "v1.2.3"
test "$(cat "$test_dir/url")" = "https://api.github.com/repos/owner/repo/releases/tags/v1.2.3"
