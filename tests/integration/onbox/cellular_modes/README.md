# Cellular generation on-box test

Run inside the devcontainer against a physical box. The test makes three builds:

2G is excluded from all test requests because it can brownout the modem on this
hardware. Disable 2G in the modem's current modes before running: the preflight
also rejects an original configuration that would restore 2G later.

1. Configure a supported preferred/allowed pair different from the modem's current
   modes, upload the archive, restart Devicecode, and verify both `mmcli -J` and the
   local UI's `cellular_modes_applied` log record.
2. Configure a pair absent from the modem's supported combinations, rebuild,
   upload, and restart. Require a `warn` / `cellular_modes_unsupported` record from
   the local UI logs and verify that the previous modes remain unchanged.
3. Rebuild with the original preferred/allowed modes captured from `mmcli` before
   the test, upload, restart, and verify the original modes and application log.

Each phase waits for a new service PID, and each modem query rediscovers the
ModemManager ID by IMEI. Mode checks do not require a cellular data connection.
Log checks query both `GET /api/logs` (recent records) and
`GET /api/logs?boot=true` (initial boot capture), retaining matches across polls
so records for different modems need not appear in the same response. The boot
buffer can fill before all modem settings have been applied.

```bash
devcontainer exec --workspace-folder . bash -lc \
  'luajit tests/integration/onbox/cellular_modes/test_box.lua --ask-pass'
```

To choose the successful setting and restrict the test to one modem:

```bash
devcontainer exec --workspace-folder . bash -lc \
  'luajit tests/integration/onbox/cellular_modes/test_box.lua \
    --password-file /path/to/password-file --host root@172.28.100.1 \
    --imei 123456789012345 --preferred 4g --allowed 3g,4g'
```

Without a requested pair, each selected modem uses a different advertised pair,
preferring 4G-only and then 4G-preferred combinations and excluding 2G.
The test fails before deployment if a selected modem has no alternative or an
explicit requested pair is unsupported/already active. By default all enabled
modems are selected; use `--imei` to limit this. Unsupported pairs are generated
from the modem's actual capability list, using recognized generation strings.

The box must expose the local UI HTTP API and run Devicecode under its OpenWrt
service. The UI is queried from the box over SSH, defaulting to
`http://127.0.0.1:<configured-port>`; `--ui-url` overrides this box-local URL.
Shared options include `--runtime`, `--service`, `--target`, `--timeout`,
`--build-command`, `--ssh-key-auth`, and `--artifacts` (see `--help`). Missing box
tools (`mmcli`, `curl`, `ubus`) are installed through the shared dependency helper.

The test stages a copy of the box's effective config, adding IMEI overrides ahead
of physical-path entries. Source config files remain untouched. Success leaves
the new code running with the captured original modes explicitly configured in
both bootstrap and persistent config. It verifies generation settings, rather
than the modem's registration or connection state.

Original configs, raw `mmcli` snapshots, three build archives, phase syslogs,
local UI JSON responses, and `results.json` are saved in the private artifact
directory. The original runtime archive is kept in the remote test workspace.
On failure or interruption the runner collects diagnostics, restores the original
runtime/config files, and restores the captured modes directly through `mmcli`.
The service is restarted only if it was originally running. A failed rollback
reports the remote backup location for manual recovery.

Run the scenario checks without a box, credentials, or a build:

```bash
devcontainer exec --workspace-folder . bash -lc \
  'luajit tests/integration/onbox/cellular_modes/test_runner.lua'
```
