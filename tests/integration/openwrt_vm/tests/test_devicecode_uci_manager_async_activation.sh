#!/usr/bin/env sh
set -eu

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
VM_DIR="$(dirname "$SCRIPT_DIR")"
ROOT_DIR="$(CDPATH= cd -- "$VM_DIR/../../.." && pwd)"
SSH="$VM_DIR/scripts/ssh"
SCP_TO="$VM_DIR/scripts/scp-to"
REMOTE="/tmp/devicecode-uci-manager-async-activation-test"
WORK="$VM_DIR/work/uci-manager-async-activation-test"

mkdir -p "$WORK"

cat > "$WORK/run_devicecode_uci_manager_async_activation.lua" <<'LUA'
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
local uci_manager = require 'services.hal.backends.openwrt.uci_manager'

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

local tmp = '/tmp/dc-devicecode-uci-manager-async-activation'
os.execute("rm -rf '" .. tmp .. "'")
local conf = tmp .. '/conf'
local save = tmp .. '/save'
mkdir_p(conf)
mkdir_p(save)
local f = assert(io.open(conf .. '/network', 'w'))
f:write('# devicecode async activation integration test\n')
f:close()

local run_started = false
local run_finished = false
local restarts = {}
local unblock_tx, unblock_rx = mailbox.new(1, { full = 'reject_newest' })
local result = nil

fibers.run(function(scope)
  local mgr, merr = uci_manager.new({
    confdir = conf,
    savedir = save,
    allow_fake = false,
    debounce_s = 0.01,
    run_cmd = function(argv)
      restarts[#restarts + 1] = table.concat(argv, ' ')
      run_started = true
      perform(unblock_rx:recv_op())
      run_finished = true
      return true, nil
    end,
  })
  assert(mgr, merr)
  assert(mgr:start(scope))

  scope:spawn(function()
    result = perform(mgr:transaction_op({
      packages = { 'network' },
      records = {
        {
          config = 'network',
          changes = {
            { op = 'set', config = 'network', section = 'lan', option = 'interface' },
            { op = 'set', config = 'network', section = 'lan', option = 'proto', value = 'static' },
          },
          restart_cmds = { { kind = 'reload', target = 'network', wait = false } },
        },
      },
      rollback = true,
      trace = { what = 'openwrt_vm_async_activation_contract', generation = 1 },
    }))
  end)

  wait_until(function() return run_started == true end, 5, 'activation runner should start scheduled command')
  eq(restarts[1], '/etc/init.d/network reload', 'activation command')

  wait_until(function() return result ~= nil end, 5, 'transaction should reply while async activation command is blocked')
  assert_true(result.ok == true, 'transaction failed: ' .. tostring(result.err))
  assert_true(result.activation and result.activation.state == 'scheduled', 'activation should be scheduled')
  eq(result.activation.commands, 1, 'scheduled command count')
  eq(run_finished, false, 'transaction reply must not wait for activation command completion')

  local c = assert(uci.cursor(conf, save))
  if type(c.load) == 'function' then pcall(function() c:load('network') end) end
  eq(c:get('network', 'lan'), 'interface', 'network.lan section committed before activation completion')
  eq(c:get('network', 'lan', 'proto'), 'static', 'network.lan proto committed before activation completion')

  assert(unblock_tx:send(true))
  wait_until(function() return run_finished == true end, 1, 'activation command should finish after release')
  eq(mgr:activation_status().state, 'done', 'activation status after command completion')

  mgr:terminate('test complete')
end)

print('devicecode UCI manager async activation contract: ok')
LUA

"$SSH" "rm -rf '$REMOTE'; mkdir -p '$REMOTE'"
"$SCP_TO" "$ROOT_DIR/src" "$REMOTE/src"
"$SCP_TO" "$ROOT_DIR/vendor" "$REMOTE/vendor"
"$SCP_TO" "$WORK/run_devicecode_uci_manager_async_activation.lua" "$REMOTE/run_devicecode_uci_manager_async_activation.lua"
"$SSH" "cd '$REMOTE' && lua ./run_devicecode_uci_manager_async_activation.lua"
