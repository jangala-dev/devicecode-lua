# Physical box tests

Run from a Devicecode Lua devcontainer with a management connection to a bench
box. Initialize the build dependencies with `make env` if needed. These tests
deploy the current checkout. Run them with wired management access when testing
cellular connectivity.
Run one test at a time. Confirm the route and identity at the prompt.
New modem scenarios should exercise both modems by default. A scenario such
as autoconnect startup can select modems by the feature it tests.

```sh
luajit tests/integration/onbox/modem_pdp/test_box.lua --ask-pass --host root@172.28.100.1
luajit tests/integration/onbox/cellular_modes/test_box.lua --ask-pass --host root@172.28.100.1
luajit tests/integration/onbox/modem_startup/test_box.lua --ask-pass
luajit tests/integration/onbox/modem_reset/test_box.lua --ask-pass
luajit tests/integration/onbox/modem_autoconnect_off/test_box.lua --ask-pass
luajit tests/integration/onbox/modem_recovery/test_box.lua --ask-pass
luajit tests/integration/onbox/speedtest_compare/test_box.lua --ask-pass
```

The PDP test requires configured, autoconnecting Quectel modems and SIMs
that support the requested PDP types. See the [cellular modes guide](cellular_modes/README.md)
for modem selection and the 2G restriction. All runners accept `--artifacts PATH`
to choose a fresh directory for the run.

After success, failure or a handled interruption, the runner restores the original
runtime and configuration before restarting Devicecode if it was running before
the test. It compares the restored runtime contents and checks the saved config
or its original absence. A mismatch fails the run. The private artifacts include
the original backup and `restore-verification.log`.

A phase keeps raw syslog in `*-service.log` and saves SSH errors separately in
`*-service.log.stderr`. The PDP check observes only lines between the acknowledged
tested-runtime markers. Its `modem-watch-*.log` files contain ModemManager object
notifications, which trigger inventory checks. The runner also checks periodically
for state and AT-port changes on existing objects. It falls back to snapshots
if the watch ends before the test completes.

Cellular modes saves the structured UI stream as `*-ui-logs.sse`. If it
needs snapshots, it saves them as `*-ui-recent-logs.json` and
`*-ui-boot-logs.json`. Both scenarios write `results.json`
with completed phases. For debugging, share the terminal result, results JSON,
relevant phase logs, and any matching stderr or failure logs. Review them for
device identifiers and credentials first. The artifact directory also holds
runtime backups and configuration snapshots for local recovery.

Modem startup tests every detected modem configured for autoconnect. Use
`--imei` to limit a troubleshooting run to one modem. The test stops
Devicecode and confirms all selected modems are disabled before startup. It
requires a GSM `connected` event and independent ModemManager confirmation
for every selected modem. A full run fails if the modem inventory is
incomplete. `results.json` records the state sequence per modem. Intermediate
states may vary with modem, network, and firmware.

Modem reset requires at least two detected modems in a full run and checks
that every detected modem is connected before testing. With Devicecode running,
it resets them one at a time and waits for the verified replacement to
reconnect before resetting the next modem. HAL and GSM must each report removal
followed by reappearance for the modem under test. ModemManager must confirm the same IMEI
on the new object reported by HAL. `results.json` records each modem's events
and object IDs. The test reads info-level logs in the default `operator` monitor
profile. Use `--imei IMEI` for a single-modem troubleshooting run.

Modem autoconnect off requires both modems to be detected. It turns off GSM
autoconnect in the temporary config, stops Devicecode and resets all detected
modems. ModemManager must report new objects in the disabled state before
Devicecode starts. After GSM reports all modems disabled, the runner observes
them for 60 seconds by default. `--observe-seconds SECONDS` changes the duration.
The runner checks GSM logs, ModemManager daemon logs, and a ModemManager state
stream per modem for any departure from disabled. It confirms the modem state
and identity in a final snapshot and reads each monitor through its acknowledged
end marker.
`results.json` and `modem-state-*.log` contain the per-modem evidence.

Modem recovery timing requires both modems to start connected with their WAN
members online. It resets them one at a time. Each result records the new HAL
modem registration, GSM connected, and NET reporting that modem's interface
online. The runner calculates all three elapsed intervals in milliseconds
using the timestamps recorded when each service emits its event. `--max-connected-seconds` and
`--max-online-seconds` set optional limits measured from reappearance.
`--imei IMEI` is available for single-modem troubleshooting.

Speedtest comparison temporarily asks Devicecode for fresh download results on
all WAN paths. It checks signed Mbps difference, absolute Mbps difference and
percentage difference against the Devicecode rate for each eligible interface.
The two downloads must use the same OpenWrt interface and IPv4 source address.
Interfaces excluded for being offline or unavailable are listed in the output
and `results.json`. Use `--settle-seconds` to adjust the 60-second WAN discovery
window and `--server-id` to use the same external server for each CLI run.
The discovery window starts after NET reports an apply completion or a fresh
Devicecode speedtest result. Any NET apply failure is recorded in `results.json`.

The comparison stages a checksum-verified LibreSpeed CLI (Rust) release in the
box's `/tmp` tmpfs and removes its workspace during cleanup. The CLI sets both the
interface binding and the mwan3 firewall mark on its download sockets. Before deployment it
checks that OpenWrt can parse the network and firewall config and that there is
enough free storage for the candidate and the original runtime used in rollback. The runner
stops the test Devicecode process before running CLI downloads sequentially,
then verifies the restored runtime and config. The CLI and Devicecode use
different endpoints and transfer limits, so differences are reported without a
pass/fail tolerance.

Run the offline framework and scenario checks without a box:

```sh
TEST_FILTER=onbox.support make test
luajit tests/integration/onbox/modem_pdp/test_runner.lua
luajit tests/integration/onbox/cellular_modes/test_runner.lua
luajit tests/integration/onbox/modem_startup/test_runner.lua
luajit tests/integration/onbox/modem_reset/test_runner.lua
luajit tests/integration/onbox/modem_autoconnect_off/test_runner.lua
luajit tests/integration/onbox/speedtest_compare/test_runner.lua
```

The modem reset offline runner also exercises recovery timing.
