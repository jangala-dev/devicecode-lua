#!/usr/bin/env sh
set -eu

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
VM_DIR="$(dirname "$SCRIPT_DIR")"
ROOT_DIR="$(CDPATH= cd -- "$VM_DIR/../../.." && pwd)"
SSH="$VM_DIR/scripts/ssh"
SCP_TO="$VM_DIR/scripts/scp-to"
REMOTE="/tmp/devicecode-uart-stty-coreutils-test"
WORK="$VM_DIR/work/uart-stty-coreutils-test"

mkdir -p "$WORK"
cat > "$WORK/run_openwrt_uart_stty_coreutils.lua" <<'LUA'
package.path = table.concat({
  './src/?.lua', './src/?/init.lua',
  './vendor/lua-fibers/src/?.lua', './vendor/lua-fibers/src/?/init.lua',
  './vendor/lua-bus/src/?.lua', './vendor/lua-bus/src/?/init.lua',
  './vendor/lua-trie/src/?.lua', './vendor/lua-trie/src/?/init.lua',
  package.path,
}, ';')

local fibers = require 'fibers'
local exec = require 'fibers.io.exec'
local safe = require 'coxpcall'

local ok_posix, posix = pcall(require, 'posix')
assert(ok_posix and type(posix) == 'table', 'luaposix is required')
assert(type(posix.openpty) == 'function', 'luaposix openpty is required')

local perform = fibers.perform

local function fail(msg)
  error(msg, 2)
end

local function exec_capture(args)
  local cmd = exec.command(args)
  local out, st, code, sig, err = perform(cmd:combined_output_op())
  out = out or ''
  if st == 'exited' and code == 0 then
    return out
  end
  fail('command failed: ' .. table.concat(args, ' ') ..
    '\nstatus=' .. tostring(st) .. ' code=' .. tostring(code) .. ' signal=' .. tostring(sig) ..
    '\nerr=' .. tostring(err) .. '\n--- output ---\n' .. out)
end

local function exec_ok(args)
  exec_capture(args)
end

local function close_fd(fd)
  if type(fd) == 'number' and type(posix.close) == 'function' then
    pcall(posix.close, fd)
  elseif type(fd) == 'userdata' and type(fd.close) == 'function' then
    pcall(function() fd:close() end)
  end
end

local function pathish(v)
  return type(v) == 'string' and v:sub(1, 1) == '/'
end

local function fdnum(v)
  if type(v) == 'number' then return v end
  if type(v) == 'userdata' then
    for _, name in ipairs({ 'fileno', 'getfd' }) do
      local fn = v[name]
      if type(fn) == 'function' then
        local ok, n = pcall(fn, v)
        if ok and type(n) == 'number' then return n end
      end
    end
  end
  return nil
end

local function ttyname(fd)
  fd = fdnum(fd)
  if type(fd) ~= 'number' then return nil end
  local fn = posix.ttyname
  if type(fn) ~= 'function' then
    local ok_unistd, unistd = pcall(require, 'posix.unistd')
    if ok_unistd and type(unistd) == 'table' then
      fn = unistd.ttyname
    end
  end
  if type(fn) ~= 'function' then return nil end
  local ok, name = pcall(fn, fd)
  if ok and pathish(name) then return name end
  return nil
end

local function describe_returns(...)
  local parts = {}
  for i = 1, select('#', ...) do
    local v = select(i, ...)
    parts[#parts + 1] = tostring(i) .. '=' .. type(v) .. ':' .. tostring(v)
  end
  return table.concat(parts, ', ')
end

local raw_a, raw_b, raw_c, raw_d = posix.openpty()
assert(raw_a, 'openpty failed: ' .. tostring(raw_b or raw_d))

-- luaposix variants differ. Prefer an explicit path return; otherwise ask the
-- OS for the slave fd name. Do not pass tostring(file) through a shell.
local master = raw_a
local slave = raw_b
local slave_name = pathish(raw_c) and raw_c or pathish(raw_b) and raw_b or ttyname(raw_b) or ttyname(raw_c)
if not pathish(slave_name) then
  close_fd(raw_a)
  close_fd(raw_b)
  close_fd(raw_c)
  fail('openpty slave path unavailable: ' .. describe_returns(raw_a, raw_b, raw_c, raw_d))
end

local strict = {
  'stty', '-F', slave_name, '115200',
  'cs8', '-cstopb', '-parenb', '-crtscts',
  '-ixon', '-ixoff', '-icrnl',
  '-icanon', '-echo', '-isig', '-iexten',
  '-opost', '-onlcr',
  'min', '1', 'time', '0',
  'clocal', 'cread',
}

local dirty = {
  'stty', '-F', slave_name, '9600',
  'icrnl', 'ixon', 'opost', 'onlcr',
  'isig', 'icanon', 'iexten', 'echo',
  'min', '0', 'time', '5',
}

local function assert_contains(raw, token)
  assert(raw:find(token, 1, true), 'expected stty output to contain ' .. token .. ':\n' .. raw)
end

local function assert_min_time(raw)
  assert(raw:find('min%s*=%s*1'), 'expected min = 1:\n' .. raw)
  assert(raw:find('time%s*=%s*0'), 'expected time = 0:\n' .. raw)
end

local ok, msg
fibers.run(function()
  ok, msg = safe.pcall(function()
    exec_capture({ 'stty', '--version' })
    exec_ok(dirty)
    exec_ok(strict)
    local raw = exec_capture({ 'stty', '-F', slave_name, '-a' })

    assert_contains(raw, 'speed 115200')
    for _, token in ipairs({
      'cs8', 'cread', 'clocal',
      '-cstopb', '-parenb', '-crtscts',
      '-ixon', '-ixoff', '-icrnl',
      '-icanon', '-echo', '-isig', '-iexten',
      '-opost', '-onlcr',
    }) do
      assert_contains(raw, token)
    end
    assert_min_time(raw)
  end)
end)

close_fd(master)
close_fd(slave)
close_fd(raw_c)
if not ok then error(msg, 0) end
print('openwrt coreutils-stty PTY raw UART setup: ok')
LUA

"$SSH" 'command -v lua >/dev/null'
"$SSH" 'command -v stty >/dev/null'
"$SSH" 'opkg list-installed | grep -q "^coreutils-stty -" || { echo "coreutils-stty is not installed" >&2; exit 1; }'
"$SSH" "rm -rf '$REMOTE'; mkdir -p '$REMOTE'"
"$SCP_TO" "$ROOT_DIR/src" "$REMOTE/src"
"$SCP_TO" "$ROOT_DIR/vendor" "$REMOTE/vendor"
"$SCP_TO" "$WORK/run_openwrt_uart_stty_coreutils.lua" "$REMOTE/run_openwrt_uart_stty_coreutils.lua"
"$SSH" "cd '$REMOTE' && lua ./run_openwrt_uart_stty_coreutils.lua"

echo "openwrt UART stty coreutils: ok"
