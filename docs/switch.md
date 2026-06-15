# Big Box PoE/VLAN switch integration

This document records the switch discovery work carried out for the Big Box PoE/VLAN switch. It is intended to prevent the HTTP UI/API discovery phase from having to be repeated when the `rtl8380m_http` provider is implemented.

The target device explored was reachable at `http://192.168.1.1/` with the factory `admin` account. The Big Box configuration uses the same provider class but will normally point at the managed switch address configured for the appliance, currently `http://172.28.100.9/` in `src/configs/bigbox-v1-cm-2.json`.

The initial provider should remain read-only. Write/control support should be added only after the read-side parser is stable and tests cover the exact POST shapes for VLAN, PoE, port and save operations.

## Role in the Devicecode architecture

The switch is modelled below the appliance services as a HAL wired provider:

```text
HAL wired provider: rtl8380m_http
Provider id:        switch-main
Initial mode:       read_only
Big Box role:       PoE/VLAN switch, including the CM5 uplink trunk
```

The boundary should remain:

```text
manufacturer HTTP UI/API
  -> services.hal.backends.wired.providers.rtl8380m_http
  -> HAL wired-provider capability
  -> Device component switch-main
  -> Wired service validation and public appliance state
```

The manufacturer-specific details in this document must not leak into `wired`, `device`, `net` or `ui`. Above HAL, callers should see semantic surfaces, link state, VLAN attachment state, PoE state and topology.

The existing stub is at:

```text
src/services/hal/backends/wired/providers/rtl8380m_http.lua
```

It already defines the intended provider operations:

```text
fetch_snapshot_op(req)
snapshot_op(req)
watch_op(req)
apply_attachments_op(req)
set_poe_op(req)
bounce_op(req)
terminate(reason)
```

Phase 1 should implement `fetch_snapshot_op`, `snapshot_op` and `watch_op`. Phase 1 control methods should continue to return `read_only`.

## Discovery artefacts

The exploration was performed with `tool/switch-explore-v7.lua`, which:

- used `lua-http` for ordinary pages;
- used a raw `curl --http1.0` fallback for switch CGI responses that `lua-http` could not parse;
- performed only the login POST;
- did not submit VLAN, PoE, port, save, reboot or other configuration writes;
- fetched the language file, UI templates and read-side CGI endpoints.

The successful authenticated crawl reported:

```text
fetched:              360
status 200:           290
status 404:           62
status 502:           8
discovered endpoints: 911
forms:                157
interesting forms:    79
```

The `report.json` in the run identifies the login method as `rtl8380-rsa` with `basic_auth_enabled = false`. The console labelled the login as a “success guess”, but the saved `home_loginStatus` response returned `status = "ok"`, so the session should be treated as authenticated.

## HTTP and session behaviour

### Entry page

The root page is only a JavaScript redirect:

```html
window.location.href="login.html?ver=" + fileVer;
```

Do not treat `/` as the application shell. The real entry points are `login.html` and, after authentication, `home.html?ver=<timestamp>`.

### API pattern

The switch UI is a browser-side JavaScript application using a CGI command API.

Read endpoints use:

```text
GET /cgi/get.cgi?cmd=<command>
```

Write endpoints use:

```text
POST /cgi/set.cgi?cmd=<command>
```

The UI JavaScript defines these in `js/url.js`. Relative paths in templates are commonly `../cgi/...`, but the driver should normalise all commands to root-relative `/cgi/...`.

### lua-http interop issue

`lua-http` successfully fetched HTML and JavaScript. It failed on many `/cgi/get.cgi?...` responses while reading the response header, with:

```text
read_header: Invalid or incomplete multibyte or wide character
```

The same CGI endpoints returned usable `HTTP/1.1 200 OK` responses via `curl --http1.0`. The production driver uses the normal HTTP capability with an explicit, opt-in response parser:

```text
response_parser = "legacy-http1-close"
```

This parser is implemented below `services/http`, not in HAL.  It is a strict, bounded HTTP/1.0 close-delimited client mode for embedded devices whose response headers are rejected by `lua-http`.  It is only admitted by HTTP policy when `allowed_response_parsers["legacy-http1-close"] == true`, requires `timeout_s`, is limited to `http://` GET/POST/HEAD, enforces a maximum response size, requires a valid HTTP status line, does not follow redirects, and does not expose raw sockets to callers.

The provider should not shell out to `curl` in production.

### Cookies

