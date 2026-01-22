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
  local asset_name="$2"
  local token="$3"
  local out="$4"

  require_cmd curl
  require_cmd python3

  log_running "Resolving latest release via GitHub API: ${repo}"

  local release_json
  release_json="$(mktemp)"
  curl -fsSL \
    -H "Authorization: Bearer ${token}" \
    -H "Accept: application/vnd.github+json" \
    -o "$release_json" \
    "https://api.github.com/repos/${repo}/releases/latest"

  local asset_id
  asset_id="$(python3 -c "import json; d=json.load(open('$release_json')); n='$asset_name'; 
assets=d.get('assets',[]);
m=[a for a in assets if a.get('name')==n];
print(m[0].get('id') if m else '')")"
  rm -f "$release_json"

  if [[ -z "$asset_id" ]]; then
    log_error "Asset not found in latest release: ${asset_name}"
    return 1
  fi

  log_running "Downloading asset '${asset_name}' (id=${asset_id})"
  curl -fL --retry 3 --retry-delay 2 \
    -H "Authorization: Bearer ${token}" \
    -H "Accept: application/octet-stream" \
    -o "$out" \
    "https://api.github.com/repos/${repo}/releases/assets/${asset_id}"
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

  curl -fL --retry 3 --retry-delay 2 \
    -H "Authorization: Bearer ${token}" \
    -o "$out" \
    "$url"
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
  local asset_name token repo url
  asset_name="${NAP_ASSET:-$ASSET_DEFAULT}"
  token="${NAP_GH_TOKEN:-}"
  repo="${NAP_GH_REPO:-}"
  url="${NAP_ZIP_URL:-}"

  if [[ -z "$token" ]]; then
    log_warning "NAP_GH_TOKEN is not set. Private repo download will fail."
    return 0
  fi

  log_info "Plugins dir: ${CSS_PLUGINS_DIR}"

  if [[ -n "$url" ]]; then
    log_running "Downloading (direct URL): ${url}"
    download_with_token_header "$url" "$token" "$zipfile"
  else
    if [[ -z "$repo" ]]; then
      log_warning "NAP_GH_REPO is empty and NAP_ZIP_URL not set. Can't download."
      return 0
    fi
    download_private_latest_asset "$repo" "$asset_name" "$token" "$zipfile"
  fi

  # Unpack
  log_running "Unpacking zip"
  unzip -oq "$zipfile" -d "$tmpdir/unpacked"

  # Determine content root (zip may contain PLUGIN_NAME/...)
  local src dest
  src="$tmpdir/unpacked"
  if [[ -d "$tmpdir/unpacked/$PLUGIN_NAME" ]]; then
    src="$tmpdir/unpacked/$PLUGIN_NAME"
  fi

  dest="${CSS_PLUGINS_DIR}/${PLUGIN_NAME}"
  log_running "Installing to: ${dest}"

  rm -rf "$dest"
  mkdir -p "$dest"
  cp -a "$src/." "$dest/"
  
    # --------------------------------------------------------------------------
  # config: write config.json if NAP_JSON_CONF contains JSON
  # --------------------------------------------------------------------------
  if [[ -n "${NAP_JSON_CONF:-}" ]]; then
    if ! command -v python3 >/dev/null 2>&1; then
      log_warning "NAP_JSON_CONF is set, but python3 not found; skipping config.json."
    else
      local conf_file
      conf_file="${dest}/config.json"

      # Validate JSON and write normalized JSON to file (overwrite)
      if python3 - "$conf_file" <<'PY'
import os, sys, json

out_path = sys.argv[1]
raw = os.environ.get("NAP_JSON_CONF", "")

# Allow accidental leading/trailing whitespace/newlines
raw_stripped = raw.strip()
if not raw_stripped:
    raise SystemExit(2)

try:
    obj = json.loads(raw_stripped)
except Exception:
    raise SystemExit(3)

# Write valid JSON (pretty) with newline
with open(out_path, "w", encoding="utf-8") as f:
    json.dump(obj, f, ensure_ascii=False, indent=2)
    f.write("\n")
PY
      then
        log_success "Wrote config: ${conf_file}"
      else
        log_warning "NAP_JSON_CONF is set, but not valid JSON; skipping config.json."
      fi
    fi
  fi


  log_success "Installed ${PLUGIN_NAME} (latest release)."
  return 0
}
