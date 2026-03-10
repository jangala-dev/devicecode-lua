-- cake_veth_probe.lua
-- Lua 5.1 / LuaJIT
--
-- Creates a throwaway veth + netns, applies CAKE, prints tc stats (text + JSON).
--
-- Usage:
--   luajit cake_veth_probe.lua
--   luajit cake_veth_probe.lua --bw 50mbit
--   luajit cake_veth_probe.lua --cake besteffort nat ack-filter
--   luajit cake_veth_probe.lua --keep
--
-- Notes:
--  * Requires: ip, tc, (optional) modprobe
--  * Needs CAP_NET_ADMIN (root).

local fibers = require 'fibers'
local exec   = require 'fibers.io.exec'
local sleep  = require 'fibers.sleep'

local unpack = _G.unpack or rawget(table, 'unpack')

local function argv_push(t, ...)
  for i = 1, select('#', ...) do t[#t + 1] = select(i, ...) end
end

local function run_cmd(argv)
  local cmd = exec.command(unpack(argv))
  local out, st, code, sig, err = fibers.perform(cmd:combined_output_op())
  local ok = (st == 'exited' and code == 0)
  return ok, out or '', err, code, st, sig
end

local function sh_quote(s)
  s = tostring(s or '')
  if s:match("^[%w%._%-%/]+$") then return s end
  return "'" .. s:gsub("'", "'\\''") .. "'"
end

local function try_cmd(argv)
  local ok, out, err = run_cmd(argv)
  return ok, out, err
end

local function must_cmd(argv, label)
  local ok, out, err, code = run_cmd(argv)
  if ok then return true, out end
  local msg = tostring(err or out or ('exit ' .. tostring(code)))
  error((label or table.concat(argv, ' ')) .. ': ' .. msg, 2)
end

local function usage()
  io.stderr:write([[
usage:
  luajit cake_veth_probe.lua [--bw <rate>] [--cake <args...>] [--keep]

examples:
  luajit cake_veth_probe.lua --bw 80mbit
  luajit cake_veth_probe.lua --cake besteffort nat ack-filter
  luajit cake_veth_probe.lua --bw 50mbit --cake diffserv4 nat
]])
  os.exit(2)
end

local function parse_args()
  local bw = '100mbit'
  local cake_args = {}
  local keep = false

  local i = 1
  while i <= #arg do
    local a = tostring(arg[i])
    if a == '--bw' then
      i = i + 1
      bw = tostring(arg[i] or '')
      if bw == '' then usage() end
    elseif a == '--cake' then
      i = i + 1
      while i <= #arg do
        local v = tostring(arg[i])
        if v:sub(1, 2) == '--' then
          i = i - 1
          break
        end
        cake_args[#cake_args + 1] = v
        i = i + 1
      end
    elseif a == '--keep' then
      keep = true
    elseif a == '--help' or a == '-h' then
      usage()
    else
      usage()
    end
    i = i + 1
  end

  if #cake_args == 0 then
    -- Conservative default; you can override with --cake ...
    cake_args = { 'besteffort' }
  end

  return bw, cake_args, keep
end

local function print_banner(s)
  io.stdout:write('\n=== ' .. tostring(s) .. ' ===\n')
  io.stdout:flush()
end

local function print_cmd(title, argv)
  print_banner(title .. ': ' .. table.concat(argv, ' '))
  local ok, out, err = run_cmd(argv)
  io.stdout:write(out or '')
  if err and tostring(err) ~= '' then
    io.stdout:write('\n[stderr]\n' .. tostring(err) .. '\n')
  end
  io.stdout:flush()
  return ok
end

local function main()
  local bw, cake_args, keep = parse_args()

  local ns  = 'dcpeer'
  local v0  = 'veth_dc0'
  local v1  = 'veth_dc1'
  local ip0 = '10.123.0.1/24'
  local ip1 = '10.123.0.2/24'

  -- Best-effort clean-up from previous runs.
  try_cmd({ 'ip', 'netns', 'del', ns })
  try_cmd({ 'ip', 'link', 'del', v0 })

  -- Optional: ensure CAKE module is present (benign if built-in).
  try_cmd({ 'modprobe', 'sch_cake' })

  print_banner('create veth + netns')
  must_cmd({ 'ip', 'link', 'add', v0, 'type', 'veth', 'peer', 'name', v1 }, 'ip link add veth')
  must_cmd({ 'ip', 'addr', 'add', ip0, 'dev', v0 }, 'ip addr add v0')
  must_cmd({ 'ip', 'link', 'set', v0, 'up' }, 'ip link up v0')

  must_cmd({ 'ip', 'netns', 'add', ns }, 'ip netns add')
  must_cmd({ 'ip', 'link', 'set', v1, 'netns', ns }, 'ip link set netns')

  must_cmd({ 'ip', 'netns', 'exec', ns, 'ip', 'link', 'set', 'lo', 'up' }, 'netns lo up')
  must_cmd({ 'ip', 'netns', 'exec', ns, 'ip', 'addr', 'add', ip1, 'dev', v1 }, 'ip addr add v1')
  must_cmd({ 'ip', 'netns', 'exec', ns, 'ip', 'link', 'set', v1, 'up' }, 'netns v1 up')

  print_banner('apply CAKE')
  local cake_argv = { 'tc', 'qdisc', 'replace', 'dev', v0, 'root', 'cake', 'bandwidth', bw }
  for i = 1, #cake_args do cake_argv[#cake_argv + 1] = cake_args[i] end
  must_cmd(cake_argv, 'tc qdisc replace cake')

  -- Show immediately (structure/fields even if counters are near-zero).
  print_cmd('tc -s qdisc show',  { 'tc', '-s', 'qdisc', 'show', 'dev', v0 })
  print_cmd('tc -j -s qdisc show',{ 'tc', '-j', '-s', 'qdisc', 'show', 'dev', v0 })

  -- Add a small amount of traffic so you can see counters move.
  -- (This won’t saturate the link; it’s just to confirm non-zero stats.)
  print_banner('generate a little traffic (ping)')
  print_cmd('ping from netns', { 'ip', 'netns', 'exec', ns, 'ping', '-c', '20', '-i', '0.02', '10.123.0.1' })

  -- Re-show stats after traffic.
  print_cmd('tc -s qdisc show (after traffic)',  { 'tc', '-s', 'qdisc', 'show', 'dev', v0 })
  print_cmd('tc -j -s qdisc show (after traffic)',{ 'tc', '-j', '-s', 'qdisc', 'show', 'dev', v0 })

  if keep then
    print_banner('left in place (--keep)')
    io.stdout:write('veth: ' .. v0 .. ' (root ns), ' .. v1 .. ' (netns ' .. ns .. ')\n')
    io.stdout:write('to remove later:\n')
    io.stdout:write('  ip netns del ' .. ns .. '\n')
    io.stdout:write('  ip link del ' .. v0 .. '\n')
    io.stdout:flush()
    return
  end

  print_banner('teardown')
  try_cmd({ 'ip', 'netns', 'del', ns })
  try_cmd({ 'ip', 'link', 'del', v0 })
end

fibers.run(main)
