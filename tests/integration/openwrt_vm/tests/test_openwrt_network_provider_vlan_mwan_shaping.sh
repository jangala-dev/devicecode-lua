#!/usr/bin/env sh
set -eu

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
VM_DIR="$(dirname "$SCRIPT_DIR")"
ROOT_DIR="$(CDPATH= cd -- "$VM_DIR/../../.." && pwd)"
SSH="$VM_DIR/scripts/ssh"
SCP_TO="$VM_DIR/scripts/scp-to"
REMOTE="/tmp/devicecode-network-provider-advanced-test"
WORK="$VM_DIR/work/network-provider-advanced-test"

mkdir -p "$WORK"
cat > "$WORK/run_openwrt_network_provider_advanced.lua" <<'LUA'
package.path = table.concat({
  './src/?.lua', './src/?/init.lua',
  './vendor/lua-fibers/src/?.lua', './vendor/lua-fibers/src/?/init.lua',
  './vendor/lua-bus/src/?.lua', './vendor/lua-bus/src/?/init.lua',
  './vendor/lua-trie/src/?.lua', './vendor/lua-trie/src/?/init.lua',
  package.path,
}, ';')

local fibers = require 'fibers'
local uci = require 'uci'
local provider_loader = require 'services.hal.backends.network.provider'
local perform = fibers.perform

local function fail(msg) error(msg, 2) end
local function eq(a,b,msg) if a ~= b then fail((msg or 'values differ') .. ': expected '..tostring(b)..', got '..tostring(a)) end end
local function mkdir_p(path) local ok = os.execute("mkdir -p '"..path.."'"); if ok ~= true and ok ~= 0 then fail('mkdir failed') end end

local tmp = '/tmp/dc-network-provider-advanced'
os.execute("rm -rf '"..tmp.."'")
local conf, save = tmp..'/conf', tmp..'/save'
mkdir_p(conf); mkdir_p(save)
for _, pkg in ipairs({ 'network', 'dhcp', 'firewall', 'mwan3' }) do local f=assert(io.open(conf..'/'..pkg,'w')); f:write('# test\n'); f:close() end

