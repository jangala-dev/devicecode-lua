# Cellular generation on-box test

Run from the Devicecode Lua checkout inside the devcontainer against a bench box.

```sh
luajit tests/integration/onbox/cellular_modes/test_box.lua --ask-pass
```

The runner reads the box's effective GSM configuration and each selected
modem's live and advertised generation settings. It tests three phases:

1. Deploy an advertised pair that differs from both the modem's live modes and
   its configured pair, if set. Automatic selection prefers 4G-only, then
   combinations that prefer 4G. Require a `cellular_modes_applied` record and
   confirm the new hardware modes with `mmcli -J`.
2. Deploy a pair the modem doesn't advertise. Require a
   `cellular_modes_unsupported` warning and verify that the hardware still
   reports the phase-one pair.
3. Restore and verify each original pair that excludes 2G and was advertised.
   For other modems, record why restoration was skipped and deploy the
   phase-one pair again to clear the unsupported setting from the config.
   Verify final hardware modes for every selected modem and require an
   application record for each restoration.

2G can brown out modems on this hardware. A live baseline that includes 2G is
allowed. The runner excludes 2G from every request it deploys and stops before
deployment if a saved GSM policy explicitly configures 2G, since restarting
Devicecode could reapply that policy.

Each deployment uses IMEI overrides in a copy of the box's effective config
and waits for a fresh Devicecode process. Log checks use the structured UI
stream, with one recent and one boot snapshot if needed for startup records.
ModemManager IDs are resolved by IMEI.

By default all enabled modems are tested. Use `--imei` for one modem and
`--preferred` with `--allowed` to specify a supported pair.

```sh
luajit tests/integration/onbox/cellular_modes/test_box.lua --ask-pass \
  --imei 123456789012345 --preferred 4g --allowed 3g,4g
```

The box must run Devicecode under its OpenWrt service and expose the local UI
HTTP API. The runner uses the configured local UI port through SSH. Use
`--ui-url` to override it, or `--help` for runtime, service, build, SSH and
artifact options.

The private artifact directory holds the original config and runtime backup,
the build archives, raw modem snapshots, syslog, the UI stream, and
`results.json` with requested and observed modes by phase and any restoration skips. Teardown restores and verifies the original runtime and config. The test
restores original modem modes only if they were advertised and exclude 2G.

Run the scenario checks without a box or credentials:

```sh
luajit tests/integration/onbox/cellular_modes/test_runner.lua
```
