This repository contains the Lua version of [Jangala's](https://www.janga.la) `devicecode`, the
program that powers our Big Box and Get Box devices.

## Run devicecode (current runtime)

Use the devcontainer for dependencies (see [.devcontainer/devcontainer.json](.devcontainer/devcontainer.json)).

Runtime entrypoint is `src/main.lua`.

For on-box runs, copy both `src/` and `vendor/` to the target, then run devicecode from inside `src/`.

### Required environment variables

- `DEVICECODE_SERVICES`: Comma-separated services to start (example: `hal,config,monitor`).
- `DEVICECODE_CONFIG_DIR`: Directory that contains `<CONFIG_TARGET>.json` used at startup by HAL.
- `CONFIG_TARGET`: Base filename (without `.json`) for the config blob consumed by the config service.

### Optional environment variables

- `DEVICECODE_ENV`: `dev` or `prod` (defaults to `dev`).

### Run command

Run from `src/` so Lua module paths resolve correctly:

```bash
cd src
DEVICECODE_ENV=dev \
DEVICECODE_SERVICES='hal,config,monitor' \
DEVICECODE_CONFIG_DIR=/path/to/config/dir \
CONFIG_TARGET=config \
luajit main.lua
```
## Vendor Versions

`lua-fibers`: v0.8.1
`lua-trie`: v0.3
`lua-bus`: v0.4
