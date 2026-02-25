That is workable. The simplest way to “own all of UCI” without making the rest of devicecode speak UCI is to define an **internal, vendor-neutral desired state**, then have the OpenWrt HAL backend compile it into UCI transactions.

The key is to avoid internal vocabulary like “UCI”, “section”, “option”, “list”, and also avoid package-specific names like `mwan3`. You can still map cleanly at the boundary.

## Proposed internal shape

### Principles

* **Authoritative**: devicecode declares the entire intended configuration for each domain; the backend replaces what is on disk.
* **Stable identifiers**: everything that becomes a named stanza on disk has a stable `id` (no anonymous constructs).
* **Two value classes only**:

  * `fields`: scalar values (string/number/boolean)
  * `sets`: ordered arrays (strings/numbers/booleans)
* **Escape hatch**: each object may carry `extra.fields` and `extra.sets` for keys you do not model yet.

### Canonical container

```lua
-- devicecode desired system state (v2.3)
{
  schema = "devicecode.state/2.3",
  rev    = 12,         -- config revision (your notion)
  gen    = 34,         -- apply generation (your notion)

  network = <NetworkModel>,
  addressing = <AddressingModel>,  -- DHCP/DNS (+ optional RA/DHCPv6 bits)
  radio = <RadioModel>,            -- Wi-Fi
  multiwan = <MultiwanModel>,      -- mwan3 without naming it
}
```

### Network model

```lua
NetworkModel = {
  globals = {
    ula_prefix      = "auto" | "fd.." | nil,
    packet_steering = 0|1|2 | nil,
    tcp_l3mdev      = true|false | nil,
    udp_l3mdev      = true|false | nil,
    netifd_loglevel = number | nil,

    extra = { fields = { ... }, sets = { ... } },
  } | nil,

  links = {
    ["br-lan"] = {
      kind = "bridge" | "plain" | "macvlan" | "vrf" | nil, -- backend decides mapping
      ports = { "eth0.1" } | nil,
      mac   = "62:..." | nil,

      knobs = { rxpause=true|false|nil, txpause=true|false|nil, autoneg=true|false|nil,
                speed=1000|nil, duplex="full"|"half"|nil },

      extra = { fields = { ... }, sets = { ... } },
    },
  } | nil,

  nets = {
    lan = {
      proto  = "static"|"dhcp"|"none"|...,
      link   = "br-lan"|"eth0.1"|nil,

      v4 = { addr="192.168.1.1", mask="255.255.255.0", gw=nil } | nil,
      dns = { "1.1.1.1", "9.9.9.9" } | nil,

      mtu        = number | nil,
      auto       = true|false|nil,
      ipv6       = true|false|nil,
      force_link = true|false|nil,
      disabled   = true|false|nil,

      tables = { v4=nil|string|number, v6=nil|string|number } | nil,

      extra = { fields = { ... }, sets = { ... } },
    },
  } | nil,

  routes = {
    { id="r1", family="v4", via_net="lan", to="10.0.0.0/8", via="192.168.1.254", extra={fields={...},sets={...}} },
  } | nil,

  rules = {
    { id="pbr1", family="v4", src="192.168.1.50", lookup="100", extra={fields={...},sets={...}} },
  } | nil,
}
```

### Addressing model (DHCP/DNS)

```lua
AddressingModel = {
  dns = {
    main = {
      fields = { domainneeded=true, boguspriv=true, authoritative=true, localservice=true, rebind_protection=true },
      sets   = { server={ "1.1.1.1", "9.9.9.9" } },
      extra  = { fields = { ... }, sets = { ... } },
    },
  } | nil,

  pools = {
    lan = {
      fields = { net="lan", start=100, limit=150, leasetime="12h", v4="server" },
      sets   = { dhcp_option = { } },
      extra  = { fields = { ... }, sets = { ... } },
    },
    guest = {
      fields = { net="guest", start=50, limit=100, leasetime="4h", v4="server" },
      sets   = { },
      extra  = { fields = { ... }, sets = { ... } },
    },
  } | nil,

  reservations = {
    { id="nas", fields={ name="nas", ip="192.168.1.123", leasetime="infinite" }, sets={ mac={ "11:22:33:44:55:66" } } },
  } | nil,

  boot = {
    { id="pxe", fields={ filename="pxelinux.0", serveraddress="192.168.1.10", servername="tftp", networkid="pxe" } },
  } | nil,

  relays = {
    { id="rly1", fields={ net="lan", local_addr="1.1.1.1", server_addr="2.2.2.2" } },
  } | nil,

  classifiers = {
    mac = {
      { id="staff_macs", fields={ mac="00:11:22:33:44:55", networkid="staff" } },
    },
    vendorclass = {
      { id="phones", fields={ vendorclass="Android", networkid="phones", force=true }, sets={ dhcp_option={ "42,192.168.1.20" } } },
    },
    tag = {
      { id="staff_tag", fields={ tag="staff", force=true }, sets={ dhcp_option={ "6,192.168.1.2" } } },
    },
  } | nil,

  ipsets = {
    { id="streaming", sets={ name={ "dst_streaming_v4" }, domain={ "youtube.com", "netflix.com" } } },
  } | nil,
}
```

