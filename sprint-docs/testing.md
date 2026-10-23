# Testing

## Shared support for physical box tests

Reusable Lua helpers live in `tests/integration/onbox/support/`. Run inside the
devcontainer and add `tests/integration/?.lua` and `src/?.lua` to `package.path`.
Imports use the `onbox.support.*` namespace.

| Module | Responsibility |
| --- | --- |
| `auth` | Hidden password entry and inherited password pipes. |
| `process` | Local commands, timeouts, captured output and background process groups. |
| `ssh` | Remote commands, authentication and uploads over SSH stdin. |
| `logs` | Continuous syslog capture, configurable filters and failure diagnostics. |
| `devicecode` | Dependencies, build/package/deploy, service control and config/runtime snapshots. |
| `runner` | Common arguments, private artifacts, signals, phases and cleanup. |
| `modem` | Discovery by IMEI, state waits, reset/rediscovery and guarded AT probing. |

`runner.parse_args()` accepts extra defaults, value options and boolean flags
for each test. `runner.open()` checks local tools, prompts when `--ask-pass` is
selected, and creates a session exposing `process`, `ssh` and `logs`.
The file-password and SSH-key modes use `--password-file` and `--ssh-key-auth`.

Use `box:phase(label, body)` for automatic log capture around a phase and
`box:run(body, hooks)` for the full test lifecycle. Register resource cleanup
with `box:defer(callback)`; callbacks run in reverse order, even after failure.
Failure hooks can collect extra diagnostics and perform test-specific rollback.
The shared runner does not choose when to deploy, reset devices or restore config.
Keep assertions and config transformations in the individual test.

Create `devicecode.new(box)` to manage a runtime. `prepare()` snapshots the
bootstrap and persistent config; `backup()` saves the runtime before mutation.
`build(label, config)` optionally replaces only the staged config. `deploy()`
stops the service and unpacks the archive, while `write_config()` updates both
config locations. `restore_runtime()` restores the snapshot and leaves the
service stopped so the caller can recover devices before restarting it.
`restore_persistent()` also restores the absence of an originally missing file.

`modem.new(box)` is optional for modem tests. It keeps selection policy in the
caller, waits by stable IMEI across changing mmcli IDs, and accepts a list of AT
commands for probing. Its helper briefly pauses ModemManager with a trap and
watchdog to resume it. AT assertions belong in the calling test.

Run the support checks without a box or password file:

```bash
devcontainer exec --workspace-folder . bash -lc \
  'luajit tests/integration/onbox/support/test.lua'
```

## PDP tests on a physical box

Run from the repository root:

```bash
devcontainer exec --workspace-folder . bash -lc \
  'luajit tests/integration/onbox/modem_pdp/test_box.lua'
```

The runner uses `root@172.28.100.1` and passes the root-level `boxkey` password
file directly to `sshpass`, without displaying or reading its contents itself.
Use `--host` and `--password-file` for another box, or `--ssh-key-auth` to use
your SSH agent/key. The box must already have its devicecode init service and
SIMs installed, with autoconnect enabled for the target Quectel modems.

To enter the password manually, run from an interactive terminal:

```bash
devcontainer exec --workspace-folder . bash -lc \
  'luajit tests/integration/onbox/modem_pdp/test_box.lua --ask-pass'
```

The password is requested once with echo disabled, held in memory for the run,
and passed to `sshpass` through a fresh anonymous pipe for each connection.
It is never placed in command arguments, environment variables, files or logs.
Terminal settings are restored on completion or interruption. `--ask-pass`,
`--password-file` and `--ssh-key-auth` are mutually exclusive.

The Lua runner executes inside the devcontainer, builds with `make build-all`, transfers the
build using tar over SSH, stops devicecode, resets and rediscovers the modems,
and restarts the service. It waits for every target modem to connect, then reads
`CGDCONT` and `CGACT` and checks every active CID against that modem's effective
config. It repeats the build/deploy/check cycle with `IP`, then `IPV4V6`.
The source configs are untouched; the build output preserves the box's existing
config and changes only the GSM PDP fields for the two test phases.

