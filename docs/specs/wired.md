# Wired service: Phase 1 Big Box

`wired` is the appliance authority for wired physical surfaces. It attaches wired
surfaces to `net` segments, but does not define those segments. It consumes the
retained `state/net/segments` catalogue and public `cap/wired-provider/...`
capability state.

## Phase 1 scope

Phase 1 supports:

- the CM5 Ethernet port as protected appliance surface `cm5-eth0`;
- the RTL8380M switch-fabric uplink as protected appliance surface
  `switch-uplink-cm5`;
- a read-only `rtl8380m_http` HAL wired-provider stub for manufacturer firmware
  telemetry;
- validation that protected trunks are trunks, retain required system
  segments, carry all realised user segments where configured, and are backed by
  available provider surfaces;
- retained publication under `state/wired/...`.

Phase 1 does not apply switch configuration. The HTTP provider returns
`read_only` for attachment and PoE control operations.

## Authority split

- `net` owns segment identity, VLAN allocation, addressing, firewall, routing,
  WAN, VPN and shaping policy.
- `wired` owns wired surfaces, access/trunk attachment, protected internal trunk
  invariants, provider capability validation and wired topology.
- `device` owns appliance component composition. A switch component can be
  configured to watch the raw/public wired-provider facts and publish component
  health.
- HAL/provider code owns OpenWrt, manufacturer HTTP and switch-specific work.

## Provider API

The Phase 1 RTL8380M provider lives at:

`src/services/hal/backends/wired/providers/rtl8380m_http.lua`

A real driver should replace `fetch_snapshot_op(req)` and return semantic state:

```lua
{
  ok = true,
  provider_id = "switch-main",
  mode = "read_only",
  writable = false,
  status = { state = "available", available = true },
  surfaces = {
    ["uplink-cm5"] = {
      provider_surface_id = "uplink-cm5",
      kind = "switch-port",
      capabilities = { trunk = true, access = false, poe = false },
      link = { state = "up", speed_mbps = 1000 },
      attachment = { mode = "trunk", vlans = { 10, 11, 12, 100 } },
    },
  },
  topology = {},
}
```

Providers should declare surface capabilities such as `access`, `trunk` and `poe`. `wired` validates configured access/trunk/PoE usage against those capabilities.

No caller above HAL should know manufacturer URL paths, cookies, forms or ASIC
register names.