### Radio model (wireless)

```lua
RadioModel = {
  radios = {
    radio0 = {
      fields = { driver="mac80211", band="2g", channel="auto", htmode="HE20", country="GB", disabled=false },
      extra  = { fields = { ... }, sets = { ... } },
    },
    radio1 = {
      fields = { driver="mac80211", band="5g", channel="auto", htmode="HE80", country="GB", disabled=false },
      extra  = { fields = { ... }, sets = { ... } },
    },
  } | nil,

  ssids = {
    -- ordered for predictable output and operator expectations
    { id="home_2g",
      fields = { radio="radio0", mode="ap", ssid="Home", security="sae-mixed", key="...", ieee80211r=true, ft_over_ds=false },
      sets   = { nets={ "lan" } },
      extra  = { fields = { ... }, sets = { ... } },
    },
    { id="guest_2g",
      fields = { radio="radio0", mode="ap", ssid="Guest", security="psk2", key="...", isolate=true },
      sets   = { nets={ "guest" } },
      extra  = { fields = { ... }, sets = { ... } },
    },
  } | nil,

  vlans = {
    { id="vlan10", fields={ ssid="home_2g", vid=10, net="dmz", name="10" }, extra={fields={...},sets={...}} },
  } | nil,

  stations = {
    { id="staff_phone", fields={ ssid="home_2g", vid=10, mac="12:34:56:78:90:00", key="per-device-psk" } },
  } | nil,
}
```

### Multiwan model (mwan3)

```lua
MultiwanModel = {
  globals = {
    fields = { enabled=true, logging=true, loglevel="notice", mark_mask="0x3F00" },
    extra  = { fields = { ... }, sets = { ... } },
  } | nil,

  uplinks = {
    wan  = { fields={ enabled=true, family="ipv4", net="wan",  track="ping", reliability=2, interval=10, timeout=4 }, sets={ probe={ "1.1.1.1", "9.9.9.9" } } },
    wanb = { fields={ enabled=true, family="ipv4", net="wanb", track="ping", reliability=1, interval=10, timeout=4 }, sets={ probe={ "1.0.0.1" } } },
  } | nil,

  members = {
    wan_m1_w3  = { fields={ uplink="wan",  metric=1, weight=3 } },
    wanb_m2_w1 = { fields={ uplink="wanb", metric=2, weight=1 } },
  } | nil,

  policies = {
    balanced = { fields={ last_resort="unreachable" }, sets={ use={ "wan_m1_w3", "wanb_m2_w1" } } },
    wan_only = { fields={ last_resort="unreachable" }, sets={ use={ "wan_m1_w3" } } },
  } | nil,

  rules = {
    -- ordered, top-to-bottom evaluation
    { id="voip",   fields={ policy="wan_only", proto="udp", dest_port="5060-5099", family="ipv4", logging=true } },
    { id="default",fields={ policy="balanced" } },
  } | nil,
}
```

## One worked end-to-end example

Putting the above together as a concrete reference:

```lua
local desired = {
  schema = "devicecode.state/2.3",
  rev = 12,
  gen = 34,

  network = {
    globals = {
      ula_prefix = "auto",
      packet_steering = 1,
      netifd_loglevel = 2,
      extra = { fields = {}, sets = {} },
    },

    links = {
      ["br-lan"] = {
        kind = "bridge",
        ports = { "eth0.1" },
        knobs = { igmp_snooping=true },
        extra = { fields = {}, sets = {} },
      },
      ["br-guest"] = {
        kind = "bridge",
        ports = {},
        knobs = { bridge_empty=true },
        extra = { fields = {}, sets = {} },
      },
    },

    nets = {
      lan = {
        proto = "static",
        link  = "br-lan",
        v4    = { addr="192.168.1.1", mask="255.255.255.0" },
        dns   = { "1.1.1.1", "9.9.9.9" },
        extra = { fields = { ip6assign=60 }, sets = {} },
      },

      guest = {
        proto = "static",
        link  = "br-guest",
        v4    = { addr="192.168.50.1", mask="255.255.255.0" },
        extra = { fields = {}, sets = {} },
      },

      wan = {
        proto = "dhcp",
        link  = "eth0.2",
        extra = { fields = { peerdns=false, metric=10 }, sets = {} },
      },

      wanb = {
        proto = "dhcp",
        link  = "eth0.3",
        extra = { fields = { peerdns=false, metric=20 }, sets = {} },
      },
    },
  },

  addressing = {
    dns = {
      main = {
        fields = { domainneeded=true, boguspriv=true, authoritative=true, localservice=true, rebind_protection=true },
        sets   = { server={ "1.1.1.1", "9.9.9.9" } },
        extra  = { fields = {}, sets = {} },
      },
    },

    pools = {
      lan   = { fields={ net="lan",   start=100, limit=150, leasetime="12h", v4="server" }, sets={}, extra={fields={},sets={}} },
      guest = { fields={ net="guest", start=50,  limit=100, leasetime="4h",  v4="server" }, sets={}, extra={fields={},sets={}} },
    },

    reservations = {
      { id="nas", fields={ name="nas", ip="192.168.1.123", leasetime="infinite" }, sets={ mac={ "11:22:33:44:55:66" } } },
    },
  },

  radio = {
    radios = {
      radio0 = { fields={ driver="mac80211", band="2g", channel="auto", htmode="HE20", country="GB", disabled=false }, extra={fields={},sets={}} },
    },

    ssids = {
      { id="home_2g",  fields={ radio="radio0", mode="ap", ssid="Home",  security="sae-mixed", key="REDACTED" }, sets={ nets={ "lan" } } },
      { id="guest_2g", fields={ radio="radio0", mode="ap", ssid="Guest", security="psk2",      key="REDACTED", isolate=true }, sets={ nets={ "guest" } } },
    },
  },

  multiwan = {
    globals = { fields={ enabled=true, logging=true, loglevel="notice", mark_mask="0x3F00" }, extra={fields={},sets={}} },

    uplinks = {
      wan  = { fields={ enabled=true, family="ipv4", net="wan",  track="ping", reliability=2, interval=10, timeout=4 }, sets={ probe={ "1.1.1.1", "9.9.9.9" } } },
      wanb = { fields={ enabled=true, family="ipv4", net="wanb", track="ping", reliability=1, interval=10, timeout=4 }, sets={ probe={ "1.0.0.1" } } },
    },

    members = {
      wan_m1_w3  = { fields={ uplink="wan",  metric=1, weight=3 } },
      wanb_m2_w1 = { fields={ uplink="wanb", metric=2, weight=1 } },
    },

    policies = {
      balanced = { fields={ last_resort="unreachable" }, sets={ use={ "wan_m1_w3", "wanb_m2_w1" } } },
    },

    rules = {
      { id="default", fields={ policy="balanced" } },
    },
  },
}
```

## Boundary mapping (kept explicit, but localised)

Internally you use `network/addressing/radio/multiwan`. The OpenWrt backend owns the mapping to on-disk structures. Keep that mapping in a single table in the backend, so the rest of devicecode never needs to know the details.

At minimum the backend needs to know:

* which internal domain maps to which file (`network`, `addressing`, `radio`, `multiwan`);
* how each record kind maps to a stanza type on disk;
* which internal keys become scalar fields vs repeated sets;
* how to render booleans and numbers.

If you follow the “stable id + fields + sets + authoritative replace” approach, you will not need any iteration APIs or anonymous identifiers, and the implementation becomes a predictable compile-and-apply step.

If you want, the next concrete step is to write down the mapping for just **`network`** and **`radio`** first (those have the most cross-references), then add **`addressing`** and finally **`multiwan`**.



