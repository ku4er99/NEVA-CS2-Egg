#!/usr/bin/env bash
# NevaAdminPlugin updater/installer for CounterStrikeSharp (private GitHub repo supported)

set -euo pipefail

source /utils/logging.sh
source /utils/updater_common.sh

# ------------------------------------------------------------------------------
# Config
# ------------------------------------------------------------------------------
PLUGIN_NAME="NEVA.CS2.NevaAdminPlugin"
ASSET_DEFAULT="${PLUGIN_NAME}-linux-x64.zip"

# Expected env vars:
#   NAP_ENABLED=0|1
#   NAP_GH_REPO=owner/repo              (e.g. ku4er99/NEVA.CS2.NevaAdminPlugin)
#   NAP_GH_TOKEN=...                    (PAT / fine-grained token with read access)
#   NAP_ASSET=...                       (optional, default: ${ASSET_DEFAULT})
#   NAP_ZIP_URL=...                     (optional direct URL; still needs token if private)
#   NAP_SB_PLACEMENTS=...               (optional SponsorBoards placements JSON)

log_info()    { log_message "[NevaAdminPlugin] $*"; }
log_running() { log_message "[NevaAdminPlugin] $*" "running"; }
log_error()   { log_message "[NevaAdminPlugin] $*" "error"; }
log_success() { log_message "[NevaAdminPlugin] $*" "success"; }
log_warning() { log_message "[NevaAdminPlugin] $*" "warning"; }
log_debug()   { log_message "[NevaAdminPlugin] $*" "debug"; }

# ------------------------------------------------------------------------------
# Helpers
# ------------------------------------------------------------------------------
find_css_plugins_dir() {
  local candidates=(
    "./game/csgo/addons/counterstrikesharp/plugins"
    "./csgo/addons/counterstrikesharp/plugins"
    "./game/csgo/addons/counterstrikesharp"
    "./csgo/addons/counterstrikesharp"
  )

  for p in "${candidates[@]}"; do
    if [[ -d "$p" ]]; then
      if [[ "$(basename "$p")" == "counterstrikesharp" ]]; then
        if [[ -d "$p/plugins" ]]; then
          echo "$p/plugins"
          return 0
        fi
      else
        echo "$p"
        return 0
      fi
    fi
  done

  local found
  found="$(find . -type d -path "*addons/counterstrikesharp/plugins" -print -quit 2>/dev/null || true)"
  if [[ -n "$found" ]]; then
    echo "$found"
    return 0
  fi

  return 1
}

require_cmd() {
  local cmd="$1"
  if ! command -v "$cmd" >/dev/null 2>&1; then
    log_error "Required command not found: $cmd"
    return 1
  fi
}

download_private_latest_asset() {
  # Args:
  #  1) repo owner/name
  #  2) asset name
  #  3) token
  #  4) output file
  local repo="$1"
  local asset_id="$2"
  local token="$3"
  local out="$4"

  require_cmd curl
  curl -4 -fL \
    --connect-timeout 15 --max-time 180 \
    --retry 5 --retry-delay 3 --retry-max-time 300 --retry-all-errors \
    -H "Authorization: Bearer ${token}" \
    -H "Accept: application/octet-stream" \
    -o "$out" \
    "https://api.github.com/repos/${repo}/releases/assets/${asset_id}"
}

resolve_private_latest_asset() {
  # Prints: tag_name<TAB>asset_id
  local repo="$1"
  local asset_name="$2"
  local token="$3"
  local release_json

  require_cmd curl
  require_cmd python3

  release_json="$(mktemp)"
  if ! curl -4 -fsSL \
    --connect-timeout 15 --max-time 60 \
    --retry 3 --retry-delay 2 --retry-max-time 120 --retry-all-errors \
    -H "Authorization: Bearer ${token}" \
    -H "Accept: application/vnd.github+json" \
    -o "$release_json" \
    "https://api.github.com/repos/${repo}/releases/latest"; then
    rm -f "$release_json"
    return 1
  fi

  python3 - "$release_json" "$asset_name" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as f:
    release = json.load(f)

asset_name = sys.argv[2]
asset = next((item for item in release.get("assets", [])
              if item.get("name") == asset_name), None)
if not asset or not release.get("tag_name") or not asset.get("id"):
    raise SystemExit(1)

print(f"{release['tag_name']}\t{asset['id']}")
PY
  local status=$?
  rm -f "$release_json"
  return "$status"
}

