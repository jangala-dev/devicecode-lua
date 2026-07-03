#!/usr/bin/env sh
set -eu

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
VM_DIR="$(dirname "$SCRIPT_DIR")"
ROOT_DIR="$(CDPATH= cd -- "$VM_DIR/../../.." && pwd)"
SSH="$VM_DIR/scripts/ssh"
SCP_TO="$VM_DIR/scripts/scp-to"
REMOTE="/tmp/devicecode-exec-containment-test"
WORK="$VM_DIR/work/exec-containment-test"

mkdir -p "$WORK"

cat > "$WORK/run_devicecode_exec_containment.lua" <<'LUA'
package.path = table.concat({
  './src/?.lua', './src/?/init.lua',
  './vendor/lua-fibers/src/?.lua', './vendor/lua-fibers/src/?/init.lua',
  './vendor/lua-bus/src/?.lua', './vendor/lua-bus/src/?/init.lua',
  './vendor/lua-trie/src/?.lua', './vendor/lua-trie/src/?/init.lua',
  package.path,
}, ';')

local fibers = require 'fibers'
local exec = require 'fibers.io.exec'
local op = require 'fibers.op'
local sleep = require 'fibers.sleep'

local perform = fibers.perform

math.randomseed(os.time())

local function fail(msg)
  error(msg, 2)
end

local function read_file(path)
  local f = io.open(path, 'r')
  if not f then return nil end
  local s = f:read('*a')
  f:close()
  return s
end

local function file_exists(path)
  local f = io.open(path, 'r')
  if f then f:close(); return true end
  return false
end

local function pid_alive(pid)
  pid = tonumber(pid)
  if not pid then return false end
  local ok = os.execute(('kill -0 %d >/dev/null 2>&1'):format(pid))
  return ok == true or ok == 0
end

local function kill_pid(pid)
  pid = tonumber(pid)
  if pid then os.execute(('kill -KILL %d >/dev/null 2>&1 || true'):format(pid)) end
end

local function wait_until(pred, timeout_s)
  local deadline = fibers.now() + timeout_s
  while fibers.now() < deadline do
    if pred() then return true end
    perform(sleep.sleep_op(0.05))
  end
  return pred()
end

local function wait_for_proc(proc, timeout_s, label)
  local is_exit, status, code, sig, err = perform(op.boolean_choice(
    proc:run_op(),
    sleep.sleep_op(timeout_s)
  ))
  if not is_exit then
    pcall(function() proc:kill(9) end)
    fail(label .. ' did not exit within ' .. tostring(timeout_s) .. 's')
  end
  return status, code, sig, err
end

local function read_line_with_timeout(stream, timeout_s, label)
  local is_line, line, err = perform(op.boolean_choice(
    stream:read_line_op(),
    sleep.sleep_op(timeout_s)
  ))
  if not is_line then
    fail(label .. ' did not produce a line within ' .. tostring(timeout_s) .. 's')
  end
  if not line then
    fail(label .. ' closed before producing a line: ' .. tostring(err))
  end
  return line
end
local function test_process_group_shutdown_kills_grandchild()
  print('running: process_group_shutdown_kills_grandchild_on_openwrt')

  if type(exec.supports) == 'function' and not exec.supports('process_group') then
    print('skipping process_group test: backend does not advertise process_group')
    return
  end

  local marker = ('/tmp/dc-exec-pg-%d-%d'):format(os.time(), math.random(1000000))
  os.remove(marker)

  local script = [[
trap '' TERM
( trap '' TERM; while :; do sleep 1; done ) &
echo $! > "$1"
while :; do sleep 1; done
]]

  local proc = exec.command {
    'sh', '-c', script, 'sh', marker,
    stdin = 'null', stdout = 'pipe', stderr = 'stdout',
    flags = { process_group = true },
  }

  local out, start_err = proc:stdout_stream()
  assert(out, 'failed to start process-group command: ' .. tostring(start_err))
  assert(wait_until(function() return file_exists(marker) end, 3.0), 'grandchild pid marker was not written')

  local grandchild = tonumber((read_file(marker) or ''):match('(%d+)'))
  assert(grandchild, 'could not parse grandchild pid marker')
  assert(pid_alive(grandchild), 'grandchild was not alive before shutdown')

  local status, _code, _sig, err = perform(proc:shutdown_op(0.15))
  assert(status == 'exited' or status == 'signalled',
    'process-group command did not reach a terminal state: ' .. tostring(status) .. ' err=' .. tostring(err))

  local dead = wait_until(function() return not pid_alive(grandchild) end, 2.0)
  if not dead then kill_pid(grandchild) end
  assert(dead, 'grandchild remained alive after process-group shutdown: pid=' .. tostring(grandchild))
  os.remove(marker)
end