{
  "monitor": {
    "rev": 1,
    "data": {
      "schema": "devicecode.pre_monitor/1.0",
      "pretty": true
    }
  },

  "net": {
    "rev": 1,
    "data": {
      "schema": "devicecode.pre_net/1.0",

      "report_period_s": 60,

      "profiles": {
        "backhaul_default": {
          "network": {
            "ipv4": { "enabled": true, "proto": "dhcp", "peerdns": false },
            "ipv6": { "enabled": false },
            "device": { "kind": "raw" }
          },
          "firewall": { "zone": "wan" },
          "shaping": {
            "egress": { "qdisc": "fq_codel" },
            "ingress": { "qdisc": "fq_codel" }
          },
          "multiwan": { "dynamic_weight": true, "metric": 1 }
        },

        "local_default": {
          "network": {
            "ipv4": { "enabled": true, "proto": "static" },
            "ipv6": { "enabled": false },
            "device": { "kind": "bridge", "bridge_empty": false }
          },
          "firewall": { "zone": "lan" },
          "shaping": {
            "egress": { "qdisc": "fq_codel" },
            "ingress": { "qdisc": "fq_codel" }
          },
          "multiwan": null
        },

        "local_restricted": {
          "network": {
            "ipv4": { "enabled": true, "proto": "static" },
            "ipv6": { "enabled": false },
            "device": { "kind": "bridge", "bridge_empty": false }
          },
          "firewall": { "zone": "lan_rst" },
          "shaping": null,
          "multiwan": null
        }
      },

      "dns": {
        "upstream_servers": [ "8.8.8.8", "1.1.1.1" ],
        "default_cache_size": 1000,
        "extra": { "fields": {}, "sets": {} }
      },

      "dhcp": {
        "domains": [
          { "name": "unifi", "ip": "$UNIFI_IP" },
          { "name": "config.bigbox.home", "ip": "172.28.8.1" }
        ],
        "extra": { "fields": {}, "sets": {} }
      },

      "network": {
        "globals": {
          "ula_prefix": null,
          "packet_steering": 0,
          "tcp_l3mdev": false,
          "udp_l3mdev": false,
          "netifd_loglevel": 2,
          "extra": { "fields": {}, "sets": {} }
        },

        "nets": {
          "loopback": {
            "id": "loopback",
            "name": "Loopback",
            "role": "local",
            "profile": null,

            "device": {
              "kind": "raw",
              "ifnames": [ "lo" ],
              "extra": { "fields": {}, "sets": {} }
            },

            "ipv4": { "enabled": true, "proto": "static", "ip_address": "127.0.0.1", "netmask": "255.0.0.0" },
            "dhcp_server": null,
            "dns_server": { "local_server": true, "default_hosts": [] },

            "firewall": null,
            "shaping": null,
            "multiwan": null,

            "extra": { "fields": {}, "sets": {} }
          },

          "adm": {
            "id": "adm",
            "name": "Admin Network",
            "role": "local",
            "profile": "local_default",

            "device": {
              "kind": "bridge",
              "ifnames": [ "eth0.8" ],
              "bridge_empty": false,
              "extra": { "fields": {}, "sets": {} }
            },

            "ipv4": { "enabled": true, "proto": "static", "ip_address": "172.28.8.1", "netmask": "255.255.255.0" },

            "dhcp_server": { "enabled": true, "range_skip": 10, "range_extent": 240, "lease_time": "12h" },
            "dns_server": { "local_server": true, "default_hosts": [ "ads" ] },

            "firewall": { "zone": "lan" },
            "shaping": null,
            "multiwan": null,

            "extra": { "fields": {}, "sets": {} }
          },

          "jan": {
            "id": "jan",
            "name": "Jangala Network",
            "role": "local",
            "profile": "local_restricted",

            "device": {
              "kind": "bridge",
              "ifnames": [ "eth0.32" ],
              "bridge_empty": false,
              "extra": { "fields": {}, "sets": {} }
            },

            "ipv4": { "enabled": true, "proto": "static", "ip_address": "172.28.32.1", "netmask": "255.255.255.0" },

            "dhcp_server": { "enabled": true, "range_skip": 10, "range_extent": 240, "lease_time": "12h" },
            "dns_server": { "local_server": true, "default_hosts": [ "ads", "adult" ] },

            "firewall": { "zone": "lan_rst" },

            "shaping": {
              "egress": {
                "qdisc": "htb",
                "filters": [
                  {
                    "id": "per_ip_filter",
                    "kind": "u32",
                    "hash_key": "dest_ip",
                    "target_class_template": "per_ip_shapers"
                  }
                ],
                "class_template": {
                  "id": "per_ip_shapers",
                  "kind": "per_dest_ip",
                  "classes": [
                    {
                      "qdisc": "htb",
                      "config": { "rate": "2mbit", "ceil": "8mbit", "burst": "500k" },
                      "classes": [ { "qdisc": "fq_codel" } ]
                    }
                  ]
                }
              },
              "ingress": {
                "qdisc": "htb",
                "filters": [
                  {
                    "id": "per_ip_filter",
                    "kind": "u32",
                    "hash_key": "src_ip",
                    "target_class_template": "per_ip_shapers"
                  }
                ],
                "class_template": {
                  "id": "per_ip_shapers",
                  "kind": "per_src_ip",
                  "classes": [
                    {
                      "qdisc": "htb",
                      "config": { "rate": "1.5mbit", "ceil": "6mbit", "burst": "225k" },
                      "classes": [ { "qdisc": "fq_codel" } ]
                    }
                  ]
                }
              }
            },

            "multiwan": null,

            "extra": { "fields": {}, "sets": {} }
          },

          "int": {
            "id": "int",
            "name": "Internal Network",
            "role": "local",
            "profile": "local_default",

            "device": {
              "kind": "bridge",
              "ifnames": [ "eth0.100" ],
              "bridge_empty": false,
              "extra": { "fields": {}, "sets": {} }
            },

            "ipv4": { "enabled": true, "proto": "static", "ip_address": "172.28.100.1", "netmask": "255.255.255.0" },

            "dhcp_server": { "enabled": true, "range_skip": 10, "range_extent": 240, "lease_time": "12h" },
            "dns_server": { "local_server": false, "default_hosts": [] },

            "firewall": { "zone": "lan" },
            "shaping": {
              "egress": { "qdisc": "fq_codel" },
              "ingress": { "qdisc": "fq_codel" }
            },
            "multiwan": null,

            "extra": { "fields": {}, "sets": {} }
          },

          "mdm0": {
            "id": "mdm0",
            "name": "Primary Modem",
            "role": "backhaul",
            "profile": "backhaul_default",

            "modem_id": "primary",

            "device": {
              "kind": "raw",
              "ifnames": [],
              "extra": { "fields": {}, "sets": {} }
            },

            "ipv4": { "enabled": true, "proto": "dhcp", "peerdns": false },
            "firewall": { "zone": "wan" },
            "shaping": {
              "egress": { "qdisc": "fq_codel" },
              "ingress": { "qdisc": "fq_codel" }
            },
            "multiwan": { "dynamic_weight": true, "metric": 1 },

            "extra": { "fields": {}, "sets": {} }
          },

          "mdm1": {
            "id": "mdm1",
            "name": "Secondary Modem",
            "role": "backhaul",
            "profile": "backhaul_default",

            "modem_id": "secondary",

            "device": {
              "kind": "raw",
              "ifnames": [],
              "extra": { "fields": {}, "sets": {} }
            },

            "ipv4": { "enabled": true, "proto": "dhcp", "peerdns": true },
            "firewall": { "zone": "wan" },
            "shaping": {
              "egress": { "qdisc": "fq_codel" },
              "ingress": { "qdisc": "fq_codel" }
            },
            "multiwan": { "dynamic_weight": true, "metric": 1 },

            "extra": { "fields": {}, "sets": {} }
          },

          "wan": {
            "id": "wan",
            "name": "Wired Internet",
            "role": "backhaul",
            "profile": "backhaul_default",

            "device": {
              "kind": "raw",
              "ifnames": [ "eth0.4" ],
              "extra": { "fields": {}, "sets": {} }
            },

            "ipv4": { "enabled": true, "proto": "dhcp", "peerdns": false },
            "firewall": { "zone": "wan" },
            "shaping": {
              "egress": { "qdisc": "fq_codel" },
              "ingress": { "qdisc": "fq_codel" }
            },
            "multiwan": { "dynamic_weight": true, "metric": 1 },

            "extra": { "fields": {}, "sets": {} }
          }
        }
      },

      "multiwan": {
        "schema": "devicecode.pre_multiwan/1.0",

        "globals": {
          "mark_mask": "0x3F00",
          "logging": true,
          "loglevel": "notice",
          "enabled": true,
          "extra": { "fields": {}, "sets": {} }
        },

        "strategy": {
          "default": "dynamic_weight",
          "extra": { "fields": {}, "sets": {} }
        },

        "health": {
          "track_method": "ping",
          "track_ip": [ "1.1.1.1", "8.8.8.8" ],
          "timeout_s": 2,
          "interval_s": 1,
          "down": 2,
          "up": 1,
          "initial_state": "offline",
          "extra": { "fields": {}, "sets": {} }
        },

        "rules": [],
        "extra": { "fields": {}, "sets": {} }
      },

      "firewall": {
        "schema": "devicecode.pre_firewall/1.0",

        "defaults": {
          "syn_flood": true,
          "input": "ACCEPT",
          "forward": "REJECT",
          "output": "ACCEPT",
          "disable_ipv6": true,
          "extra": { "fields": {}, "sets": {} }
        },

        "zones": {
          "lan": {
            "description": "Local Networks",
            "config": { "name": "lan", "input": "ACCEPT", "output": "ACCEPT", "forward": "ACCEPT" },
            "forward_to": [ "wan" ],
            "extra": { "fields": {}, "sets": {} }
          },

          "lan_rst": {
            "description": "Local Networks - restricted",
            "config": { "name": "lan_rst", "input": "REJECT", "output": "ACCEPT", "forward": "REJECT" },
            "forward_to": [ "wan" ],
            "extra": { "fields": {}, "sets": {} }
          },

          "wan": {
            "description": "Internet",
            "config": {
              "name": "wan",
              "input": "REJECT",
              "output": "ACCEPT",
              "forward": "REJECT",
              "masq": true,
              "mtu_fix": true
            },
            "forward_to": [],
            "extra": { "fields": {}, "sets": {} }
          }
        },

        "rules": [
          {
            "id": "allow_dhcp_renew",
            "description": "Allows for DHCP renewal from upstream routers",
            "config": { "name": "Allow-DHCP-Renew", "src": "wan", "proto": "udp", "dest_port": "68", "target": "ACCEPT" }
          },
          {
            "id": "allow_ping",
            "description": "Responds to pings from the Internet",
            "config": { "name": "Allow-Ping", "src": "wan", "proto": "icmp", "icmp_type": "echo-request", "target": "ACCEPT" }
          },
          {
            "id": "allow_igmp",
            "description": "",
            "config": { "name": "Allow-IGMP", "src": "wan", "proto": "igmp", "target": "ACCEPT" }
          },
          {
            "id": "allow_ipsec_esp",
            "description": "",
            "config": { "name": "Allow-IPSec-ESP", "src": "wan", "dest": "lan", "proto": "esp", "target": "ACCEPT" }
          },
          {
            "id": "allow_isakmp",
            "description": "",
            "config": { "name": "Allow-ISAKMP", "src": "wan", "dest": "lan", "proto": "udp", "dest_port": "500", "target": "ACCEPT" }
          },
          {
            "id": "allow_ipsec_esp_rst",
            "description": "",
            "config": { "name": "Allow-IPSec-ESP (RST)", "src": "wan", "dest": "lan_rst", "proto": "esp", "target": "ACCEPT" }
          },
          {
            "id": "allow_isakmp_rst",
            "description": "",
            "config": { "name": "Allow-ISAKMP (RST)", "src": "wan", "dest": "lan_rst", "proto": "udp", "dest_port": "500", "target": "ACCEPT" }
          },
          {
            "id": "allow_dhcp_rst",
            "description": "",
            "config": { "name": "Allow DHCP request (RST)", "src": "lan_rst", "proto": "udp", "src_port": "67-68", "dest_port": "67-68", "target": "ACCEPT" }
          },
          {
            "id": "allow_dns_rst",
            "description": "",
            "config": { "name": "Allow DNS queries (RST)", "src": "lan_rst", "proto": "tcp udp", "dest_port": "53", "target": "ACCEPT" }
          }
        ],

        "extra": { "fields": {}, "sets": {} }
      },

      "routes": {
        "static": [
          { "target": "192.168.100.1", "interface": "wan" }
        ],
        "extra": { "fields": {}, "sets": {} }
      },

      "extra": { "fields": {}, "sets": {} }
    }
  },

  "wifi": {
    "rev": 1,
    "data": {
      "schema": "devicecode.pre_wifi/1.0",
      "report_period_s": 10,

      "radios": {
        "radio0": {
          "name": "radio0",
          "band": "2g",
          "channel": "auto",
          "allowed_channels": [ "1", "6", "11" ],
          "country": "GB",
          "htmode": "HE20",
          "txpower": 20,
          "disabled": false,
          "extra": { "fields": {}, "sets": {} }
        },

        "radio1": {
          "name": "radio1",
          "band": "5g",
          "channel": "36",
          "allowed_channels": [],
          "country": "GB",
          "htmode": "HE80",
          "txpower": 23,
          "disabled": false,
          "extra": { "fields": {}, "sets": {} }
        }
      },

      "ssids": [
        {
          "id": "mainflux_default",
          "mainflux_path": "config/mainflux",
          "mode": "access_point",
          "encryption": "psk2",
          "name": null,
          "radios": [ "radio0", "radio1" ],
          "network": null,
          "extra": { "fields": {}, "sets": {} }
        },
        {
          "id": "jangala_open",
          "name": "Jangala",
          "mode": "access_point",
          "encryption": "none",
          "network": "jan",
          "radios": [ "radio0", "radio1" ],
          "extra": { "fields": {}, "sets": {} }
        }
      ],

      "extra": { "fields": {}, "sets": {} }
    }
  }
}