download_with_token_header() {
  # Args:
  #  1) url
  #  2) token
  #  3) output file
  local url="$1"
  local token="$2"
  local out="$3"

  require_cmd curl

  curl -4 -fL \
    --connect-timeout 15 --max-time 180 \
    --retry 5 --retry-delay 3 --retry-max-time 300 --retry-all-errors \
    -H "Authorization: Bearer ${token}" \
    -o "$out" \
    "$url"
}

write_nap_config() {
  local dest="$1"

  if [[ -z "${NAP_JSON_CONF:-}" ]]; then
    return 0
  fi

  if ! command -v python3 >/dev/null 2>&1; then
    log_warning "NAP_JSON_CONF is set, but python3 not found; skipping config.json."
    return 0
  fi

  local conf_file="${dest}/config.json"
  if python3 - "$conf_file" <<'PY'
import os, sys, json

out_path = sys.argv[1]
raw = os.environ.get("NAP_JSON_CONF", "").strip()
if not raw:
    raise SystemExit(2)

try:
    obj = json.loads(raw)
except Exception:
    raise SystemExit(3)

with open(out_path, "w", encoding="utf-8") as f:
    json.dump(obj, f, ensure_ascii=False, indent=2)
    f.write("\n")
PY
  then
    log_success "Wrote config: ${conf_file}"
  else
    log_warning "NAP_JSON_CONF is set, but not valid JSON; skipping config.json."
  fi
}

write_sponsorboards_placements() {
  local css_plugins_dir="$1"

  if [[ -z "${NAP_SB_PLACEMENTS:-}" ]]; then
    log_warning "NAP_SB_PLACEMENTS is not set, skip changing placements.json."
    return 0
  fi

  if ! command -v python3 >/dev/null 2>&1; then
    log_warning "NAP_SB_PLACEMENTS is set, but python3 not found; keeping the existing placements.json."
    return 0
  fi

  local sponsorboards_dir placements_file
  sponsorboards_dir="$(dirname "$css_plugins_dir")/configs/plugins/${PLUGIN_NAME}/sponsorboards"
  placements_file="${sponsorboards_dir}/placements.json"
  mkdir -p "$sponsorboards_dir"

  if NAP_SB_PLACEMENTS="$NAP_SB_PLACEMENTS" NAP_SB_PLACEMENTS_FILE="$placements_file" python3 - <<'PY'
import json
import os
import pathlib
import tempfile

raw = os.environ.get("NAP_SB_PLACEMENTS", "").strip()
target = pathlib.Path(os.environ["NAP_SB_PLACEMENTS_FILE"])

try:
    document = json.loads(raw)
except (TypeError, json.JSONDecodeError):
    raise SystemExit(2)

if not isinstance(document, dict) or not isinstance(document.get("Boards"), list):
    raise SystemExit(3)

fd, temporary = tempfile.mkstemp(prefix="placements.", suffix=".tmp", dir=target.parent)
try:
    with os.fdopen(fd, "w", encoding="utf-8") as stream:
        json.dump(document, stream, ensure_ascii=False, indent=2)
        stream.write("\n")
        stream.flush()
        os.fsync(stream.fileno())
    os.replace(temporary, target)
except BaseException:
    try:
        os.unlink(temporary)
    except FileNotFoundError:
        pass
    raise
PY
  then
    log_success "Wrote SponsorBoards placements: ${placements_file}"
  else
    log_warning "NAP_SB_PLACEMENTS is not a valid placements document; keeping the existing placements.json."
  fi
}

