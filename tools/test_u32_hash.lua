local fibers  = require 'fibers'
local exec    = require 'fibers.io.exec'
local perform = require 'fibers.performer'.perform
local unpack_ = (table and table.unpack) or _G.unpack

local function cmd(argv)
  local c = exec.command(unpack_(argv))
  local out, st, code, sig, err = perform(c:combined_output_op())
  local ok = (st == 'exited' and code == 0)
  return ok, (out or ''), st, code, sig, err
end

local function best_effort(argv) cmd(argv) end

local function die(msg) io.stderr:write(msg .. "\n"); os.exit(1) end

local function parse_sent_bytes(out, tag)
  local start = out:find("class%s+htb%s+" .. tag)
  if not start then return nil end
  local block = out:sub(start)
  local sent = block:match("Sent%s+(%d+)%s+bytes")
  return sent and tonumber(sent) or nil
end

fibers.run(function()
  local a, b = "dc0", "dc1"

  -- clean
  best_effort({ "ip", "link", "del", a })
  best_effort({ "tc", "qdisc", "del", "dev", a, "root" })

  local ok = cmd({ "ip", "link", "add", a, "type", "veth", "peer", "name", b })
  if not ok then die("veth create failed") end

  cmd({ "ip", "addr", "add", "10.12.0.1/20", "dev", a })
  cmd({ "ip", "addr", "add", "10.12.0.2/20", "dev", b })
  cmd({ "ip", "link", "set", "dev", a, "up" })
  cmd({ "ip", "link", "set", "dev", b, "up" })

  -- HTB root and inner
  cmd({ "tc", "qdisc", "add", "dev", a, "root", "handle", "1:", "htb", "default", "10" })
  cmd({ "tc", "class", "add", "dev", a, "parent", "1:", "classid", "1:1", "htb", "rate", "1gbit", "ceil", "1gbit" })
  cmd({ "tc", "class", "add", "dev", a, "parent", "1:1", "classid", "1:20", "htb", "rate", "1gbit", "ceil", "1gbit" })
  cmd({ "tc", "qdisc", "add", "dev", a, "parent", "1:20", "handle", "20:", "htb", "default", "100" })
  cmd({ "tc", "class", "add", "dev", a, "parent", "20:", "classid", "20:1", "htb", "rate", "1gbit", "ceil", "1gbit" })
  cmd({ "tc", "class", "add", "dev", a, "parent", "20:1", "classid", "20:100", "htb", "rate", "1gbit", "ceil", "1gbit" })
  cmd({ "tc", "class", "add", "dev", a, "parent", "20:1", "classid", "20:102", "htb", "rate", "1gbit", "ceil", "1gbit" })

  -- Outer prefix gate -> pool
  cmd({ "tc", "filter", "add", "dev", a, "parent", "1:", "chain", "9000", "protocol", "ip", "prio", "100",
        "u32", "match", "ip", "dst", "10.12.0.0/20", "flowid", "1:20" })

  -- Inner u32 hash (attempt 1): direct match for 10.12.0.2
  -- This is not hashing yet; it checks that we can safely attach u32 filters under 20:
  cmd({ "tc", "filter", "add", "dev", a, "parent", "20:", "protocol", "ip", "prio", "1",
        "u32", "match", "ip", "dst", "10.12.0.2/32", "flowid", "20:102" })

  -- Traffic
  cmd({ "ping", "-c", "20", "-I", "10.12.0.1", "10.12.0.2" })

  local ok_s, out = cmd({ "tc", "-s", "class", "show", "dev", a })
  if not ok_s then die("tc -s class show failed") end

  local sent = parse_sent_bytes(out, "20:102") or 0
  io.stdout:write("Sent bytes on 20:102: " .. tostring(sent) .. "\n")

  -- cleanup
  best_effort({ "tc", "qdisc", "del", "dev", a, "root" })
  best_effort({ "ip", "link", "del", a })

  if sent > 0 then
    io.stdout:write("PASS: classification to 20:102 works (u32 direct match)\n")
  else
    io.stdout:write("FAIL: no bytes counted in 20:102\n")
    os.exit(2)
  end
end)