compiled:

-- net compiler output target (derived from the older pre-net config)

local REV = 1
local GEN = 1

local desired = {
  schema = "devicecode.state/2.5",

  snapshot = {
    rev = REV,
    gen = GEN,
  },

  --------------------------------------------------------------------
  -- NETWORK
  --------------------------------------------------------------------
  network = {
    rev = REV,

    globals = {
      -- not present in the config; keep explicit and nil/omitted unless set
      ula_prefix      = nil,
      packet_steering = 1,
      tcp_l3mdev      = nil,
      udp_l3mdev      = nil,
      netifd_loglevel = nil,
    },

    links = {
      ["br-adm"] = {
        kind  = "bridge",
        ports = { "eth0.8" },

        bridge_empty      = false,
        vlan_filtering    = false,
        igmp_snooping     = false,
        multicast_querier = false,
        stp               = false,

        rxpause = nil,
        txpause = nil,
        autoneg = nil,
        speed   = nil,
        duplex  = nil,
        macaddr = nil,
      },

      ["br-jan"] = {
        kind  = "bridge",
        ports = { "eth0.32" },

        bridge_empty      = false,
        vlan_filtering    = false,
        igmp_snooping     = false,
        multicast_querier = false,
        stp               = false,

        rxpause = nil,
        txpause = nil,
        autoneg = nil,
        speed   = nil,
        duplex  = nil,
        macaddr = nil,
      },

      ["br-int"] = {
        kind  = "bridge",
        ports = { "eth0.100" },

        bridge_empty      = false,
        vlan_filtering    = false,
        igmp_snooping     = false,
        multicast_querier = false,
        stp               = false,

        rxpause = nil,
        txpause = nil,
        autoneg = nil,
        speed   = nil,
        duplex  = nil,
        macaddr = nil,
      },
    },

    nets = {
      loopback = {
        proto  = "static",
        device = { ifname = "lo" },

        auto       = true,
        disabled   = false,
        force_link = true,

        v4 = { addr = "127.0.0.1", prefix = 8, gw = nil },

        dns     = nil,
        peerdns = nil,
        metric  = nil,

        ipv6     = nil,
        ip6assign = nil,

        mtu     = nil,
        ip4table = nil,
        ip6table = nil,
      },

      adm = {
        proto  = "static",
        device = { ref = "br-adm" },

        auto       = true,
        disabled   = false,
        force_link = true,

        v4 = { addr = "172.28.8.1", prefix = 24, gw = nil },

        dns     = nil,
        peerdns = nil,
        metric  = nil,

        ipv6     = nil,
        ip6assign = nil,

        mtu     = nil,
        ip4table = nil,
        ip6table = nil,
      },

      jan = {
        proto  = "static",
        device = { ref = "br-jan" },

        auto       = true,
        disabled   = false,
        force_link = true,

        v4 = { addr = "172.28.32.1", prefix = 24, gw = nil },

        dns     = nil,
        peerdns = nil,
        metric  = nil,

        ipv6     = nil,
        ip6assign = nil,

        mtu     = nil,
        ip4table = nil,
        ip6table = nil,
      },

      int = {
        proto  = "static",
        device = { ref = "br-int" },

        auto       = true,
        disabled   = false,
        force_link = true,

        v4 = { addr = "172.28.100.1", prefix = 24, gw = nil },

        dns     = nil,
        peerdns = nil,
        metric  = nil,

        ipv6     = nil,
        ip6assign = nil,

        mtu     = nil,
        ip4table = nil,
        ip6table = nil,
      },

      mdm0 = {
        proto  = "dhcp",
        -- placeholder: resolved by modem service (or hal capability join)
        device = { ifname = "@modem.primary" },

        auto     = true,
        disabled = false,

        v4 = nil,
        dns = nil,

        -- old config: peerdns=0 => false
        peerdns = false,
        metric  = nil,

        ipv6     = nil,
        ip6assign = nil,

        mtu     = nil,
        ip4table = nil,
        ip6table = nil,
      },

      mdm1 = {
        proto  = "dhcp",
        device = { ifname = "@modem.secondary" },

        auto     = true,
        disabled = false,

        v4 = nil,
        dns = nil,

        peerdns = nil, -- not specified in old config
        metric  = nil,

        ipv6     = nil,
        ip6assign = nil,

        mtu     = nil,
        ip4table = nil,
        ip6table = nil,
      },

      wan = {
        proto  = "dhcp",
        device = { ifname = "eth0.4" },

        auto     = true,
        disabled = false,

        v4 = nil,
        dns = nil,

        peerdns = false,
        metric  = nil,

        ipv6     = nil,
        ip6assign = nil,

        mtu     = nil,
        ip4table = nil,
        ip6table = nil,
      },
    },

    routes = {
      -- from old net.static_route[{target="192.168.100.1", interface="wan"}]
      -- canonicalise as host route; backend decides exact UCI encoding.
      { family = "ipv4", target = "192.168.100.1/32", net = "wan", via = nil },
    },
  },

  --------------------------------------------------------------------
  -- ADDRESSING (dnsmasq + DHCP)
  --------------------------------------------------------------------
  addressing = {
    rev = REV,

    -- Profiles allow you to represent the old per-network "default_hosts" intent
    -- without an untyped bag.
    dns = {
      plain = {
        domainneeded      = nil,
        boguspriv         = nil,
        authoritative     = nil,
        localservice      = nil,
        rebind_protection = nil,

        upstream_servers = { "8.8.8.8", "1.1.1.1" },
        cache_size       = 1000,

        host_sets = {}, -- old: default_hosts=[]
      },

      ads = {
        domainneeded      = nil,
        boguspriv         = nil,
        authoritative     = nil,
        localservice      = nil,
        rebind_protection = nil,

        upstream_servers = { "8.8.8.8", "1.1.1.1" },
        cache_size       = 1000,

        host_sets = { "ads" },
      },

      ads_adult = {
        domainneeded      = nil,
        boguspriv         = nil,
        authoritative     = nil,
        localservice      = nil,
        rebind_protection = nil,

        upstream_servers = { "8.8.8.8", "1.1.1.1" },
        cache_size       = 1000,

        host_sets = { "ads", "adult" },
      },
    },

    pools = {
      adm = {
        net       = "adm",
        start     = 10,
        limit     = 240,
        leasetime = "12h",
        v4        = "server",

        -- choose dns profile for this pool
        dns_profile = "ads",
      },

      jan = {
        net       = "jan",
        start     = 10,
        limit     = 240,
        leasetime = "12h",
        v4        = "server",
        dns_profile = "ads_adult",
      },

      int = {
        net       = "int",
        start     = 10,
        limit     = 240,
        leasetime = "12h",
        v4        = "server",
        dns_profile = "plain",
      },
    },

    reservations = {
      -- none in the old config excerpt
    },

    domains = {
      { name = "unifi",            ip = "$UNIFI_IP"  },
      { name = "config.bigbox.home", ip = "172.28.8.1" },
    },
  },

  --------------------------------------------------------------------
  -- FIREWALL
  --------------------------------------------------------------------
  firewall = {
    rev = REV,

    defaults = {
      syn_flood    = true,
      input        = "ACCEPT",
      forward      = "REJECT",
      output       = "ACCEPT",
      disable_ipv6 = true,
    },

    zones = {
      lan = {
        input   = "ACCEPT",
        output  = "ACCEPT",
        forward = "ACCEPT",
        masq    = false,
        mtu_fix = false,
        networks = { "adm", "int" },
      },

      lan_rst = {
        input   = "REJECT",
        output  = "ACCEPT",
        forward = "REJECT",
        masq    = false,
        mtu_fix = false,
        networks = { "jan" },
      },

      wan = {
        input   = "REJECT",
        output  = "ACCEPT",
        forward = "REJECT",
        masq    = true,
        mtu_fix = true,
        networks = { "mdm0", "mdm1", "wan" },
      },
    },

    forwardings = {
      { src = "lan",     dest = "wan" },
      { src = "lan_rst", dest = "wan" },
    },

    rules = {
      {
        id        = "allow_dhcp_renew",
        name      = "Allow-DHCP-Renew",
        src       = "wan",
        dest      = nil,
        proto     = "udp",
        src_port  = nil,
        dest_port = "68",
        icmp_type = nil,
        target    = "ACCEPT",
      },

      {
        id        = "allow_ping",
        name      = "Allow-Ping",
        src       = "wan",
        dest      = nil,
        proto     = "icmp",
        src_port  = nil,
        dest_port = nil,
        icmp_type = "echo-request",
        target    = "ACCEPT",
      },

      {
        id        = "allow_igmp",
        name      = "Allow-IGMP",
        src       = "wan",
        dest      = nil,
        proto     = "igmp",
        src_port  = nil,
        dest_port = nil,
        icmp_type = nil,
        target    = "ACCEPT",
      },

      {
        id        = "allow_ipsec_esp",
        name      = "Allow-IPSec-ESP",
        src       = "wan",
        dest      = "lan",
        proto     = "esp",
        src_port  = nil,
        dest_port = nil,
        icmp_type = nil,
        target    = "ACCEPT",
      },

      {
        id        = "allow_isakmp",
        name      = "Allow-ISAKMP",
        src       = "wan",
        dest      = "lan",
        proto     = "udp",
        src_port  = nil,
        dest_port = "500",
        icmp_type = nil,
        target    = "ACCEPT",
      },

      {
        id        = "allow_ipsec_esp_rst",
        name      = "Allow-IPSec-ESP (RST)",
        src       = "wan",
        dest      = "lan_rst",
        proto     = "esp",
        src_port  = nil,
        dest_port = nil,
        icmp_type = nil,
        target    = "ACCEPT",
      },

      {
        id        = "allow_isakmp_rst",
        name      = "Allow-ISAKMP (RST)",
        src       = "wan",
        dest      = "lan_rst",
        proto     = "udp",
        src_port  = nil,
        dest_port = "500",
        icmp_type = nil,
        target    = "ACCEPT",
      },

      {
        id        = "allow_dhcp_rst",
        name      = "Allow DHCP request (RST)",
        src       = "lan_rst",
        dest      = nil,
        proto     = "udp",
        src_port  = "67-68",
        dest_port = "67-68",
        icmp_type = nil,
        target    = "ACCEPT",
      },

      {
        id        = "allow_dns_rst",
        name      = "Allow DNS queries (RST)",
        src       = "lan_rst",
        dest      = nil,
        proto     = "tcp udp",
        src_port  = nil,
        dest_port = "53",
        icmp_type = nil,
        target    = "ACCEPT",
      },
    },
  },

  --------------------------------------------------------------------
  -- MULTIWAN
  --------------------------------------------------------------------
  multiwan = {
    rev = REV,

    globals = {
      enabled   = true,
      logging   = nil,
      loglevel  = nil,
      mark_mask = "0x3F00", -- old mmx_mask
    },

    uplinks = {
      mdm0 = {
        enabled       = true,
        family        = "ipv4",
        net           = "mdm0",
        track         = "ping",
        reliability   = 2, -- old health_checks.down
        interval      = 1,
        timeout       = 2,
        probe         = { "1.1.1.1", "8.8.8.8" },
        dynamic_weight = true,
      },

      mdm1 = {
        enabled       = true,
        family        = "ipv4",
        net           = "mdm1",
        track         = "ping",
        reliability   = 2,
        interval      = 1,
        timeout       = 2,
        probe         = { "1.1.1.1", "8.8.8.8" },
        dynamic_weight = true,
      },

      wan = {
        enabled       = true,
        family        = "ipv4",
        net           = "wan",
        track         = "ping",
        reliability   = 2,
        interval      = 1,
        timeout       = 2,
        probe         = { "1.1.1.1", "8.8.8.8" },
        dynamic_weight = true,
      },
    },

    members = {
      mdm0_m1_w1 = { uplink = "mdm0", metric = 1, weight = 1 },
      mdm1_m1_w1 = { uplink = "mdm1", metric = 1, weight = 1 },
      wan_m1_w1  = { uplink = "wan",  metric = 1, weight = 1 },
    },

    policies = {
      default = {
        last_resort = "unreachable",
        use = { "mdm0_m1_w1", "mdm1_m1_w1", "wan_m1_w1" },
      },
    },

    rules = {
      { id = "default", policy = "default" },
    },
  },
}