# ------------------------------------------------------------------------------
# Main entry (call from update.sh): update_nap
# ------------------------------------------------------------------------------
update_nap() {
  # Toggle
  if [[ "${NAP_ENABLED:-0}" != "1" ]]; then
    log_debug "Disabled (NAP_ENABLED!=1)."
    return 0
  fi

  # Find CSS plugins dir
  local CSS_PLUGINS_DIR
  CSS_PLUGINS_DIR="$(find_css_plugins_dir || true)"
  if [[ -z "${CSS_PLUGINS_DIR:-}" ]]; then
    log_warning "CounterStrikeSharp plugins dir not found. Is CSS installed/enabled?"
    return 0
  fi

  # Check unzip
  if ! command -v unzip >/dev/null 2>&1; then
    log_error "unzip not found in container. Install it in the egg install script (apt/apk) and retry."
    return 1
  fi

  # Temp
  local tmpdir zipfile
  tmpdir="$(mktemp -d)"
  zipfile="$tmpdir/plugin.zip"
  # Cleanup for this function call
  # shellcheck disable=SC2064
  trap "rm -rf '$tmpdir'" RETURN

  # Decide what to download
  local asset_name token repo url dest release_info release_tag asset_id release_key current_version
  asset_name="${NAP_ASSET:-$ASSET_DEFAULT}"
  token="${NAP_GH_TOKEN:-}"
  repo="${NAP_GH_REPO:-}"
  url="${NAP_ZIP_URL:-}"
  dest="${CSS_PLUGINS_DIR}/${PLUGIN_NAME}"

  # Runtime configuration (including SponsorBoards placements) lives under
  # addons/counterstrikesharp/configs, outside this DLL deployment directory.
  # Keep installation scoped to dest so updates never remove that state.

  write_sponsorboards_placements "$CSS_PLUGINS_DIR"

  if [[ -z "$token" ]]; then
    log_warning "NAP_GH_TOKEN is not set. Private repo download will fail."
    return 0
  fi

  log_info "Plugins dir: ${CSS_PLUGINS_DIR}"

  if [[ -n "$url" ]]; then
    log_running "Downloading (direct URL): ${url}"
    if ! download_with_token_header "$url" "$token" "$zipfile"; then
      if [[ -d "$dest" ]]; then
        log_warning "Download failed; keeping the currently installed plugin."
        write_nap_config "$dest"
        return 0
      fi
      log_error "Download failed and no installed plugin is available."
      return 1
    fi
  else
    if [[ -z "$repo" ]]; then
      log_warning "NAP_GH_REPO is empty and NAP_ZIP_URL not set. Can't download."
      return 0
    fi
    log_running "Resolving latest release via GitHub API: ${repo}"
    if ! release_info="$(resolve_private_latest_asset "$repo" "$asset_name" "$token")"; then
      if [[ -d "$dest" ]]; then
        log_warning "Could not resolve the latest release; keeping the currently installed plugin."
        write_nap_config "$dest"
        return 0
      fi
      log_error "Could not resolve the latest release and no installed plugin is available."
      return 1
    fi

    IFS=$'\t' read -r release_tag asset_id <<< "$release_info"
    if [[ -z "$release_tag" || -z "$asset_id" ]]; then
      log_error "Asset not found in latest release: ${asset_name}"
      return 1
    fi

    release_key="${release_tag}:${asset_id}"
    current_version="$(get_current_version "NevaAdminPlugin")"
    if [[ "$current_version" == "$release_key" && -d "$dest" ]]; then
      log_success "Already up to date (${release_tag}, asset id=${asset_id}); skipping download."
      write_nap_config "$dest"
      return 0
    fi

    log_running "Downloading asset '${asset_name}' (tag=${release_tag}, id=${asset_id})"
    if ! download_private_latest_asset "$repo" "$asset_id" "$token" "$zipfile"; then
      if [[ -d "$dest" ]]; then
        log_warning "Download failed; keeping the currently installed plugin (${current_version:-unknown version})."
        write_nap_config "$dest"
        return 0
      fi
      log_error "Download failed and no installed plugin is available."
      return 1
    fi
  fi

  # Unpack
  log_running "Unpacking zip"
  unzip -oq "$zipfile" -d "$tmpdir/unpacked"

  # Determine content root (zip may contain PLUGIN_NAME/...)
  local src
  src="$tmpdir/unpacked"
  if [[ -d "$tmpdir/unpacked/$PLUGIN_NAME" ]]; then
    src="$tmpdir/unpacked/$PLUGIN_NAME"
  fi

  log_running "Installing to: ${dest}"

  rm -rf "$dest"
  mkdir -p "$dest"
  cp -a "$src/." "$dest/"
  
    # --------------------------------------------------------------------------
  # config: write config.json if NAP_JSON_CONF contains JSON
  # --------------------------------------------------------------------------
  write_nap_config "$dest"

  if [[ -z "$url" ]]; then
    update_version_file "NevaAdminPlugin" "$release_key"
  fi


  log_success "Installed ${PLUGIN_NAME} (latest release)."
  return 0
}