local function test_signal_bridge_sigterm_cleans_owned_grandchild()
  print('running: signal_bridge_sigterm_cleans_owned_grandchild_on_openwrt')

  if type(exec.supports) == 'function' and not exec.supports('process_group') then
    print('skipping signal bridge process cleanup test: backend does not advertise process_group')
    return
  end

  local marker = ('/tmp/dc-signal-bridge-%d-%d'):format(os.time(), math.random(1000000))
  os.remove(marker)

  local proc = exec.command {
    'lua', './signal_bridge_child.lua', marker,
    stdin = 'null', stdout = 'pipe', stderr = 'stdout',
  }
  local out, start_err = proc:stdout_stream()
  assert(out, 'failed to start signal bridge child: ' .. tostring(start_err))

  local line = read_line_with_timeout(out, 5.0, 'signal bridge child')
  local grandchild = tonumber(line:match('READY%s+(%d+)'))
  assert(grandchild, 'unexpected signal bridge child line: ' .. tostring(line))
  assert(pid_alive(grandchild), 'owned grandchild was not alive before SIGTERM')

  local ok, kill_err = proc:kill(15)
  assert(ok, 'failed to send SIGTERM to signal bridge child: ' .. tostring(kill_err))

  local status, code, sig, err = wait_for_proc(proc, 6.0, 'signal bridge child')
  assert(status == 'exited' or status == 'signalled',
    'signal bridge child did not terminate cleanly: status=' .. tostring(status) ..
    ' code=' .. tostring(code) .. ' sig=' .. tostring(sig) .. ' err=' .. tostring(err))

  local dead = wait_until(function() return not pid_alive(grandchild) end, 3.0)
  if not dead then kill_pid(grandchild) end
  assert(dead, 'owned grandchild remained alive after SIGTERM/root-scope cancellation: pid=' .. tostring(grandchild))
  os.remove(marker)
end

local function test_parent_death_signal_cleans_helper()
  print('running: parent_death_signal_cleans_helper_on_openwrt')

  if type(exec.supports) == 'function' and not exec.supports('parent_death_signal') then
    print('skipping parent_death_signal test: backend does not advertise parent_death_signal')
    return
  end

  local marker = ('/tmp/dc-parent-death-%d-%d'):format(os.time(), math.random(1000000))
  os.remove(marker)

  local proc = exec.command {
    'lua', './parent_death_launcher.lua', marker,
    stdin = 'null', stdout = 'pipe', stderr = 'stdout',
  }
  local out, start_err = proc:stdout_stream()
  assert(out, 'failed to start parent-death launcher: ' .. tostring(start_err))

  local line = read_line_with_timeout(out, 5.0, 'parent-death launcher')
  if line:match('^SKIP') then
    print(line)
    wait_for_proc(proc, 3.0, 'parent-death launcher skip')
    return
  end

  local helper = tonumber(line:match('LAUNCHED%s+(%d+)'))
  assert(helper, 'unexpected parent-death launcher line: ' .. tostring(line))
  assert(pid_alive(helper), 'parent-death helper was not alive before parent exit')

  local status, code, sig, err = wait_for_proc(proc, 3.0, 'parent-death launcher')
  assert(status == 'exited' and code == 0,
    'parent-death launcher should exit 0: status=' .. tostring(status) ..
    ' code=' .. tostring(code) .. ' sig=' .. tostring(sig) .. ' err=' .. tostring(err))

  local dead = wait_until(function() return not pid_alive(helper) end, 3.0)
  if not dead then kill_pid(helper) end
  assert(dead, 'parent-death-owned helper remained alive after launcher parent exit: pid=' .. tostring(helper))
  os.remove(marker)
end

fibers.run(function()
  local features = type(exec.features) == 'function' and exec.features() or {}
  print(('exec backend features: process_group=%s parent_death_signal=%s')
    :format(tostring(features.process_group), tostring(features.parent_death_signal)))

  test_process_group_shutdown_kills_grandchild()
  test_signal_bridge_sigterm_cleans_owned_grandchild()
  test_parent_death_signal_cleans_helper()
end)

print('devicecode exec containment on OpenWrt VM: ok')
LUA

cat > "$WORK/signal_bridge_child.lua" <<'LUA'
package.path = table.concat({
  './src/?.lua', './src/?/init.lua',
  './vendor/lua-fibers/src/?.lua', './vendor/lua-fibers/src/?/init.lua',
  './vendor/lua-bus/src/?.lua', './vendor/lua-bus/src/?/init.lua',
  './vendor/lua-trie/src/?.lua', './vendor/lua-trie/src/?/init.lua',
  package.path,
}, ';')

local fibers = require 'fibers'
local exec = require 'fibers.io.exec'
local sleep = require 'fibers.sleep'
local signal_bridge = require 'devicecode.signal_bridge'

local perform = fibers.perform
local marker = assert(arg and arg[1], 'marker path required')

local function read_file(path)
  local f = io.open(path, 'r')
  if not f then return nil end
  local s = f:read('*a')
  f:close()
  return s
end

local function file_exists(path)
  local f = io.open(path, 'r')
  if f then f:close(); return true end
  return false
end

local function wait_until(pred, timeout_s)
  local deadline = fibers.now() + timeout_s
  while fibers.now() < deadline do
    if pred() then return true end
    perform(sleep.sleep_op(0.05))
  end
  return pred()