The only cookie name seen during exploration was:

```text
cookie_language
```

The explorer set:

```text
cookie_language=defLang_en
```

The authenticated CGI session did not expose an obvious session cookie in the captured metadata. It may be IP-bound, implicit in the HTTP session, or encoded in a way the current explorer did not record. The first provider implementation should preserve all `Set-Cookie` headers and replay all cookies, even if only `cookie_language` is observed.

## Login flow

The switch does not use HTTP Basic auth. `home_login` returns a public RSA modulus and the browser encrypts the password before calling `home_loginAuth`.

### Step 1: fetch login information

```text
GET /cgi/get.cgi?cmd=home_login
```

Observed payload:

```json
{
  "data": {
    "title": "RTL8380",
    "httpsEnbl": false,
    "https": false,
    "modulus": "C058176034298BF78CD4766CB9B044262E6F17C86542CB5320CB39FAFB1460200806430561963F2D397756173065503E5540756A69698CE7F1FD67A2506F6DC27C6C736F5A134B65150630ED70E57147CDEBD90511BF2305C844ACC4DB1A68FC05CAD37B3147908D8C3ABDD70DEFCC06C76E1E4B5F7D361A549A35F30E637C25",
    "logoUrl": "logo_login_en.png"
  }
}
```

The browser-side exponent is `10001` hex, i.e. 65537.

### Step 2: encrypt the password

The UI includes:

```text
/js/crypt/jsbn.js
/js/crypt/prng4.js
/js/crypt/rng.js
/js/crypt/rsa.js
/js/crypt/base64.js
```

The explorer reproduced the login by using the modulus from `home_login` and RSA public-key encryption of the password. The v6/v7 successful attempt used the Backbone-style JSON body with a string key.

Implementation note: keep the RSA login implementation small and isolated. It should be covered by a fixture test using the observed modulus and password `admin`, but do not commit real operational credentials.

### Step 3: submit login

```text
POST /cgi/set.cgi?cmd=home_loginAuth&dummy=<integer>
```

The driver should send browser-like headers:

```text
Origin:           http://<switch-host>
Referer:          http://<switch-host>/login.html
X-Requested-With: XMLHttpRequest
Accept:           application/json, text/javascript, */*; q=0.01
Content-Type:     application/json; charset=UTF-8
```

The exact request body should be confirmed in implementation tests from the explorer code and, if required, browser capture. The current explorer called this form successfully enough for `home_loginStatus` to become `ok`.

### Step 4: confirm login

```text
GET /cgi/get.cgi?cmd=home_loginStatus
```

Before login this returned:

```json
{ "data": { "status": "authing" } }
```

After the successful login this returned:

```json
{ "data": { "status": "ok" } }
```

The provider should not proceed with a snapshot if `home_loginStatus` is not `ok`.

## Core read commands for the read-only provider

Use this minimum set for `fetch_snapshot_op`:

| Purpose | Command |
|---|---|
| Login information | `home_login` |
| Login state | `home_loginStatus` |
| Model, user, ports, LAG names and menu tree | `home_main` |
| Front-panel physical layout | `panel_layout` |
| Live physical link state | `panel_info` |
| System identity | `sys_sysinfo` |
| CPU/memory telemetry | `sys_cpumem` |
| Port admin and operational state | `port_port` |
| Port counters | `port_cnt` |
| Port bandwidth utilisation | `port_bwutilz` |
| LAG management state | `lag_mgmt` |
| VLAN list | `vlan_create` |
| Per-VLAN membership | `vlan_conf` |
| Per-port VLAN settings | `vlan_port` |
| Per-port admin/oper VLAN strings | `vlan_membership` |
| PoE state | `poe_poe` |
| PoE edit defaults | `poe_poeEdit` |
| PoE schedules | `poe_poeTimer` |
| Local LLDP identity | `lldp_local` |
| LLDP neighbours | `lldp_neighbor` |

The first implementation can omit counters, bandwidth, LAG and LLDP from the semantic snapshot if necessary, but it should save the raw payloads in diagnostics so the driver can be extended without another discovery run.

## Device identity observed

From `home_login`, `home_main` and `sys_sysinfo`:

