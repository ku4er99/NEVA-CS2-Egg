# Managed shared CS2 startup

SMS-managed nodes mount `/srv/cs2-shared` read-only at `SYNC_LOCATION=/tmp/cs2_ds`.
The host provisioning and maintenance tools in `NEVA.ServerManagementService/ansible`
own that installation. Slot startup consumes the verified build; it never runs its own
SteamCMD against that tree.

## Admission and synchronization

The entrypoint recognizes the managed mount by its fixed `/tmp/cs2_ds` path. A different
sync path is also managed when `.neva-provisioned` or `.neva-maintenance` exists there.
An absent or damaged managed mount is an error, not permission to install or update it.

Before copying binaries, linking VPKs or copying default configs, the entrypoint opens
`.neva-maintenance/cs2.lock` read-only and takes a nonblocking shared `flock`. It then
requires all of the following under that lock:

- A nonempty `.neva-provisioned` file and readable `.neva-maintenance/start-guard.sh`.
- No `.neva-maintenance/blocked` recovery marker.
- `steamapps/appmanifest_730.acf` with `appid=730`, `StateFlags=4` and a positive numeric build ID.
- A nonempty executable `game/bin/linuxsteamrt64/cs2` and nonempty `game/csgo/pak01_dir.vpk`.
- Nonempty `.steam/sdk32/steamclient.so` and `.steam/sdk64/steamclient.so` files.
- Requested app ID 730 and no per-slot beta branch override.

Failure rejects startup with exit 75, before any slot game-file mutation. Recovery belongs
to the existing SMS host maintenance flow; do not remove markers or create an empty lock
as a startup workaround. The stable lock inode must not be replaced during operation.

FD 8 remains open in the entrypoint and is inherited by the game. This covers the entire
sync/start/game lifetime and excludes the host's exclusive maintenance writer. The
existing host startup wrapper uses FD 9 and remains compatible.

Managed slots still synchronize non-VPK files and VPK links, preserve existing
`gameinfo.gi` and server configs, copy missing defaults, and run the selected addon
updaters. Maintenance metadata is excluded from the copy. A failed base-file copy,
VPK enumeration/link or default-config copy rejects startup. Addon release/freeze
configuration is unchanged.

Keep `SRCDS_STOP_UPDATE=0` for managed slots. `SRCDS_STOP_UPDATE=1` is not the mechanism
for avoiding SteamCMD: it historically also disabled required synchronization. Managed
mode skips SteamCMD independently and always performs required synchronization, even
if the old stop-update variable remains set to 1.

## Ordinary installations and retries

Installations without the managed path or markers retain per-slot SteamCMD updates
and the existing stop-update behavior. Arguments are passed as an array, without
shell evaluation. The wrapper reports attempt number, deadline and numeric exit
status; it does not print commands, passwords, beta passwords or raw SteamCMD output.

| Environment variable | Default | Accepted range | Meaning |
| --- | --- | --- | --- |
| `STEAMCMD_UPDATE_ATTEMPTS` | `3` | 1–10 | Maximum attempts per SteamCMD phase |
| `STEAMCMD_UPDATE_TIMEOUT` | `600` | 1–3600 seconds | Maximum time for one attempt |
| `STEAMCMD_UPDATE_DEADLINE` | `1800` | 2–7200 seconds | Overall budget including retry delays |
| `STEAMCMD_UPDATE_BACKOFF` | `5` | 0–300 seconds | Initial exponential retry delay, capped at 300 seconds |

An attempt's timeout is shortened to fit the remaining overall budget, reserving one
second for forced termination after SIGTERM. Status capture works under `set -euo
pipefail`, including when it is enabled by the sourced NAP updater. New SteamCMD client
bootstrap uses the same bounded wrapper with its own phase budget; existing SteamCMD
installations skip bootstrap. After a successful CS2 update, the manifest, executable
and VPK are verified before startup continues. Failure never falls back to launching
an old or partially updated local installation.

## Validation and release

Run on Linux with Bash, coreutils, util-linux, rsync, jq, zip/unzip and ShellCheck:

```bash
find docker -name '*.sh' -print0 | xargs -0 -n1 bash -n
shellcheck -S warning -e SC1091 docker/scripts/steamcmd.sh docker/scripts/shared_install.sh docker/tests/startup_update_test.sh
for test in docker/tests/*_test.sh; do bash "$test"; done
```

The startup suite mocks SteamCMD but uses real file copies, VPK links, `flock`, inherited
file descriptors and a real timeout. It covers incomplete/shared/blocked installations,
lock contention, sync failures, retries under strict mode, deadline exhaustion, secret
arguments and rejection of a successful exit with an incomplete manifest. No game or
network Steam installation is needed.

The reusable `shell-tests` workflow gates both version bumping and image publishing.
The existing main-branch workflow chooses the next `VERSION` and tag. Tags pushed by
its `GITHUB_TOKEN` do not trigger another workflow: dispatch `publish.yml` explicitly
at the resulting version tag (not the main branch). That workflow runs the same tests
before building the NEVA Docker image. Do not manually modify `VERSION` for this
change. Deploy the resulting immutable image through the existing SMS/Pelican delivery
process; no host-side script replacement is required.
