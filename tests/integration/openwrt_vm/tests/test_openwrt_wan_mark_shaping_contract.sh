#!/usr/bin/env sh
set -eu

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
VM_DIR="$(dirname "$SCRIPT_DIR")"
ROOT_DIR="$(CDPATH= cd -- "$VM_DIR/../../.." && pwd)"
SCP_TO="$VM_DIR/scripts/scp-to"
STAGE_DEVICECODE="$VM_DIR/scripts/ensure-devicecode-staged"
SSH="$VM_DIR/scripts/ssh"
WORK="$VM_DIR/work/wan-mark-shaping-contract"
REMOTE="/tmp/devicecode-wan-mark-shaping-contract"

mkdir -p "$WORK"
cat > "$WORK/run_openwrt_wan_mark_shaping_contract.lua" <<'LUA'
package.path = table.concat({
  './src/?.lua', './src/?/init.lua',
  './vendor/lua-fibers/src/?.lua', './vendor/lua-fibers/src/?/init.lua',
  './vendor/lua-bus/src/?.lua', './vendor/lua-bus/src/?/init.lua',
  './vendor/lua-trie/src/?.lua', './vendor/lua-trie/src/?/init.lua',
  package.path,
}, ';')

local fibers = require 'fibers'
local provider_loader = require 'services.hal.backends.network.provider'

local function fail(msg) error(msg, 2) end
local function contains(s, needle, msg)
  if type(s) ~= 'string' or not s:find(needle, 1, true) then fail(msg or ('missing ' .. tostring(needle))) end
end

local cmds = {}
local restores = {}
local provider = assert(provider_loader.new({
  provider = 'openwrt',
  allow_fake_uci = true,
  debounce_s = 0.01,
  run_cmd = function(_argv) return true, '', nil end,
  shaper_run_cmd = function(argv)
    cmds[#cmds + 1] = table.concat(argv, ' ')
    return true, '', nil
  end,
  shaper_run_restore = function(payload)
    restores[#restores + 1] = payload
    return true, nil, ''
  end,
}, {}))

local intent = {
  schema = 'devicecode.net.intent/1', rev = 1,
  segments = { wan = { kind = 'wan', firewall = { zone = 'wan' } } },
  interfaces = {
    wan = { kind = 'ethernet', role = 'wan', segment = 'wan', endpoint = { ifname = 'eth1' }, addressing = { ipv4 = { mode = 'dhcp' } } },
  },
  firewall = { zones = { wan = { masq = true } }, policies = {}, rules = {} },
  routing = {}, dns = {}, dhcp = {}, vpn = {}, diagnostics = {},
  wan = {
    enabled = true,
    members = {
      wired = {
        interface = 'wan', mwan_metric = 1, weight = 1,
        shaping = { download = { limit = '80mbit' }, upload = { limit = '20mbit' } },
      },
    },
  },
  shaping = { enabled = true },
}

fibers.run(function()
  local result = fibers.perform(provider:apply_op({ intent = intent }))
  assert(result and result.ok == true, 'apply failed: ' .. tostring(result and result.err))
  provider:terminate('test complete')
end)

if #restores ~= 1 then fail('expected one iptables-restore payload, got ' .. tostring(#restores)) end
local restore = restores[1]
contains(restore, ':DEVICECODE_SHAPING_OUTPUT', 'output chain expected')
contains(restore, ':DEVICECODE_SHAPING_FORWARD', 'forward chain expected')
contains(restore, '-A DEVICECODE_SHAPING_OUTPUT -o eth1', 'router-originated traffic should be marked on WAN')
contains(restore, 'devicecode-shaping router exempt', 'router exemption comment expected')
contains(restore, '-A DEVICECODE_SHAPING_FORWARD -o eth1', 'forwarded client traffic should be marked on WAN')
contains(restore, 'CONNMARK --save-mark --mask 0x00f00000', 'marks should be saved to conntrack')

local all = table.concat(cmds, '\n')
contains(all, 'tc qdisc add dev eth1 root handle 1: htb default 20', 'WAN upload root qdisc expected')
contains(all, 'tc class replace dev eth1 parent 1:1 classid 1:10 htb rate 1gbit ceil 1gbit', 'router/control class should be high-rate')
contains(all, 'tc class replace dev eth1 parent 1:1 classid 1:20 htb rate 20mbit ceil 20mbit', 'client upload class should be limited')
contains(all, 'tc filter add dev eth1 parent ffff: protocol ip prio 1 u32 match u32 0 0 action ctinfo cpmark 0x00f00000 action mirred egress redirect dev ifb_eth1', 'download path should restore connmark before IFB redirect')
contains(all, 'tc class replace dev ifb_eth1 parent 1:1 classid 1:20 htb rate 80mbit ceil 80mbit', 'client download class should be limited')

print('openwrt wan mark shaping contract: ok')
LUA

"$SSH" "rm -rf '$REMOTE'; mkdir -p '$REMOTE'"
CODE_REMOTE="$($STAGE_DEVICECODE)"
"$SCP_TO" "$WORK/run_openwrt_wan_mark_shaping_contract.lua" "$REMOTE/run.lua"
"$SSH" "cd '$CODE_REMOTE' && lua '$REMOTE/run.lua'"
