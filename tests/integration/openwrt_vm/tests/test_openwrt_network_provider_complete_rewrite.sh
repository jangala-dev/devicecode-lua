#!/usr/bin/env sh
set -eu

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
VM_DIR="$(dirname "$SCRIPT_DIR")"
ROOT_DIR="$(CDPATH= cd -- "$VM_DIR/../../.." && pwd)"
SSH="$VM_DIR/scripts/ssh"
SCP_TO="$VM_DIR/scripts/scp-to"
REMOTE="/tmp/devicecode-network-provider-complete-rewrite-test"
WORK="$VM_DIR/work/network-provider-complete-rewrite-test"

mkdir -p "$WORK"
cat > "$WORK/run_openwrt_network_provider_complete_rewrite.lua" <<'LUA'
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
local function eq(a, b, msg) if a ~= b then fail((msg or 'values differ') .. ': expected ' .. tostring(b) .. ', got ' .. tostring(a)) end end
local function mkdir_p(path) local ok = os.execute("mkdir -p '" .. path .. "'"); if ok ~= true and ok ~= 0 then fail('mkdir failed for ' .. path) end end

local tmp = '/tmp/dc-network-provider-complete-rewrite'
os.execute("rm -rf '" .. tmp .. "'")
local conf, save = tmp .. '/conf', tmp .. '/save'
mkdir_p(conf); mkdir_p(save)

-- Deliberately create only two stale files.  The provider/manager must create
-- missing packages and must completely replace stale package contents.
local f = assert(io.open(conf .. '/network', 'w'))
f:write([[config interface 'lan'
  option proto 'dhcp'
  option stale_option 'must_disappear'

config interface 'oldwan'
  option proto 'dhcp'
]])
f:close()
f = assert(io.open(conf .. '/dhcp', 'w'))
f:write([[config dhcp 'lan'
  option interface 'lan'
  option instance 'old_dnsmasq'
  option stale_option 'must_disappear'

config dnsmasq 'old_dnsmasq'
  option domainneeded '1'
]])
f:close()

local intent = {
  schema = 'devicecode.net.intent/1', rev = 1,
  segments = {
    lan = { kind = 'lan', vlan = { id = 10 }, addressing = { ipv4 = { mode = 'static', cidr = '192.168.10.1/24' } }, dhcp = { enabled = true }, dns = { local_server = true }, firewall = { zone = 'lan' } },
  },
  interfaces = {},
  dns = { enabled = true, domain = 'bigbox.home', upstreams = { '1.1.1.1' } },
  dhcp = {}, firewall = { zones = { lan = {} } }, routing = {}, wan = {}, shaping = {}, vpn = {}, diagnostics = {},
}

fibers.run(function()
  local provider = assert(provider_loader.new({ provider = 'openwrt', confdir = conf, savedir = save, debounce_s = 0.01, platform = { segment_trunk = { ifname = 'eth0' } }, run_cmd = function() return true, nil end }, {}))
  local result = perform(provider:apply_op({ intent = intent }))
  assert(result and result.ok == true, 'apply failed: ' .. tostring(result and result.err))
  provider:terminate('test complete')
end)

for _, pkg in ipairs({ 'network', 'dhcp', 'firewall', 'mwan3' }) do
  local fh = io.open(conf .. '/' .. pkg, 'rb')
  if not fh then fail('missing generated package file ' .. pkg) end
  fh:close()
end

local c = assert(uci.cursor(conf, save))
for _, pkg in ipairs({ 'network', 'dhcp', 'firewall', 'mwan3' }) do if type(c.load) == 'function' then pcall(function() c:load(pkg) end) end end

eq(c:get('network', 'oldwan'), nil, 'stale network section removed')
eq(c:get('network', 'lan', 'stale_option'), nil, 'stale network option removed from recreated section')
eq(c:get('dhcp', 'old_dnsmasq'), nil, 'stale dnsmasq removed')
local dhcp_sec = nil
for name, sec in pairs(c:get_all('dhcp') or {}) do if type(sec) == 'table' and sec['.type'] == 'dhcp' and sec.interface == 'lan' then dhcp_sec = sec end end
assert(dhcp_sec, 'lan dhcp section expected')
eq(dhcp_sec.stale_option, nil, 'stale dhcp option removed')
if dhcp_sec.instance == 'old_dnsmasq' then fail('dhcp instance should not point to stale dnsmasq') end

eq(c:get('network', 'loopback'), 'interface', 'loopback generated')
eq(c:get('network', 'loopback', 'device'), 'lo', 'loopback device')

for _, pkg in ipairs({ 'network', 'dhcp', 'firewall', 'mwan3' }) do
  for name, sec in pairs(c:get_all(pkg) or {}) do
    if type(sec) == 'table' then
      for _, opt in ipairs({ 'devicecode_managed', 'devicecode_owner', 'devicecode_semantic_id', 'devicecode_role' }) do
        if sec[opt] ~= nil then fail('unexpected UCI metadata ' .. pkg .. '.' .. tostring(name) .. '.' .. opt) end
      end
    end
  end
end
print('openwrt complete rewrite and missing package creation: ok')
LUA

"$SSH" "rm -rf '$REMOTE'; mkdir -p '$REMOTE'"
"$SCP_TO" "$ROOT_DIR/src" "$REMOTE/src"
"$SCP_TO" "$ROOT_DIR/vendor" "$REMOTE/vendor"
"$SCP_TO" "$WORK/run_openwrt_network_provider_complete_rewrite.lua" "$REMOTE/run_openwrt_network_provider_complete_rewrite.lua"
"$SSH" "cd '$REMOTE' && lua ./run_openwrt_network_provider_complete_rewrite.lua"