By default a final cycle restores the original per-modem config and checks it
again, keeping the new code deployed. `--keep-final-config` instead leaves the
second test config active. `--first`, `--second`, `--timeout`, `--runtime`,
`--service`, `--target`, and `--build-command` customize the run.

SFTP and picocom are unnecessary: the probe uses the built Lua AT transport.
ModemManager is briefly paused during read-only connected-state AT checks to
avoid competing serial readers, then resumed by a trap and watchdog. If required
box dependencies are missing, package installation is attempted even when
`opkg update` returns nonzero; the installed commands/modules are checked afterwards.

Private build, service, AT, and failure logs plus `results.json` are saved under
`tests/integration/onbox/modem_pdp/artifacts/pdp-box-<timestamp>` in the mounted
workspace (override with `--artifacts`). This directory is ignored by Git. Config/build
artifacts may contain credentials: the directory and files have private permissions.
A runtime backup is retained in `/tmp/devicecode-pdp-box-<timestamp>` on the
box. Failures print relevant logs and attempt to restore the original runtime
and config. The saved service stream is included even if the box's syslog ring
has rolled over. A rollback failure is reported explicitly with the backup path.

Offline checks for the runner:

```bash
devcontainer exec --workspace-folder . bash -lc \
  'luajit tests/integration/onbox/modem_pdp/test_runner.lua'
```

## Unit Testing

If we want to 100% unit test our code we will need to think about refactoring around local functions within modules that our
testing framework will not have scope of. If we want to test these functions we can either

- Add a global `_TEST` flag to our code that exports local functions at runtime, adds more internal complexity to every file that has local functions
- Export all functions and mark private functions with an underscore prefix
- Move local functions to either own file which will export them all

## Service Testing

### Hardware independent services

Service level testing will only require sending dummy signals through the central bus for simple services such as `Metrics` or `GSM`,
which has no module-level interactions with `HAL`. Some tests will be difficult as the reaction to a bus message may not be
exported outside of the service to be tested, therefore we cannot check validity of the reaction,
should we refactor the services to publish more state to the bus for this?

### Hardware dependant services

Hardware dependant services create an issue of emulating hardware events and interactions.

**Stateless Hardware Emulation**: Static emulation will allow us to run a command and always get back the same output independent of any other commands
or the wider state of the system. Statelessness is good for less complex integration tests and can be achieved by creating a set of shims, overwriting
Lua's package path and flushing Lua's package cache whenever a shim (or package dependant on a shim) needs to be loaded. This approach does become less appealing
if we wanted to chain together events in a responsive manner. Local state may be able to be held in our shim which could allow for a static loop of outputs each time a
command is called.

```lua
local tmodule = require "mod_folder.tmodule"
local tpack = require "pack_folder.tpack"

-- we expect non-shimed content
print("Unshimmed")
tmodule.run_test()
print(tpack.content())

-- changing path to priorities the loading of the shimmed module
package.path = "./harness/?.lua;" .. package.path

-- unload both modules
package.loaded["pack_folder.tpack"] = nil
package.loaded["mod_folder.tmodule"] = nil

local tmodule = require "mod_folder.tmodule"
local tpack = require "pack_folder.tpack"

-- both now show overriden content
print("\nBoth uncached")
tmodule.run_test()
print(tpack.content())
```

```bash
root
    main.lua
    /mod_folder
                  tmodule.lua
    /pack_folder
                  tpack.lua
    /harness
                  /pack_folder
                                tpack.lua (shim)
```

**Stateful Hardware Emulation**: This is significantly more complex and I severely doubt it would get done before the MVP deadline, if it did I still expect the
time spent developing it to be far too much when it could have been spent on functional code. Stateful emulation would allow us to create as faithful a model of different
hardware as possible, this means a command send in one module could impact the result of a command in another. I have no idea how to keep state of hardware between modules
apart from maybe maintaining ctx be passed as an argument for all commands and then we can sneak state in there.
