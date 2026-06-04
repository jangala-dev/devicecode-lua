# Per-Component Memory Usage Test

This folder contains a helper script to run DeviceCode repeatedly while dropping one service or one HAL manager at a time, and capture memory snapshots for each run.

Script:
- `test-mem-usage-per-component-dropped.sh`

## What It Does

The script runs these variants:
- Full baseline: all services enabled
- Drop one service at a time
- Drop one HAL manager at a time (by removing that manager from `hal.data` in config)

For each variant, it:
- Starts `main.lua`
- Samples process memory every N seconds (`ps` RSS/VSZ)
- Stops after a fixed duration
- Writes logs into a variant-specific directory

The original config is backed up and restored automatically (including on Ctrl+C/TERM).

## Prerequisites

- Run from this repository (or set `DEVICECODE_ROOT`)
- Shell with POSIX `sh`
- `luajit` (or another Lua binary via env var)
- A valid config file under either `src/configs` (source tree) or `configs` (build tree)
- The files in this folder:
  - `all_services`
  - `all_managers`

## Quick Start

From repository root:

```sh
chmod +x tests/integration/onbox/test-mem-usage/test-mem-usage-per-component-dropped.sh
./tests/integration/onbox/test-mem-usage/test-mem-usage-per-component-dropped.sh
```

Default behavior:
- Config target: `bigbox-v1-cm-2`
- Runtime per variant: `120` seconds
- Sample interval: `5` seconds
- Logs: `/tmp/devicecode-per-component-dropped-<timestamp>`

## Environment Variables

You can override these when running:

- `DEVICECODE_ROOT`
  - Repository root path
  - Default: auto-detected from script location

- `DEVICECODE_APP_DIR`
  - Directory where `main.lua` is executed from
  - Default: `$DEVICECODE_ROOT/src` if it exists, otherwise `$DEVICECODE_ROOT`

- `DEVICECODE_ALL_SERVICES_FILE`
  - Path to services list file
  - Default: `<script_dir>/all_services`

- `DEVICECODE_ALL_MANAGERS_FILE`
  - Path to managers list file
  - Default: `<script_dir>/all_managers`

- `CONFIG_TARGET`
  - Config name without `.json`
  - Default: `bigbox-v1-cm-2`

- `DEVICECODE_CONFIG_DIR`
  - Directory containing config JSON files
  - Default: `$DEVICECODE_ROOT/src/configs` if `src` exists, otherwise `$DEVICECODE_ROOT/configs`

- `DEVICECODE_LUA_BIN`
  - Lua interpreter command
  - Default: `luajit`

- `DEVICECODE_RUN_SECONDS`
  - How long each variant runs
  - Default: `120`

- `DEVICECODE_SAMPLE_SECONDS`
  - Memory sample interval in seconds
  - Default: `5`

- `DEVICECODE_LOG_DIR`
  - Output directory for logs
  - Default: `/tmp/devicecode-per-component-dropped-<UTC timestamp>`

## Example Runs

Use 60-second runs, sample every 2 seconds:

```sh
DEVICECODE_RUN_SECONDS=60 \
DEVICECODE_SAMPLE_SECONDS=2 \
./tests/integration/onbox/test-mem-usage/test-mem-usage-per-component-dropped.sh
```

Use a different config target and explicit log directory:

```sh
CONFIG_TARGET=bigbox-v1-cm-2 \
DEVICECODE_LOG_DIR=/tmp/mem-usage-run-1 \
./tests/integration/onbox/test-mem-usage/test-mem-usage-per-component-dropped.sh
```

Use plain Lua instead of luajit:

```sh
DEVICECODE_LUA_BIN=lua \
./tests/integration/onbox/test-mem-usage/test-mem-usage-per-component-dropped.sh
```

Run against a build tree (like on OpenWrt):

```sh
DEVICECODE_ROOT=../build \
./test-mem-usage-per-component-dropped.sh
```

## Output Structure

Inside `DEVICECODE_LOG_DIR`, each variant gets its own folder, for example:

- `all-enabled/`
- `drop-service-<service>/`
- `drop-manager-<manager>/`

Each variant folder contains:
- `devicecode.log` - stdout/stderr from `main.lua`
- `memory.log` - periodic `ps` snapshots for the process
- `services.csv` - services enabled for that run
- `<CONFIG_TARGET>.json` - config used in that run

The script also stores a copy of the original config as:
- `<log_dir>/<config_filename>.original`

## Input File Format

`all_services` and `all_managers` should contain one name per line.

Rules:
- Empty lines are ignored
- Lines starting with `#` are treated as comments

## Troubleshooting

- `missing file: ...`
  - Ensure `all_services`, `all_managers`, and config JSON exist.
  - If you exported `DEVICECODE_CONFIG_DIR` earlier, it may override auto-detection. Run `unset DEVICECODE_CONFIG_DIR` or set it explicitly to your build config path.
  - The script prints resolved paths at startup (`root`, `app_dir`, `config_dir`) so you can verify what it is using.

- `Lua interpreter not found: ...`
  - Install the interpreter or set `DEVICECODE_LUA_BIN`.

- `manager not present in hal.data: ...`
  - The manager listed in `all_managers` is not present in selected config JSON under `hal.data`.

- Script exits early
  - Check variant `devicecode.log` for runtime errors.

- `memory.log` has sample timestamps but no RSS/VSZ values
  - On BusyBox/OpenWrt, `ps -o ... -p ...` may be unsupported.
  - The script falls back to `/proc/<pid>/status` and records `rss` (`VmRSS`) and `vsz` (`VmSize`).
  - If still empty, verify `/proc/<pid>/status` is readable for the target process.

## Notes

- The script kills the test process after `DEVICECODE_RUN_SECONDS` if still running.
- Labels with `/` are sanitized to `_` for folder names.
- Config restoration is guarded by traps (`EXIT`, `INT`, `TERM`).
