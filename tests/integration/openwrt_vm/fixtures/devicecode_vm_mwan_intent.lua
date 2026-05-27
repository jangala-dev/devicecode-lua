-- Shared OpenWrt VM intent used by real /etc/config + mwan3 integration tests.
-- The VM exposes eth0 as the QEMU management/LAN NIC and eth1..eth3 as
-- deterministic QEMU user-mode WAN NICs when OPENWRT_VM_WAN_IFACES=3.

local M = {}

M.wans = {
  { id = 'wan', device = 'eth1', gateway = '172.31.1.2', route_metric = 11, weight = 50 },
  { id = 'wanb', device = 'eth2', gateway = '172.31.2.2', route_metric = 12, weight = 30 },
  { id = 'wanc', device = 'eth3', gateway = '172.31.3.2', route_metric = 13, weight = 20 },
}

function M.intent()
  return {
    schema = 'devicecode.net.intent/1',
    rev = 24010,
    generation = 24010,
    segments = {
      lan = {
        kind = 'lan',
        addressing = { ipv4 = { mode = 'static', cidr = '192.168.1.1/24' } },
        dhcp = { enabled = true, start = 100, limit = 150, leasetime = '12h' },
        dns = { local_server = true, domain = 'vm.bigbox.test' },
        firewall = { zone = 'lan' },
      },
    },
    interfaces = {
      lan = {
        kind = 'bridge', role = 'lan', segment = 'lan', members = { 'eth0' },
        addressing = { ipv4 = { mode = 'static', cidr = '192.168.1.1/24' } },
        firewall = { zone = 'lan' },
      },
      wan = {
        kind = 'ethernet', role = 'wan', endpoint = { ifname = 'eth1' },
        addressing = { ipv4 = { mode = 'dhcp', peerdns = false } },
        dhcp = { enabled = false }, firewall = { zone = 'wan' },
      },
      wanb = {
        kind = 'ethernet', role = 'wan', endpoint = { ifname = 'eth2' },
        addressing = { ipv4 = { mode = 'dhcp', peerdns = false } },
        dhcp = { enabled = false }, firewall = { zone = 'wan' },
      },
      wanc = {
        kind = 'ethernet', role = 'wan', endpoint = { ifname = 'eth3' },
        addressing = { ipv4 = { mode = 'dhcp', peerdns = false } },
        dhcp = { enabled = false }, firewall = { zone = 'wan' },
      },
    },
    dns = {
      enabled = true,
      domain = 'vm.bigbox.test',
      upstreams = { '1.1.1.1', '8.8.8.8' },
      cache = { size = 1000 },
      records = { router = { name = 'config.vm.bigbox.test', address = '192.168.1.1' } },
    },
    dhcp = { defaults = { authoritative = true } },
    firewall = {
      defaults = { input = 'REJECT', output = 'ACCEPT', forward = 'REJECT' },
      zones = {
        lan = { input = 'ACCEPT', output = 'ACCEPT', forward = 'REJECT' },
        wan = { input = 'REJECT', output = 'ACCEPT', forward = 'REJECT', masq = true, mtu_fix = true },
      },
      policies = { lan_to_wan = { src = 'lan', dest = 'wan' } },
    },
    routing = { routes = {} },
    wan = {
      enabled = true,
      load_balancing = { policy = 'balanced', speedtests = true },
      last_resort = 'unreachable',
      health = { family = 'ipv4', reliability = 1, count = 1, timeout = 1, interval = 2, up = 1, down = 1, initial_state = 'online' },
      rules = {
        https = { family = 'ipv4', proto = 'tcp', dest_port = '443', policy = 'balanced', sticky = true },
      },
      members = {
        wan = { interface = 'wan', mwan_metric = 1, weight = 50, track_ip = '172.31.1.2' },
        wanb = { interface = 'wanb', mwan_metric = 1, weight = 30, track_ip = '172.31.2.2' },
        wanc = { interface = 'wanc', mwan_metric = 1, weight = 20, track_ip = '172.31.3.2' },
      },
    },
    shaping = {}, vpn = {}, diagnostics = {},
  }
end

return M
