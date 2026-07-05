#!/usr/bin/env sh
set -eu

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
VM_DIR="$(dirname "$SCRIPT_DIR")"
ROOT_DIR="$(CDPATH= cd -- "$VM_DIR/../../.." && pwd)"
SSH="$VM_DIR/scripts/ssh"
SCP_TO="$VM_DIR/scripts/scp-to"
REMOTE="/tmp/devicecode-network-provider-async-activation-test"
WORK="$VM_DIR/work/network-provider-async-activation-test"

mkdir -p "$WORK"

cat > "$WORK/run_openwrt_network_provider_async_activation.lua" <<'LUA'
package.path = table.concat({
  './src/?.lua',
  './src/?/init.lua',
  './vendor/lua-fibers/src/?.lua',
  './vendor/lua-fibers/src/?/init.lua',
  './vendor/lua-bus/src/?.lua',
  './vendor/lua-bus/src/?/init.lua',
  './vendor/lua-trie/src/?.lua',
  './vendor/lua-trie/src/?/init.lua',
  package.path,
}, ';')

local fibers = require 'fibers'
local sleep = require 'fibers.sleep'
local mailbox = require 'fibers.mailbox'
local uci = require 'uci'
local provider_loader = require 'services.hal.backends.network.provider'

local perform = fibers.perform

local function fail(msg) error(msg, 2) end
local function eq(a, b, msg)
  if a ~= b then fail((msg or 'values differ') .. ': expected ' .. tostring(b) .. ', got ' .. tostring(a)) end
end
local function assert_true(v, msg) if not v then fail(msg or 'assertion failed') end end

local function mkdir_p(path)
  local ok = os.execute("mkdir -p '" .. path .. "'")
  if ok ~= true and ok ~= 0 then fail('mkdir failed for ' .. path) end
end

local function wait_until(pred, timeout_s, label)
  local deadline = fibers.now() + (timeout_s or 1)
  while fibers.now() < deadline do
    if pred() then return true end
    perform(sleep.sleep_op(0.01))
  end
  if pred() then return true end
  fail(label or 'condition was not satisfied before timeout')
end

local tmp = '/tmp/dc-openwrt-provider-async-activation'
os.execute("rm -rf '" .. tmp .. "'")
local conf = tmp .. '/conf'
local save = tmp .. '/save'
mkdir_p(conf)
mkdir_p(save)
for _, pkg in ipairs({ 'network', 'dhcp', 'firewall', 'mwan3' }) do
  local f = assert(io.open(conf .. '/' .. pkg, 'w'))
  f:write('# devicecode provider synchronous activation integration test\n')
  f:close()
end

local intent = {
  schema = 'devicecode.net.intent/1',
  rev = 909,
  generation = 44,
  segments = {
    lan = {
      kind = 'lan',
      addressing = { ipv4 = { mode = 'static', cidr = '192.168.10.1/24' } },
      dhcp = { enabled = true, start = 20, limit = 50, leasetime = '6h' },
      dns = { local_server = true, domain = 'bigbox.home' },
      firewall = { zone = 'lan' },
    },
    wan = { kind = 'wan', firewall = { zone = 'wan' } },
  },
  interfaces = {
    lan = {
      kind = 'bridge', role = 'lan', segment = 'lan', members = { 'eth0' },
      addressing = { ipv4 = { mode = 'static', cidr = '192.168.10.1/24' } },
    },
    wan = {
      kind = 'ethernet', role = 'wan', segment = 'wan', endpoint = { ifname = 'eth1' },
      addressing = { ipv4 = { mode = 'dhcp', peerdns = false } },
    },
  },
  dns = { enabled = true, domain = 'bigbox.home', upstreams = { '1.1.1.1' }, cache = { size = 1000 } },
  dhcp = { defaults = { authoritative = true } },
  firewall = {
    defaults = { input = 'REJECT', output = 'ACCEPT', forward = 'REJECT' },
    zones = { lan = { input = 'ACCEPT', output = 'ACCEPT', forward = 'REJECT' }, wan = { masq = true, mtu_fix = true } },
    policies = { lan_to_wan = { src = 'lan', dest = 'wan' } },
  },
  routing = { routes = {} },
  wan = { enabled = true, members = { wan = { interface = 'wan', mwan_metric = 1, weight = 1 } } },
  
  vpn = {},
  diagnostics = {},
}

local restarts = {}
local run_started = false
local run_finished = false
local unblock_tx, unblock_rx = mailbox.new(1, { full = 'reject_newest' })
local result = nil
local provider = nil

fibers.run(function(scope)
  provider = assert(provider_loader.new({
    provider = 'openwrt',
    confdir = conf,
    savedir = save,
    debounce_s = 0.01,
    run_cmd = function(argv)
      restarts[#restarts + 1] = table.concat(argv, ' ')
      run_started = true
      if #restarts == 1 then
        perform(unblock_rx:recv_op())
      end
      run_finished = true
      return true, nil
    end,
  }, {}))

  scope:spawn(function()
    result = perform(provider:apply_op({ intent = intent, opts = { generation = 44, apply_id = 7 } }))
  end)

  -- Provider structural apply now owns activation completion.  The apply result
  -- must not be reported while network/dnsmasq/firewall/mwan3 activation is
  -- still blocked.
  wait_until(function() return run_started == true end, 5, 'activation should start first command')
  eq(restarts[1], '/etc/init.d/network reload', 'first activation command')
  perform(sleep.sleep_op(0.05))
  assert_true(result == nil, 'provider apply must wait for activation command completion')

  local c = assert(uci.cursor(conf, save))
  if type(c.load) == 'function' then pcall(function() c:load('network') end) end
  eq(c:get('network', 'lan'), 'interface', 'network.lan committed before activation completion')
  eq(c:get('network', 'lan', 'proto'), 'static', 'network.lan proto committed before activation completion')

  assert(unblock_tx:send(true))
  wait_until(function() return result ~= nil end, 5, 'provider apply should complete after activation is released')
  assert_true(result.ok == true, 'provider apply failed: ' .. tostring(result.err))
  assert_true(result.transaction and result.transaction.ok == true, 'transaction should succeed')
  assert_true(result.activation == nil, 'synchronous provider activation should not return a scheduled activation token')

  eq(#restarts, 4, 'provider should run network, dnsmasq, firewall and mwan3 activation before reply')
  eq(restarts[2], '/etc/init.d/dnsmasq restart', 'second activation command')
  eq(restarts[3], '/etc/init.d/firewall restart', 'third activation command')
  eq(restarts[4], '/etc/init.d/mwan3 restart', 'fourth activation command')

  provider:terminate('test complete')
end)

print('openwrt network provider synchronous activation contract: ok')
LUA

"$SSH" "rm -rf '$REMOTE'; mkdir -p '$REMOTE'"
"$SCP_TO" "$ROOT_DIR/src" "$REMOTE/src"
"$SCP_TO" "$ROOT_DIR/vendor" "$REMOTE/vendor"
"$SCP_TO" "$WORK/run_openwrt_network_provider_async_activation.lua" "$REMOTE/run_openwrt_network_provider_async_activation.lua"
"$SSH" "cd '$REMOTE' && lua ./run_openwrt_network_provider_async_activation.lua"