```text
model:             RTL8380
title:             RTL8380
hostname:          Switch
serial:            0123456789
system object ID:  1.3.6.1.4.1.27282.1.1
MAC:               00:E0:5C:24:16:39
management IPv4:   192.168.1.1
firmware:          1.0.0.6
firmware date:     Mar 27 2023 - 10:08:11
loader:            3.6.7.55090
loader date:       Mar 27 2023 - 10:05:15
HTTP enabled:      true
HTTPS enabled:     false
Telnet enabled:    false
SSH enabled:       false
SNMP enabled:      false
```

The driver should not key behaviour on this exact firmware version unless a compatibility check proves that the API differs by version. Store these values in `identity` and `telemetry`.

## Port model

`home_main` listed 18 switch surfaces:

```text
GE1..GE10
LAG1..LAG8
```

`panel_info` listed 10 physical ports. GE1-GE8 are copper and PoE-capable. GE9-GE10 are fibre/uplink-facing and not PoE-capable in the PoE payload.

Observed live state during discovery:

```text
GE1:  link up, speed 100M, full duplex, PoE not delivering
GE2-GE8: link down, PoE not delivering
GE9-GE10: fibre, link down
LAG1-LAG8: logical surfaces; no direct physical-panel entries
```

### Port fields

From `port_port` and `panel_info`:

| Field | Meaning | Notes |
|---|---|---|
| `descp` | Port description | empty in discovery |
| `type` | UI language expression for media | e.g. `lang('port','txtMediaCopper',[1000])` |
| `adminStatus` | boolean administrative enable | true means enabled |
| `adminSpeed` | configured speed | `lang('port','lblAuto')` or raw edit values such as `auto`, `100`, `1000` |
| `adminDuplex` | configured duplex | `auto`, `full`, `half` on edit path |
| `adminFlowCtrl` | configured flow control | language expression or raw edit value |
| `operStatus` | boolean link state | true means up |
| `operSpeed` | operational speed string | e.g. `100M` |
| `operDuplex` | operational duplex language expression | full/half |
| `operFlowCtrl` | boolean operational flow control | true means on |
| `panel_info.speed` | numeric speed string when up | e.g. `100` |
| `panel_info.dupFull` | boolean duplex when up | true means full |
| `panel_info.media` | media override | `fiber` for GE9/GE10 |
| `panel_info.poelinkup` | PoE delivery indicator | false during discovery |

### Port code-to-label mappings

| Field | Raw value | UI label | Provider label |
|---|---:|---|---|
| `adminStatus` | `true` | `Enabled` | `enabled` |
| `adminStatus` | `false` | `Disabled` | `disabled` |
| `operStatus` | `true` | `Up` | `up` |
| `operStatus` | `false` | `Down` | `down` |
| `operDuplex` | `lang('port','txtDuplexFull')` | `Full` | `full` |
| `operDuplex` | `lang('port','txtDuplexHalf')` | `Half` | `half` |
| `type` | `lang('port','txtMediaCopper',[1000])` | `1000M Copper` | media `copper`, max `1000` |
| `type` | `lang('port','txtMediaFiber',[1000])` | `1000M Fiber` | media `fiber`, max `1000` |
| `adminSpeed` | `lang('port','lblAuto')` | `Auto` | `auto` |
| `adminSpeed` edit value | `auto_10` | `Auto(10M)` | `auto_10` |
| `adminSpeed` edit value | `auto_100` | `Auto(100M)` | `auto_100` |
| `adminSpeed` edit value | `auto_1000` | `Auto(1000M)` | `auto_1000` |
| `adminSpeed` edit value | `auto_10_100` | `Auto(10M/100M)` | `auto_10_100` |
| `adminSpeed` edit value | `10`, `100`, `1000`, `10000` | forced speed | numeric forced speed |
| `adminDuplex` edit value | `auto` | `Auto` | `auto` |
| `adminDuplex` edit value | `full` | `Full` | `full` |
| `adminDuplex` edit value | `half` | `Half` | `half` |
| `adminFlowCtrl` edit value | `auto` | `Auto` | `auto` |
| `adminFlowCtrl` edit value | `enable` | `Enable` | `enable` |
| `adminFlowCtrl` edit value | `disable` | `Disable` | `disable` |

## VLAN model

The switch exposes three useful read-side VLAN views:

```text
vlan_create      configured VLAN list
vlan_conf        per-selected-VLAN membership for each port/LAG
vlan_port        per-port VLAN mode, PVID, accepted-frame type and TPID
vlan_membership  per-port admin/oper VLAN membership strings
```

Observed state during discovery:

