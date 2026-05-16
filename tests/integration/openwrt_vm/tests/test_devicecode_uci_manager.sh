#!/usr/bin/env sh
set -eu

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
VM_DIR="$(dirname "$SCRIPT_DIR")"
ROOT_DIR="$(CDPATH= cd -- "$VM_DIR/../../.." && pwd)"
SSH="$VM_DIR/scripts/ssh"
SCP_TO="$VM_DIR/scripts/scp-to"
REMOTE="/tmp/devicecode-uci-manager-test"
WORK="$VM_DIR/work/uci-manager-test"

mkdir -p "$WORK"

cat > "$WORK/run_devicecode_uci_manager.lua" <<'LUA'
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
local bus = require 'bus'
local trie = require 'trie'
local uci = require 'uci'
local uci_manager = require 'services.hal.backends.openwrt.uci_manager'
local compat = require 'services.hal.backends.common.uci'

assert(type(bus.new) == 'function', 'vendored bus did not load')
assert(type(trie.new_pubsub) == 'function', 'vendored trie did not load')

local perform = fibers.perform

local function fail(msg)
  error(msg, 2)
end

local function eq(a, b, msg)
  if a ~= b then
    fail((msg or 'values differ') .. ': expected ' .. tostring(b) .. ', got ' .. tostring(a))
  end
end

local function assert_list(v, expected, label)
  if type(v) ~= 'table' then
    fail((label or 'list') .. ' should be a table, got ' .. type(v))
  end
  eq(#v, #expected, (label or 'list') .. ' length')
  for i = 1, #expected do
    eq(v[i], expected[i], (label or 'list') .. '[' .. i .. ']')
  end
end

local function mkdir_p(path)
  local ok = os.execute("mkdir -p '" .. path .. "'")
  if ok ~= true and ok ~= 0 then fail('mkdir failed for ' .. path) end
end

local tmp = '/tmp/dc-devicecode-uci-manager'
os.execute("rm -rf '" .. tmp .. "'")
local conf = tmp .. '/conf'
local save = tmp .. '/save'
mkdir_p(conf)
mkdir_p(save)
local f = assert(io.open(conf .. '/dcuci', 'w'))
f:write('# devicecode manager integration test\n')
f:close()

local restarts = {}

fibers.run(function(scope)
  local mgr, merr = uci_manager.new({
    confdir = conf,
    savedir = save,
    allow_fake = false,
    debounce_s = 0.02,
    run_cmd = function(argv)
      restarts[#restarts + 1] = table.concat(argv, ' ')
      return true, nil
    end,
  })
  assert(mgr, merr)
  local fake, note = mgr:fake_mode()
  eq(fake, false, 'manager should use real libuci-lua')
  assert(note == nil or note == false, 'unexpected fake-mode note: ' .. tostring(note))
  assert(mgr:start(scope))

  local s = mgr:new_session()
  s:set('dcuci', 'named', 'example')
  s:set('dcuci', 'named', 'enabled', true)
  s:set('dcuci', 'named', 'count', 7)
  s:set('dcuci', 'named', 'listopt', { 'one', 'two' })
  local anon = s:add('dcuci', 'thing')
  s:set('dcuci', anon, 'name', 'anonymous')
  s:add_list('dcuci', 'named', 'listopt', 'three')
  s:del_list('dcuci', 'named', 'listopt', 'one')
  s:rename('dcuci', anon, 'anon_named')
  s:reorder('dcuci', 'anon_named', 0)

  local ok, err = perform(s:commit_op('dcuci', {
    { kind = 'reload', target = 'network' },
    { '/etc/init.d/network', 'reload' },
    { kind = 'reload', target = 'wifi' },
  }))
  assert(ok, 'commit_op failed: ' .. tostring(err))

  local s2 = mgr:new_session()
  s2:rename('dcuci', 'named', 'count', 'renamed_count')
  s2:delete('dcuci', 'named', 'enabled')
  local ok2, err2 = s2:commit('dcuci')
  assert(ok2, 'compat blocking commit failed: ' .. tostring(err2))

  compat.bind_manager(mgr)
  local cs = compat.new_session()
  cs:set('dcuci', 'compat_named', 'example')
  cs:set('dcuci', 'compat_named', 'flag', false)
  local cok, cerr = cs:commit('dcuci')
  assert(cok, 'common UCI compatibility commit failed: ' .. tostring(cerr))
  eq(compat.manager_owner(), 'bound', 'compat manager should be bound')
  compat.clear_bound_manager()

  mgr:terminate('test complete')
end)

eq(#restarts, 2, 'restart deduplication should leave network and wifi only')
eq(restarts[1], '/etc/init.d/network reload', 'first restart')
eq(restarts[2], '/sbin/wifi reload', 'second restart')

local c = assert(uci.cursor(conf, save))
if type(c.load) == 'function' then pcall(function() c:load('dcuci') end) end

eq(c:get('dcuci', 'named', 'enabled'), nil, 'enabled should have been deleted')
eq(c:get('dcuci', 'named', 'renamed_count'), '7', 'renamed option')
assert_list(c:get('dcuci', 'named', 'listopt'), { 'two', 'three' }, 'listopt')
eq(c:get('dcuci', 'anon_named', 'name'), 'anonymous', 'renamed anonymous section')
eq(c:get('dcuci', 'compat_named', 'flag'), '0', 'compat boolean false')

local seen_thing = false
assert(c:foreach('dcuci', 'thing', function(section)
  if section['.name'] == 'anon_named' then
    seen_thing = true
  end
end))
assert(seen_thing, 'foreach did not see renamed anonymous section')

print('devicecode UCI manager on OpenWrt: ok')
LUA

"$SSH" "rm -rf '$REMOTE'; mkdir -p '$REMOTE'"
"$SCP_TO" "$ROOT_DIR/src" "$REMOTE/src"
"$SCP_TO" "$ROOT_DIR/vendor" "$REMOTE/vendor"
"$SCP_TO" "$WORK/run_devicecode_uci_manager.lua" "$REMOTE/run_devicecode_uci_manager.lua"
"$SSH" "cd '$REMOTE' && lua ./run_devicecode_uci_manager.lua"
