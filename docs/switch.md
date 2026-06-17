# Big Box RTL8380M switch integration

This document records the useful results from the Big Box PoE/VLAN switch discovery work and the current architecture for using those results.  It is intended to avoid repeating the UI/API exploration when the read-only driver is extended into a controlled switch driver.

The explored switch was first discovered at `http://192.168.1.1/` with the factory `admin` account.  In Big Box it is addressed on the internal management segment at `http://172.28.100.9/`.  The current configuration uses `switch-main` as the raw observation id and Device component id.

## Current architectural boundary

The switch is currently an attached local hardware element observed by the CM5 over HTTP.  It is not yet a fabric peer.  The current boundary is therefore:

```text
RTL8380M manufacturer HTTP UI/API
  -> services.hal.backends.wired.providers.rtl8380m_http
  -> raw/host/wired/provider/switch-main/...
  +  state/device/assembly
  -> services.wired
  -> state/wired/...
```

The public seam is `state/wired/...`.  There is no public `cap/wired-provider` seam.  Provider-shaped data remains raw input or diagnostic provenance only; the public seam is source/component terminology.

The intended future boundary, once the switch itself runs OpenWrt, devicecode and fabric, is:

```text
switch fabric peer observations
  + state/device/assembly
  -> services.wired
  -> state/wired/...
```

`services.net` should remain unchanged across that transition.  It consumes semantic wired state, not the RTL8380M driver, raw switch topics or manufacturer port names.

## Big Box physical map

The CM5's single Ethernet port is connected to the RTL8380M switch on `GE8`.

The current product assembly uses:

```text
cm5-local-wired / eth0  <->  switch-main / GE8
```

Stable product surfaces are mapped by Device assembly:

```text
cm5-eth0           -> cm5-local-wired / eth0
switch-uplink-cm5 -> switch-main / GE8
lan-1              -> switch-main / GE1
lan-2              -> switch-main / GE2
lan-3              -> switch-main / GE3
lan-4              -> switch-main / GE4
lan-5              -> switch-main / GE5
lan-6              -> switch-main / GE6
lan-7              -> switch-main / GE7
sfp-1              -> switch-main / GE9
sfp-2              -> switch-main / GE10
```

`GE1` to `GE8` are copper ports and are the PoE-capable surfaces.  `GE9` and `GE10` are fibre/SFP surfaces and do not appear in the PoE port list.

`cfg/wired` must not repeat this physical mapping.  It describes semantic wired intent for product surfaces: protected trunks, access/trunk mode, required segments, user-segment expansion, PoE expectations and related policy.  Device assembly says what backs a surface; Wired says what that surface means.

## Driver status

The current driver is:

```text
src/services/hal/backends/wired/providers/rtl8380m_http.lua
```

It is deliberately read-only.  It implements one-shot snapshot observation and returns `read_only` for configuration operations until the write forms have dedicated tests against the switch UI.

The production HTTP path is through the `services.http` capability.  The driver does not use `curl`, shell-out HTTP, raw sockets or direct bus access.  The HAL wired manager obtains the narrowed HTTP dependency at the service boundary and passes an HTTP dependency factory to the provider.

The only supported switch HTTP provider configuration spellings on this path are listed below.  `base_url` must include the scheme and trailing slash:

```lua
{
  provider = "rtl8380m_http",
  base_url = "http://172.28.100.9/",
  username = "$SWITCH_USERNAME",
  password = "$SWITCH_PASSWORD",
  timeout_s = 0.8,
  poll = {
    fast = { interval_s = 1.0, groups = { "panel", "poe", "counters" } },
    medium = { interval_s = 5.0, groups = { "vlan", "lldp" } },
    slow = { interval_s = 30.0, groups = { "identity", "runtime" } },
  },
  http = {
    capability = "main",
    response_parser = "legacy-http1-close",
    max_response_bytes = 1024 * 1024,
  },
}
```

The HAL wired manager treats the providers-map key as the observation id and passes it to the backend as `opts.provider_id`.  It must not be repeated inside provider configuration.  Do not add compatibility aliases such as `id`, `url`, `user`, `pass`, `capability_id`, `http_id` or top-level parser settings.

## HTTP and session behaviour

The root page only redirects with JavaScript:

```html
window.location.href="login.html?ver=" + fileVer;
```

The real browser entry points are `login.html` and, after authentication, `home.html?ver=<timestamp>`.

The UI is a JavaScript application using CGI command endpoints:

```text
GET  /cgi/get.cgi?cmd=<command>
POST /cgi/set.cgi?cmd=<command>
```

Template paths often use `../cgi/...`, but the driver normalises commands to root-relative `/cgi/...`.

### Legacy HTTP parser

