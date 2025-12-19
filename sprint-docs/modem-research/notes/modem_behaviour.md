# EG25-new modem behaviour (for dummy modem modelling)

This document summarises observed behaviour of an EG25 (new FW) modem from the mmcli/qmicli captures under
`scratchpad/modem-research/command_outputs/eg25-new`. It is intended to be the behavioural spec for the
test dummy modem.

## High-level modem states

There are two layers of "state":

- **mmcli modem state**: `modem.generic.state`
	- `failed` (e.g. `state-failed-reason = sim-missing`)
	- `disabled`
	- `registered`
	- `connected`

- **mmcli monitor state** (`mmcli -m X -w`, not fully captured here but implied by ModemManager docs and
	behaviour):
	- `enabling → enabled → searching → registered`
	- `registered → connecting → connected`
	- `connected → disconnecting → registered`
	- SIM removal can be represented as a synthetic `no_sim` state at the HAL level.

The HAL modem driver mainly looks at:

- `modem.generic.state` (for failed vs non-failed)
- `modem["3gpp"]["registration-state"]` (for registered vs not)
- SIM presence via `modem.generic.sim` (`"--"` vs a SIM D-Bus path)

## Data availability by state (mmcli)

All observations below are from the JSON snapshots under `eg25-new/state/*/mmcli`.

### `failed` (no SIM)

Example: `state/failed-no-sim/mmcli`.

- `mmcli -J -m` (modem.json)
	- Succeeds.
	- `modem.generic.state = "failed"`.
	- `modem.generic["state-failed-reason"] = "sim-missing"`.
	- `modem.generic.sim = "--"` (no SIM path).
	- `modem["3gpp"]["registration-state"] = "--"`.

- `mmcli --signal-get` (signal.json)
	- Fails, output is a plain error string, not JSON:
		- `error: modem has no extended signal capabilities`
	- The HAL driver never calls `get_signal()` in this state because it gates on `generic.sim ~= "--"`.

- `mmcli -J -i` (SIM info)
	- Not applicable; there is no SIM D-Bus path in `modem.generic.sim`.

### `disabled` (SIM present, modem disabled)

Example: `state/disabled/mmcli`.

- `mmcli -J -m`
	- Succeeds.
	- `modem.generic.state = "disabled"`.
	- `modem.generic.sim` is a SIM path (e.g. `/org/freedesktop/ModemManager1/SIM/2`).
	- `modem["3gpp"]["registration-state"] = "--"`.

- `mmcli --signal-get` (signal.json)
	- Succeeds and returns JSON with full `modem.signal` structure.
	- All access technologies (`5g`, `cdma1x`, `evdo`, `gsm`, `lte`, `umts`) are present, but all metrics
		are `"--"` (no meaningful signal values while disabled).

- `mmcli -J -i` (SIM info)
	- Succeeds when called with the SIM path from `modem.generic.sim`.

### `registered`

Example: `state/registered/mmcli`.

- `mmcli -J -m`
	- Succeeds.
	- `modem.generic.state = "registered"`.
	- `modem.generic.sim` is a SIM path.
	- `modem["3gpp"]["registration-state"] = "home"`.
	- `modem["3gpp"].operator-code` and `.operator-name` are populated (e.g. `23410`, `"O2 - UK"`).
	- `modem["3gpp"]["packet-service-state"] = "attached"`.
	- `modem.generic["access-technologies"]` contains `"lte"`.

- `mmcli --signal-get` (signal.json)
	- Succeeds with the same JSON structure as in `disabled`.
	- For this firmware, extended signal metrics are still all `"--"`; HAL falls back to QMI NAS for
		real RSRP/RSRQ/SNR via `nas-get-signal-info`.

- `mmcli -J -i` (SIM info)
	- Succeeds and returns SIM details.

### `connected`

Example: `state/connected/mmcli`.

- `mmcli -J -m`
	- Succeeds.
	- `modem.generic.state = "connected"`.
	- `modem.generic.bearers` contains one or more bearer paths.
	- `modem["3gpp"]["registration-state"] = "home"` and `packet-service-state = "attached"`.
	- `modem.generic["access-technologies"]` still includes `"lte"`.

- `mmcli --signal-get` (signal.json)
	- Same structure as `disabled`/`registered` and still all `"--"` for extended metrics.

## Command behaviour by state (mmcli)

From the transition captures under `eg25-new/transitions`:

- `mmcli -m X -e` / `-d` while **modem is in `failed` state**:
	- Both enable and disable fail with `WrongState` errors, e.g.:
		- `error: couldn't enable the modem: 'GDBus.Error:org.freedesktop.ModemManager1.Error.Core.WrongState: modem in failed state'`
		- `error: couldn't disable the modem: 'GDBus.Error:org.freedesktop.ModemManager1.Error.Core.WrongState: modem in failed state'`
	- Dummy modem should refuse to change state when `enable`/`disable` are called in `FAILED`.

- `mmcli -m X -e` / `-d` in **normal states**:
	- From `connected` → `mmcli -d` succeeds and drives state towards `disabled`.
	- From `disabled` → `mmcli -e` will eventually drive the monitor state sequence
		`enabling → enabled → searching → registered` (not all steps are captured here but observed in HAL).

## Data availability by state (qmicli)

