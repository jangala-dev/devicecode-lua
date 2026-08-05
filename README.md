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
## Build

Run `make build-all` to copy sources into `build/` and inject secrets into config files.

### Secret substitution

Config files under `src/configs/` may contain `$VAR` placeholders for sensitive values (credentials, URLs, etc.). During `make build-all`, these are replaced in the **build output only** — `src/` is never modified.

Create `.env.secret` in the repository root with the following keys:

```
SWITCH_USERNAME=
SWITCH_PASSWORD=
UNIFI_ADDRESS=
CLOUD_URL=
USER_SALT=
```

`.env.secret` is listed in `.gitignore` and must never be committed. If the file is absent, `make build-all` will print a warning and leave placeholders unreplaced.

## Vendor Versions

`lua-fibers`: v0.8.1
`lua-trie`: v0.3
`lua-bus`: v0.4