Ordinary HTML and JavaScript pages are readable with `lua-http`.  Several CGI responses from this firmware are not accepted by the normal `lua-http` response parser.  The production driver therefore asks the HTTP service for:

```text
response_parser = "legacy-http1-close"
```

This parser is inside `services.http`, not the switch provider.  It is opt-in through HTTP policy, bounded by timeout and maximum response size, limited to HTTP GET/POST/HEAD over `http://`, requires a valid HTTP status line, rejects unsupported transfer encodings, does not follow redirects, and does not expose raw sockets to callers.

The strict HTTP path uses the normal `lua-http`/cqueues transport.  The `legacy-http1-close` path cannot use the `lua-http` response parser because the switch CGI replies are malformed for that parser.  It therefore uses the HTTP service's bounded legacy transport with Fibers non-blocking socket operations.  It remains scheduled work inside the HTTP service capability and should not block the rest of the system, but it is not parsed by `lua-http`.

HTTP policy must explicitly admit it:

```lua
policy = {
  allowed_response_parsers = {
    strict = true,
    ["legacy-http1-close"] = true,
  },
  legacy_http1_close_max_response_bytes = 1024 * 1024,
}
```

### Cookies

The only cookie consistently observed during exploration was:

```text
cookie_language=defLang_en
```

The driver preserves `Set-Cookie` values and replays the cookie header.  The authenticated session may be IP-bound or implicit in the switch firmware; no separate durable API token was identified.

## Login flow

The switch does not use HTTP Basic authentication.  The UI performs an RSA-encrypted password login.

Step 1:

```text
GET /cgi/get.cgi?cmd=home_login
```

The response includes a public RSA modulus.

Step 2:

```text
POST /cgi/set.cgi?cmd=home_loginAuth
```

The browser sends an encrypted password generated with the modulus from `home_login`.  The Lua driver uses `openssl` for this RSA operation.  The successful crawler run identified the login method as `rtl8380-rsa`; `home_loginStatus` returned `status = "ok"` after authentication.

## Read-side CGI commands

The read-only snapshot uses these commands:

```text
home_main
panel_info
sys_sysinfo
sys_cpumem
port_port
vlan_create
vlan_conf
vlan_port
vlan_membership
poe_poe
rmon_statistics
lldp_local
lldp_neighbor
```

The provider has narrow read groups for grouped polling.  Surface-bearing groups include `home_main` so that rows can be attached to the canonical switch surface names (`GE1` ... `GE10`):

```text
panel path:    home_main, panel_info
identity path: sys_sysinfo
vlan path:     home_main, vlan_create, vlan_conf, vlan_port, vlan_membership
poe path:      home_main, poe_poe
lldp path:     lldp_local, lldp_neighbor
runtime path:  sys_cpumem
counters path: home_main, rmon_statistics
```

The poll plan is based on timings measured against the fixed RTL8380M switch on 192.168.1.1 using a retained admin session:

```text
panel      avg 0.303 s, max 0.344 s
vlan       avg 0.363 s, max 0.389 s
poe        avg 0.077 s, max 0.084 s
lldp       avg 0.160 s, max 0.183 s
counters   avg 0.203 s, max 0.257 s
runtime    avg 2.085 s, max 2.089 s
full read  avg 3.522 s, max 3.554 s, with observed timeout
```

A concurrent probe over `panel,poe,counters,runtime` improved wall-clock time only modestly, from 2.688 s sequential average to 2.309 s concurrent average, so the production poller remains grouped and sequential.

The driver captures the full snapshot into normalised provider observations:

```text
raw/host/wired/provider/switch-main/status
raw/host/wired/provider/switch-main/state/identity
raw/host/wired/provider/switch-main/state/runtime
raw/host/wired/provider/switch-main/state/power
raw/host/wired/provider/switch-main/state/surfaces
raw/host/wired/provider/switch-main/state/topology
```

If `include_raw = true` is set in a test, the snapshot also keeps the source command payloads for parser debugging.  Full raw CGI bodies should not be promoted to public retained state by default.

The HAL wired manager owns scheduling.  For the RTL8380M provider, manager apply admits the provider and starts owned poller work; switch observation is not part of configuration admission.  The Big Box poll plan is grouped and sequential:

```text
fast, 1 Hz:   panel, poe, counters
medium, 5 s:  vlan, lldp
slow, 30 s: identity, runtime
```

Each poll loop is non-overlapping.  A slow runtime read therefore cannot queue behind, block, or mark the fast link-state path unavailable.  Successful groups merge into the retained raw observation cache, so `state/surfaces` carries last-known link, PoE, counter and VLAN facts together.  Group failures update provider status but leave the last good identity/runtime/power/surfaces/topology retained facts in place.