```text
Configured VLANs: VLAN 1, name "default"
Default VLAN:     1
All ports/LAGs:   mode 2, PVID 1, accFrameType 0, ingressFilter true, uplink false, TPID 0x8100
Membership:       VLAN 1 untagged and PVID on all ports and LAGs
```

### VLAN mode mappings

From `html/vlan_vlan_port.html`, `html/vlan_vlan_portEdit.html` and `lang/defLang.js`:

| `vlan_port.mode` | UI label | Provider label |
|---:|---|---|
| `0` | `Hybrid` | `hybrid` |
| `1` | `Access` | `access` |
| `2` | `Trunk` | `trunk` |
| `3` | `Tunnel` | `tunnel` |

### Accepted-frame mappings

| `vlan_port.accFrameType` | UI label | Provider label |
|---:|---|---|
| `0` | `All` | `all` |
| `1` | `Tag Only` | `tag_only` |
| `2` | `Untag Only` | `untag_only` |

### Per-VLAN membership mappings

From `html/vlan_vlan_configuration.html`:

| `vlan_conf.membership` | UI label | Provider label |
|---:|---|---|
| `0` | `Excluded` | `excluded` |
| `2` | `Tagged` | `tagged` |
| `3` | `Untagged` | `untagged` |

`forbidden` is a separate boolean column. `pvid` is also a separate boolean column.

### VLAN membership string grammar

`vlan_membership` returns strings such as:

```text
1UP
```

The UI editor logic in `html/vlan_vlan_membershipEdit.html` uses these suffixes:

| Suffix | Meaning |
|---|---|
| `T` | tagged |
| `U` | untagged |
| `F` | forbidden |
| `P` | PVID |

Examples:

```text
1UP   VLAN 1, untagged, PVID
8T    VLAN 8, tagged
32F   VLAN 32, forbidden
100U  VLAN 100, untagged
```

The editor uses `4095P` as a placeholder when a hybrid port has no real PVID assigned. Do not treat `4095P` as a normal configured VLAN.

### VLAN edit constraints discovered from UI logic

These constraints matter for the later control path:

- trunk ports must have one untagged/native VLAN;
- access ports must have one untagged/access VLAN;
- hybrid ports must have a PVID;
- only one real PVID may be selected;
- tunnel mode disables excluded and tagged membership choices in the configuration view;
- for non-hybrid modes, selecting untagged automatically marks the VLAN as PVID.

Do not implement writes until these constraints are represented in unit tests.

## PoE model

PoE is exposed through:

```text
poe_poe       summary and per-port PoE state
poe_poeEdit   edit defaults for selected port(s)
poe_poeTimer  per-port timer schedule
```

`poe_poe` includes eight ports, corresponding to GE1-GE8. GE9-GE10 do not appear in the PoE port list.

Observed PoE state during discovery:

```text
System power:       0 W
System temperature: 28 C
GE1-GE8:            enabled, off/not delivering, type N/A, level 0, power limit 0, watchdog false
```

### PoE fields and units

From `html/poe_port.html`:

| Field | UI behaviour | Provider handling |
|---|---|---|
| `devPower` | displayed as `devPower / 1000` W | payload unit is mW; expose watts and raw mW |
| `devTemp` | displayed as C | expose Celsius |
| `portEnable` | `Enabled` / `Disabled` | administrative enable boolean |
| `portStatus` | `On` / `Off` | delivery state boolean |
| `portType` | displayed as raw string or `N/A` | preserve raw |
| `portLevel` | displayed as numeric or `N/A` | preserve raw, optionally expose class-like numeric field |
| `portPower` | displayed as `portPower / 1000` W | payload unit is mW if present |
| `portVoltage` | displayed as V | preserve numeric volts if present |
| `portCurrent` | displayed as mA | preserve numeric mA if present |
| `watchDog` | controls whether watchdog column is shown | device/feature-level boolean |
| `portWatchDog` | shown when `watchDog` is enabled | per-port watchdog boolean if present |
| `portPowerLimit` | edit field | preserve raw until control path is implemented |

### PoE mappings

| Field | Raw value | UI label | Provider label |
|---|---:|---|---|
| `portEnable` | `true` | `Enabled` | `enabled` |
| `portEnable` | `false` | `Disabled` | `disabled` |
| `portStatus` | `true` | `On` | `delivering` or `on` |
| `portStatus` | `false` | `Off` | `off` |

For consistency with the existing provider stub, map to:

```lua
poe = {
  state = "off" | "delivering" | "fault" | "unknown",
  enabled = true | false,
  watts = <number or nil>,
  raw = <original port payload>,
}
```

The UI did not expose a distinct fault code in the captured state. If future payloads contain additional status values, preserve the raw value and set `state = "unknown"` until mapped.

## LLDP and topology

Useful commands:

```text
lldp_local
lldp_neighbor
lldp_localDetail
lldp_neighborDetail
lldp_statistic
```

Observed local LLDP state:

```text
chassisType: Mac Address
chassisId:   00:E0:5C:24:16:39
sysName:     Switch
sysDescp:    RTL8380
capability:  L3
port status: Tx and Rx, MED enabled, all ten physical ports
```

Observed neighbour state:

```json
{ "data": { "null": true } }
```

The first driver can expose an empty topology when no neighbours are present. Later, use LLDP neighbour data to enrich `topology` rather than to override configured protected surfaces.

## Commands likely needed for the control phase

From `js/url.js`, the commands relevant to VLAN/PoE/port control are:

### Login and session

```text
get: home_login
set: home_loginAuth
get: home_loginStatus
set: home_logout
set: home_save
```

### Port

```text
get: port_port
get: port_portEdit
set: port_portEdit
get: port_jumbo
set: port_jumbo
get: port_eee
get: port_eeeEdit
set: port_eeeEdit
```

### LAG

```text
get: lag_mgmt
set: lag_mgmt
get: lag_mgmtEdit
set: lag_mgmtEdit
get: lag_port
get: lag_portEdit
set: lag_portEdit
get: lag_lacp
set: lag_lacp
get: lag_lacpEdit
set: lag_lacpEdit
```

### VLAN

```text
get: vlan_create
set: vlan_create
set: vlan_edit
set: vlan_del
get: vlan_conf
set: vlan_conf
get: vlan_port
get: vlan_portEdit
set: vlan_portEdit
get: vlan_membership
get: vlan_membershipEdit
set: vlan_membershipEdit
```

### PoE

```text
get: poe_poe
get: poe_poeEdit
set: poe_poeEdit
get: poe_poeTimer
set: poe_poeTimer
```

### Save and reboot

```text
set: home_save
reboot page: diag_reboot.html
management save page: mgmt_cfg_save.html
```

Do not call save or reboot from the provider until there is a higher-level operation and explicit policy for it.

## Normalised snapshot shape

A first read-only `fetch_snapshot_op` should return a shape close to:

```lua
{
  ok = true,
  provider_id = "switch-main",
  mode = "read_only",
  writable = false,
  status = {
    state = "available",
    available = true,
    driver = "rtl8380m_http",
    base_url = "http://.../",
    authenticated = true,
    response_parser = "legacy-http1-close",
  },
  identity = {
    model = "RTL8380",
    hostname = "Switch",
    serial = "0123456789",
    mac = "00:E0:5C:24:16:39",
    firmware = "1.0.0.6",
    firmware_date = "Mar 27 2023 - 10:08:11",
    loader = "3.6.7.55090",
    loader_date = "Mar 27 2023 - 10:05:15",
    management_ipv4 = "192.168.1.1",
  },
  surfaces = {
    GE1 = {
      provider_surface_id = "GE1",
      kind = "switch-port",
      capabilities = { trunk = true, access = true, poe = true },
      media = { type = "copper", max_speed_mbps = 1000 },
      link = { state = "up", speed_mbps = 100, duplex = "full" },
      attachment = {
        mode = "trunk",
        pvid = 1,
        accept_frame_type = "all",
        ingress_filter = true,
        uplink = false,
        tpid = "0x8100",
        admin_vlans_raw = "1UP",
        oper_vlans_raw = "1UP",
        admin_vlans = {
          { vlan = 1, untagged = true, pvid = true },
        },
      },
      poe = {
        state = "off",
        enabled = true,
        watts = nil,
        raw = {},
      },
    },
  },
  topology = {
    lldp = {
      local = {},
      neighbours = {},
    },
  },
  telemetry = {
    cpu_percent = 3,
    memory_percent = 61,
    poe = { dev_power_watts = 0, dev_temp_c = 28 },
  },
  raw = {
    -- optional diagnostics; keep bounded and redacted
  },
}
```

## Raw and curated projection

The provider snapshot is carried through HAL and Device as several separate retained state facts.  The HAL wired manager publishes raw provider state under:

```text
raw/host/wired/cap/wired-provider/<id>/status
raw/host/wired/cap/wired-provider/<id>/state/identity
raw/host/wired/cap/wired-provider/<id>/state/telemetry
raw/host/wired/cap/wired-provider/<id>/state/surfaces
raw/host/wired/cap/wired-provider/<id>/state/topology
```

Device curates those facts into the public wired-provider capability surface:

```text
cap/wired-provider/<id>/status
cap/wired-provider/<id>/state/identity
cap/wired-provider/<id>/state/telemetry
cap/wired-provider/<id>/state/surfaces
cap/wired-provider/<id>/state/topology
```

The component view also carries the same material under `component.wired_provider`: status, identity, telemetry, surfaces and topology.  This is deliberate: the provider should not only expose port surfaces.  Firmware version, management address, device-wide PoE power and temperature, and other read-only operational details are part of the curated switch model.

Full CGI command bodies remain diagnostic and should not be retained on public curated topics by default.  Per-surface raw source rows are acceptable where they help debug parser mistakes without leaking credentials or write payloads.

### Surface naming

Use the physical and logical names reported by the switch as provider surface IDs:

```text
GE1..GE10
LAG1..LAG8
```

Map the configured Big Box protected surface `uplink-cm5` onto the actual provider surface only in configuration or a small provider alias map, not by changing the manufacturer surface names. The current Big Box config has `topology.uplinks.cm5 = "uplink-cm5"`; once the real port is known, this should become an alias to the appropriate `GE*` or `LAG*` surface.

## Suggested implementation plan

### Phase 1: read-only driver

Implement:

```text
new(config, opts)
login_op()
get_cmd_op(cmd)
fetch_snapshot_op(req)
parse_identity()
parse_ports()
parse_vlans()
parse_poe()
parse_lldp()
```

Keep the existing control operations read-only:

```text
apply_attachments_op -> read_only
set_poe_op           -> read_only
bounce_op            -> read_only
```

### Phase 2: explicit dry-run control model

Before write support, add pure request builders and tests for:

```text
vlan_portEdit
vlan_membershipEdit
vlan_conf
poe_poeEdit
poe_poeTimer
port_portEdit
home_save
```

Do not call `set.cgi` in normal operation until each operation has:

- a semantic request type;
- validation against the UI constraints above;
- an idempotent desired-state comparison;
- a dry-run output showing the exact CGI command and body;
- fixture tests using captured HTML/JSON;
- a clear save/revert policy.

### Phase 3: controlled writes

Only after Phase 2, implement:

```text
apply_attachments_op
set_poe_op
bounce_op
```

Each write should:

1. login;
2. read current state;
3. validate the requested transition;
4. submit the minimum required `set.cgi` call;
5. re-read and verify state;
6. optionally save configuration, under an explicit policy;
7. return a semantic result with raw evidence.

## Safety notes

- The discovery tools deliberately avoided configuration writes except the login POST.
- `set.cgi` endpoints were recorded for design purposes and must be treated as mutating.
- `home_save`, reboot and firmware-management pages must not be called by the provider without an explicit higher-level operation.
- Keep credentials out of logs and retained state. Redact passwords and encrypted password payloads.
- Store raw payloads only as bounded diagnostics. They may contain hostnames, MAC addresses, network settings or credentials-related configuration.

## Open questions

These should be resolved during driver implementation or with a narrow follow-up capture:

1. Why `lua-http` fails on CGI response headers for this switch firmware.
2. The exact session mechanism beyond `cookie_language`.
3. The exact POST body shape for each control operation.
4. Whether writes require a separate `home_save` to persist across reboot.
5. Which physical port or LAG is the CM5 uplink in the final Big Box wiring.
6. Whether the firmware version `1.0.0.6` is representative of production units.

## Driver dependency-port integration

The read-only RTL8380M provider is an HTTP-capability user, but it should not
receive the bus connection. The HAL service root owns `conn`, declares an HTTP
client dependency, and passes the wired manager an `http_client_for(capability)`
factory. The wired manager constructs the provider with that narrowed dependency
port. The provider can call `exchange_op` on the HTTP capability, but it cannot
construct arbitrary bus topics or call unrelated capabilities.

The supported switch HTTP mode remains:

```lua
http = {
  capability = "main",
  response_parser = "legacy-http1-close",
  max_response_bytes = 1024 * 1024,
}
```