Using captures under `eg25-new/state/*/qmicli`.

### UIM card status (SIM presence)

- **Disabled (SIM present)** – `state/disabled/qmicli/uim-get-card-status.txt`:
	- Slot [1]: `Card state: 'present'`.
	- Full application list is reported (`Application [1]` usim ready, etc.).
	- This is the "healthy SIM inserted" baseline.

- **Failed, no SIM** – `state/failed-no-sim/qmicli/uim-get-card-status.txt`:
	- Slot [1]: `Card state: 'error: no-atr-received (3)'`.
	- No applications are listed.
	- This aligns with `modem.generic.state = "failed"` and `state-failed-reason = "sim-missing"`.

### UIM read transparent (GID1)

- In non-failed, SIM-present states, `uim-read-transparent` returns a `Card result` and `Read result`
	section with a hex string for GID1.
- In `failed`/no-SIM, this command is expected to fail or return no meaningful `Read result`.
	- The HAL only calls `uim_get_gids()` when `modem.generic.state ~= 'failed'`.

### NAS info (home network + signal)

- `nas-get-home-network`:
	- Only meaningful when `modem["3gpp"]["registration-state"] ~= "--"` (i.e. registered/connected).
	- Returns MCC/MNC and description; the HAL uses this for MCC/MNC and operator info.

- `nas-get-signal-info`:
	- Returns LTE `RSSI`, `RSRQ`, `RSRP`, `SNR` when attached/registered/connected.
	- This is the primary source of usable signal metrics for EG25-new, given that
		`mmcli --signal-get` lacks extended values.

## SIM power / presence behaviour

From experiments scripted in `collect_modem_transitions.sh` and the user observations:

- **SIM power-cycle with SIM inserted** (`qmicli --uim-sim-power-off=1` then `--uim-sim-power-on=1`):
	- Causes the modem to effectively **disappear and reappear** from ModemManager's point of view.
		- In practice this looks like a remove/add cycle on the USB device and a new D-Bus modem path.
	- A modem that was in `failed` will come back as a **fresh modem in `disabled` state** once the SIM
		is powered back on.
	- This is the primary recovery path out of `failed(sim-missing)`.

- **SIM removal** (physical SIM pulled out):
	- Results in loss of SIM and subsequent `sim-missing` behaviour.
	- In practice, the modem is observed to disappear and reappear from ModemManager, returning in a
		`failed` state with `state-failed-reason = "sim-missing"` and `generic.sim = "--"`.

For dummy modelling this implies:

- When SIM power is toggled **off then on while a SIM is inserted**:
	- Emit a modem `(-)` removal event on the mmcli monitor bus, then a `(+)` add event with a **new**
		modem address.
	- Reset the modem state machine to `DISABLED` with no bearer/registration state.
	- Clear any previous failure reason.

- When a SIM is **removed**:
	- Emit a modem `(-)` removal event, then a `(+)` add event with a (potentially) new modem address.
	- Recreate the modem in `FAILED` state with `state-failed-reason = "sim-missing"` and
		`generic.sim = "--"`.

## Driver-facing behavioural rules (what the dummy must respect)

Summarising what the HAL modem driver expects from the underlying tools:

- `get_modem_info()` (mmcli -J -m):
	- Always succeeds in all states and reports at least:
		- `modem.generic.state`
		- `modem["3gpp"]["registration-state"]`
		- `modem.generic.sim` (SIM path or `"--"`)
		- Driver/mode/model fields (plugin, model, revision, drivers, ports, primary-port, equipment-identifier).

- `get_sim_info()` (mmcli -J -i):
	- Only called when `modem.generic.sim ~= "--"`.
	- Should fail (or not be callable) when there is no SIM path.

- `get_signal()` (mmcli --signal-get):
	- Only called when `modem.generic.sim ~= "--"`.
	- May legitimately fail or return no valid signals; driver will then report an error and move on.
	- In `failed`/no-SIM state, the dummy should mimic `mmcli` by returning a non-JSON error string so
		any accidental call fails cleanly.

- `get_nas_info()` / `nas_get_rf_band_info()` / `uim_get_gids()` (QMI):
	- `get_nas_info()` is only called when `modem["3gpp"]["registration-state"] ~= "--"`.
	- `uim_get_gids()` is only called when `modem.generic.state ~= 'failed'`.
	- The dummy should enforce the same gating and either return errors or empty results when invoked
		outside these conditions.

- `enable()` / `disable()` (mmcli -e/-d):
	- Must fail with a `WrongState`-style error when current state is `FAILED`.
	- Otherwise should drive the state-machine transitions described above via the monitor stream.

These rules, plus the state/command availability matrices above, are what the dummy modem should
implement to behave like a realistic EG25-new instance.

## QMI slot monitor

The HAL uses `qmicli --uim-monitor-slot-status` (wrapped by `monitor_slot_status()` and parsed by
`utils.parse_slot_monitor`) to detect SIM insertion/removal events at runtime.

- The dummy modem will need to emit slot-monitor lines that `parse_slot_monitor` can interpret as
	transitions between "present" and "not present".
- Capturing some real `--uim-monitor-slot-status` output for:
	- SIM present,
	- SIM removed,
	- SIM power-cycled,
	would be useful to ensure the dummy's slot-monitor stream matches reality.