Canonical observation names are deliberately strict.  CPU and memory are published as `runtime.cpu` and `runtime.memory`; PoE device-level power and temperature are published as `power.poe`; port counters are published under each surface as `counters`.  The switch path must not publish `telemetry.cpu`, `telemetry.mem`, `telemetry.poe`, or any compatibility topic for `state/telemetry`.

## Snapshot shape

The provider snapshot includes:

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
    login = "confirmed",
  },
  identity = {
    model = "RTL8380",
    hostname = "...",
    mac = "...",
    firmware = "...",
    loader = "...",
    management_ipv4 = "...",
  },
  runtime = {
    cpu = { utilisation_pct = ... },
    memory = { utilisation_pct = ... },
  },
  power = {
    poe = {
      total_power_mw = ...,
      total_power_w = ...,
      temperature_c = ...,
    },
  },
  surfaces = {
    GE1 = {
      provider_surface_id = "GE1",
      kind = "ethernet-port",
      capabilities = { access = true, trunk = true, poe = true },
      link = { state = "up", speed_mbps = 1000, duplex = "full", media = "copper" },
      attachment = { mode = "trunk", pvid = 1, tagged = {...}, untagged = {...} },
      poe = { state = "off", enabled = true, ... },
      counters = {
        rx = { bytes = ..., packets = ..., drops = ..., errors = ... },
      },
    },
  },
  topology = {
    lldp_local = {...},
    lldp_neighbor = {...},
  },
}
```

The `provider_surface_id` field is raw provider provenance.  Device assembly and Wired use the canonical backing vocabulary `component` plus `observed_surface`.

## VLAN model

The UI exposes four useful read-side VLAN views:

```text
vlan_create      configured VLAN list
vlan_conf        per-selected-VLAN membership for each port/LAG
vlan_port        per-port mode, PVID, accepted-frame type and TPID
vlan_membership  per-port admin/oper VLAN membership strings
```

The current default observed state is VLAN 1 untagged/PVID on all ports and LAGs.

VLAN mode mapping:

```text
0 -> hybrid
1 -> access
2 -> trunk
3 -> tunnel
```

Accepted frame type mapping:

```text
0 -> all
1 -> tag_only
2 -> untag_only
```

Per-VLAN membership mapping:

```text
0 -> excluded
2 -> tagged
3 -> untagged
```

Membership string examples:

```text
1UP   VLAN 1, untagged, PVID
8T    VLAN 8, tagged
32F   VLAN 32, forbidden
100U  VLAN 100, untagged
```

The UI uses `4095P` as a placeholder when a hybrid port has no real PVID.  Do not treat `4095P` as a real configured VLAN.

## PoE model

PoE is exposed through `poe_poe`.  It includes eight ports, corresponding to `GE1` through `GE8`.  It does not include `GE9` or `GE10`.

Useful PoE fields include:

```text
portEnable       admin enabled
portStatus       delivering/not delivering
portType         detected class/type string
portPowerLimit   configured power limit
portPriority     priority, where exposed
portLegacy       legacy detection mode, where exposed
devPower         source field mapped to power.poe.total_power_mw / total_power_w
devTemp          source field mapped to power.poe.temperature_c
```

The driver normalises PoE-capable surfaces with `capabilities.poe = true` and includes a `poe` table for those surfaces.

## Control endpoints discovered but not yet enabled

The UI JavaScript exposes write commands under `set.cgi`, including login/logout/save and edit forms for system, ports, VLAN, PoE, LLDP and related configuration.  The current production driver must not submit these until each operation has a test covering the exact payload shape and required persistence behaviour.

Known write categories include:

```text
home_loginAuth
home_save
home_logout
port_port
vlan_create
vlan_conf
vlan_port
poe_poe
poe_poeEdit
poe_poeTimer
sys_sysinfo
lldp_* edit commands
```

Likely control questions still to resolve:

```text
whether every write requires home_save to persist across reboot
exact POST body for each VLAN and PoE write
whether port/LAG indexing is zero- or one-based for all edit forms
whether firmware 1.0.0.6 is representative of production units
how failed validation is reported by set.cgi
```

## Test coverage

The real-switch tests are opt-in and environment gated:

```sh
cd tests
SWITCH_TEST_BASE_URL=http://192.168.1.1/ \
SWITCH_TEST_USERNAME=admin \
SWITCH_TEST_PASSWORD=admin \
TEST_FILTER=rtl8380m_real_switch \
lua run.lua
```

They prove:

```text
the HTTP capability and legacy parser can snapshot the real switch
login succeeds through the RSA flow
GE8 is present as the Big Box internal switch uplink
GE9 and GE10 are fibre/SFP surfaces
raw switch observations project through Device assembly into state/wired
```

The OpenWrt VM tests cover the static equivalent of the same seam: Device assembly plus raw wired observations are transformed into semantic Wired state, and Net remains above that boundary.