end

local function owned_flags()
  local flags = { process_group = true }
  if type(exec.supports) == 'function' and exec.supports('parent_death_signal') then
    flags.parent_death_signal = 'TERM'
  end
  return flags
end

local ok, err = xpcall(function()
  fibers.run(function(scope)
    local sig_ok, sig_err = signal_bridge.install(scope, { TERM = true, INT = true })
    assert(sig_ok, 'signal bridge install failed: ' .. tostring(sig_err))

    os.remove(marker)

    local script = [[
trap '' TERM
( trap '' TERM; while :; do sleep 1; done ) &
echo $! > "$1"
while :; do sleep 1; done
]]

    local cmd = exec.command {
      'sh', '-c', script, 'sh', marker,
      stdin = 'null', stdout = 'null', stderr = 'null',
      flags = owned_flags(),
    }

    local spawned, spawn_err = scope:spawn(function()
      perform(cmd:run_op())
    end)
    assert(spawned, 'failed to spawn command waiter: ' .. tostring(spawn_err))

    assert(wait_until(function() return file_exists(marker) end, 3.0), 'owned grandchild marker was not written')
    local grandchild = tonumber((read_file(marker) or ''):match('(%d+)'))
    assert(grandchild, 'could not parse owned grandchild pid')

    io.stdout:write('READY ' .. tostring(grandchild) .. '\n')
    io.stdout:flush()

    while true do
      perform(sleep.sleep_op(1.0))
    end
  end)
end, tostring)

if not ok then
  if tostring(err):match('signal:TERM') or tostring(err):match('signal:INT') or tostring(err):match('scope cancelled') then
    os.exit(0)
  end
  io.stderr:write('signal bridge child failed: ' .. tostring(err) .. '\n')
  os.exit(1)
end
LUA

cat > "$WORK/parent_death_launcher.lua" <<'LUA'
package.path = table.concat({
  './src/?.lua', './src/?/init.lua',
  './vendor/lua-fibers/src/?.lua', './vendor/lua-fibers/src/?/init.lua',
  './vendor/lua-bus/src/?.lua', './vendor/lua-bus/src/?/init.lua',
  './vendor/lua-trie/src/?.lua', './vendor/lua-trie/src/?/init.lua',
  package.path,
}, ';')

local fibers = require 'fibers'
local exec = require 'fibers.io.exec'
local sleep = require 'fibers.sleep'

local perform = fibers.perform
local marker = assert(arg and arg[1], 'marker path required')

local function read_file(path)
  local f = io.open(path, 'r')
  if not f then return nil end
  local s = f:read('*a')
  f:close()
  return s
end

local function file_exists(path)
  local f = io.open(path, 'r')
  if f then f:close(); return true end
  return false
end

local function wait_until(pred, timeout_s)
  local deadline = fibers.now() + timeout_s
  while fibers.now() < deadline do
    if pred() then return true end
    perform(sleep.sleep_op(0.05))
  end
  return pred()
end

fibers.run(function()
  if type(exec.supports) == 'function' and not exec.supports('parent_death_signal') then
    print('SKIP parent_death_signal unsupported by selected backend')
    return
  end

  os.remove(marker)

  local script = [[
echo $$ > "$1"
while :; do sleep 1; done
]]

  local cmd = exec.command {
    'sh', '-c', script, 'sh', marker,
    stdin = 'null', stdout = 'pipe', stderr = 'null',
    flags = { parent_death_signal = 'TERM' },
  }

  local out, start_err = cmd:stdout_stream()
  if not out then
    local msg = tostring(start_err)
    if msg:match('parent_death_signal') and msg:match('not supported') then
      print('SKIP parent_death_signal unsupported by selected backend: ' .. msg)
      return
    end
    error('failed to start parent-death helper: ' .. msg)
  end
  assert(wait_until(function() return file_exists(marker) end, 3.0), 'parent-death helper marker was not written')

  local helper = tonumber((read_file(marker) or ''):match('(%d+)'))
  assert(helper, 'could not parse parent-death helper pid')

  io.stdout:write('LAUNCHED ' .. tostring(helper) .. '\n')
  io.stdout:flush()

  -- Deliberately bypass Fibers scope unwinding and command finalisers.  The
  -- helper must still die because the exec backend was asked for parent_death_signal.
  os.exit(0)
end)
LUA

"$SSH" "rm -rf '$REMOTE'; mkdir -p '$REMOTE'"
"$SCP_TO" "$ROOT_DIR/src" "$REMOTE/src"
"$SCP_TO" "$ROOT_DIR/vendor" "$REMOTE/vendor"
"$SCP_TO" "$WORK/run_devicecode_exec_containment.lua" "$REMOTE/run_devicecode_exec_containment.lua"
"$SCP_TO" "$WORK/signal_bridge_child.lua" "$REMOTE/signal_bridge_child.lua"
"$SCP_TO" "$WORK/parent_death_launcher.lua" "$REMOTE/parent_death_launcher.lua"
"$SSH" "cd '$REMOTE' && lua ./run_devicecode_exec_containment.lua"