local shaper_cmds, restarts, live_cmds = {}, {}, {}
local provider = assert(provider_loader.new({
  provider = 'openwrt', confdir = conf, savedir = save, debounce_s = 0.01,
  run_cmd = function(argv) restarts[#restarts+1] = table.concat(argv, ' '); return true, nil end,
  shaper_run_cmd = function(argv) shaper_cmds[#shaper_cmds+1] = table.concat(argv, ' '); return true, nil end,
  speedtest_run_cmd = function(argv) return true, '55', nil end,
  mwan_run_cmd_capture = function(argv)
    if table.concat(argv, ' ') ~= 'iptables-save -t mangle' then return nil, '', 'unexpected capture command' end
    return true, [[
*mangle
:mwan3_iface_in_wan_a - [0:0]
:mwan3_iface_in_wan_b - [0:0]
:mwan3_policy_balanced - [0:0]
-A mwan3_iface_in_wan_a -i wwan0 -m mark --mark 0x0/0x3f00 -m comment --comment wan_a -j MARK --set-xmark 0x100/0x3f00
-A mwan3_iface_in_wan_b -i wwan1 -m mark --mark 0x0/0x3f00 -m comment --comment wan_b -j MARK --set-xmark 0x300/0x3f00
-A mwan3_policy_balanced -m mark --mark 0x0/0x3f00 -m statistic --mode random --probability 0.50000000000 -m comment --comment "wan_b 1 2" -j MARK --set-xmark 0x300/0x3f00
-A mwan3_policy_balanced -m mark --mark 0x0/0x3f00 -m comment --comment "wan_a 1 1" -j MARK --set-xmark 0x100/0x3f00
COMMIT
]], nil
  end,
  mwan_run_cmd = function(argv) live_cmds[#live_cmds+1] = table.concat(argv, ' '); return true, nil end,
}, {}))

local intent = {
  schema = 'devicecode.net.intent/1', rev = 303,
  segments = {
    lan = { kind='lan', vlan={id=10}, addressing={ipv4={mode='static', cidr='192.168.10.1/24'}}, dhcp={enabled=true}, firewall={zone='lan'} },
    wan = { kind='wan', firewall={zone='wan'} },
  },
  interfaces = {
    lan = { kind='bridge', role='lan', segment='lan', members={'eth0'}, addressing={ipv4={mode='static', cidr='192.168.10.1/24'}} },
    wan_a = { kind='cellular', role='wan', segment='wan', endpoint={ifname='wwan0'}, addressing={ipv4={mode='dhcp', metric=10}} },
    wan_b = { kind='cellular', role='wan', segment='wan', endpoint={ifname='wwan1'}, addressing={ipv4={mode='dhcp', metric=20}} },
  },
  firewall = { zones={lan={}, wan={masq=true}}, policies={lan_to_wan={from='lan', to='wan'}} },
  routing={}, dns={}, dhcp={}, vpn={}, diagnostics={},
  wan = { enabled=true, policy='weighted_failover', load_balancing={speedtests=true, policy='balanced'}, members={ gsm_a={interface='wan_a', metric=1, weight=1}, gsm_b={interface='wan_b', metric=1, weight=1} } },
  shaping = { enabled=true, links={ wan_a={ iface='wwan0', egress={enabled=true, host_rate='2mbit', hosts={['192.168.10.2']={rate='1mbit'}}} } } },
}

fibers.run(function()
  local plan = perform(provider:plan_op({ intent = intent }))
  assert(plan.ok == true, plan.err)
  eq(plan.plan.domains.vlan.status, 'implemented', 'vlan domain')
  eq(plan.plan.domains.multiwan.status, 'implemented', 'mwan domain')
  local result = perform(provider:apply_op({ intent = intent }))
  assert(result.ok == true, result.err)
  local speed = perform(provider:speedtest_op({ interface='wan_a', device='wwan0' }))
  eq(speed.peak_mbps, 55, 'speedtest fake result')
  local live = perform(provider:apply_live_weights_op({ policy='balanced', members={{link_id='gsm_a', interface='wan_a', metric=1, weight=80},{link_id='gsm_b', interface='wan_b', metric=1, weight=20}}, persist=true }))
  assert(live.ok == true, live.err)
  provider:terminate('test complete')
end)

if #shaper_cmds == 0 then fail('shaper commands expected') end
if #live_cmds ~= 3 then fail('live weight commands expected') end
if not live_cmds[2]:find('%-%-probability 0.80000000000') then fail('live first-member probability expected') end
local joined = table.concat(restarts, '\n')
if joined:find('mwan3', 1, true) then fail('mwan3 restart must not be used') end

local c = assert(uci.cursor(conf, save))
for _, pkg in ipairs({ 'network', 'mwan3' }) do if type(c.load) == 'function' then pcall(function() c:load(pkg) end) end end
if c:get('network', 'dev_lan_10') then
  eq(c:get('network', 'dev_lan_10'), 'device', 'vlan device type')
  eq(c:get('network', 'dev_lan_10', 'vid'), '10', 'vlan vid')
end
eq(c:get('mwan3', 'balanced'), 'policy', 'mwan balanced policy')
eq(c:get('mwan3', 'default_rule_v4'), 'rule', 'mwan default rule')
print('openwrt network provider VLAN/MWAN/shaping: ok')
LUA

"$SSH" "rm -rf '$REMOTE'; mkdir -p '$REMOTE'"
"$SCP_TO" "$ROOT_DIR/src" "$REMOTE/src"
"$SCP_TO" "$ROOT_DIR/vendor" "$REMOTE/vendor"
"$SCP_TO" "$WORK/run_openwrt_network_provider_advanced.lua" "$REMOTE/run_openwrt_network_provider_advanced.lua"
"$SSH" "cd '$REMOTE' && lua ./run_openwrt_network_provider_advanced.lua"
