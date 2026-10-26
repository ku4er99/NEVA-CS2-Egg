#!/bin/bash

source /utils/logging.sh
source /utils/config.sh
source /scripts/install.sh
source /scripts/shared_install.sh
source /scripts/sync.sh
source /scripts/cleanup.sh
source /scripts/update.sh
source /scripts/filter.sh
source /scripts/update_helper.sh

# Enhanced error handling
trap 'handle_error ${LINENO} "$BASH_COMMAND"' ERR

cd /home/container
sleep 1

# Run legacy file migration check (only runs on first boot with new structure)
migrate_legacy_files

# Remove obsolete config files from old versions
cleanup_obsolete_configs

# Check for deprecated variables (ADDON_SELECTION)
#check_deprecated_variables

# Initialize and load configurations
init_configs
load_configs

# Get internal Docker IP
INTERNAL_IP=$(ip route get 1 | awk '{print $NF;exit}')

# Validate and lock a managed shared tree before any file sync. Failure never
# falls through to addons/game startup, including after a partial local update.
prepare_game_files || exit $?

# Handle the addon installations based on the selection
update_addons

# Set up console filter
setup_message_filter

# Build the actual startup command from template
MODIFIED_STARTUP=$(eval echo $(echo ${STARTUP} | sed -e 's/{{/${/g' -e 's/}}/}/g'))

# Log the command but hide the Steam account token for security
LOGGED_STARTUP=$(echo "${MODIFIED_STARTUP}" | \
    sed -E 's/(\+sv_setsteamaccount\s+[A-Z0-9]{32})/+sv_setsteamaccount ************************/g')
log_message "Starting server: ${LOGGED_STARTUP}" "info"

# Start GDB debugger in background if port specified
if [[ "${GDB_DEBUG_PORT:-0}" =~ ^[0-9]+$ ]] && [ "${GDB_DEBUG_PORT:-0}" -gt 0 ]; then
    (
        CS2_PID=""
        for i in {1..30}; do
            sleep 1
            for pid in /proc/[0-9]*; do
                [ -d "$pid" ] || continue
                cmdline=$(cat "$pid/cmdline" 2>/dev/null | tr '\0' ' ')
                if [[ "$cmdline" =~ game/bin/.*/cs2 ]] || [[ "$cmdline" =~ /cs2\.sh ]]; then
                    CS2_PID=$(basename "$pid")
                    break 2
                fi
            done
        done

        if [ -n "${CS2_PID:-}" ]; then
            log_message "Starting GDB debugger on port ${GDB_DEBUG_PORT} (PID: ${CS2_PID})" "info"
            log_message "The console may hang until you resume it through IDA Pro or GDB client" "warning"
            gdbserver :"${GDB_DEBUG_PORT}" --attach "${CS2_PID}" > /tmp/gdb.log 2>&1 || \
              log_message "GDB server failed to start (see /tmp/gdb.log)" "warning"
        else
            log_message "CS2 process not found after 30s timeout" "error"
        fi
    ) &
fi

# Actually start the server and handle its output
script -qfc "$MODIFIED_STARTUP" /dev/null 2>&1 | while IFS= read -r line; do
    line="${line%[[:space:]]}"
    [[ -n "${GAMEEXE:-}" && "$line" =~ Segmentation\ fault.*"${GAMEEXE}" ]] && continue

    # Detect crash via cs2.sh crash message pattern
    if [[ "$line" =~ \./game/cs2\.sh:.*Aborted.*\(core\ dumped\) ]]; then
        handle_server_output "$line"

        log_message "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" "warning"
        log_message "Server crash detected - Common causes and solutions:" "warning"
        log_message "" "warning"
        log_message "1. Plugin Issues:" "info"
        log_message "   • Check if recently installed/updated plugins are compatible" "info"
        log_message "   • Try removing plugins one by one to identify the culprit" "info"
        log_message "" "warning"
        log_message "2. Addon Compatibility:" "info"
        log_message "   • Verify MetaMod/CSS/SwiftlyS2/ModSharp versions are up to date" "info"
        log_message "   • Check addon compatibility with current CS2 version" "info"
        log_message "   • Review gameinfo.gi for correct addon load order" "info"
        log_message "" "warning"
        log_message "3. Outdated Gamedata:" "info"
        log_message "   • Check which plugins have outdated gamedata for current CS2 version" "info"
        log_message "   • Visit: https://gdc.eternar.dev" "info"
        log_message "" "warning"
        log_message "Review logs above for specific error messages and stack traces" "warning"
        log_message "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" "warning"
        continue
    fi

    handle_server_output "$line"
done

# Clean up any background processes we started
pkill -P $$ 2>/dev/null || true

log_message "Server stopped" "success"