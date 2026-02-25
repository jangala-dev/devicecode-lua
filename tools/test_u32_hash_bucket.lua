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

local function die(msg)
  io.stderr:write(msg .. "\n")
  os.exit(1)
end

local function must(argv, label)
  local ok, out, st, code, sig, err = cmd(argv)
  if not ok then
    io.stderr:write("FAIL: " .. (label or table.concat(argv, " ")) .. "\n")
    io.stderr:write(out .. "\n")
    if err then io.stderr:write(tostring(err) .. "\n") end
    io.stderr:write("(exit " .. tostring(code) .. ")\n")
    os.exit(1)
  end
  return out
end

local function parse_sent_bytes(out, tag)
  local start = out:find("class%s+htb%s+" .. tag)
  if not start then return nil end
  local block = out:sub(start)
  local sent = block:match("Sent%s+(%d+)%s+bytes")
  return sent and tonumber(sent) or nil
end

fibers.run(function()
  local a, b = "dc0", "dc1"

  best_effort({ "ip", "link", "del", a })
  best_effort({ "tc", "qdisc", "del", "dev", a, "root" })

  must({ "ip", "link", "add", a, "type", "veth", "peer", "name", b }, "veth create")

  must({ "ip", "addr", "add", "10.12.0.1/20", "dev", a })
  must({ "ip", "addr", "add", "10.12.0.2/20", "dev", b })
  must({ "ip", "addr", "add", "10.12.15.2/20", "dev", b })
  must({ "ip", "link", "set", "dev", a, "up" })
  must({ "ip", "link", "set", "dev", b, "up" })

  -- Root + pool + inner HTB
  must({ "tc", "qdisc", "add", "dev", a, "root", "handle", "1:", "htb", "default", "10" })
  must({ "tc", "class", "add", "dev", a, "parent", "1:", "classid", "1:1", "htb", "rate", "1gbit", "ceil", "1gbit" })
  must({ "tc", "class", "add", "dev", a, "parent", "1:1", "classid", "1:10", "htb", "rate", "1gbit", "ceil", "1gbit" })
  must({ "tc", "class", "add", "dev", a, "parent", "1:1", "classid", "1:20", "htb", "rate", "1gbit", "ceil", "1gbit" })

  must({ "tc", "qdisc", "add", "dev", a, "parent", "1:20", "handle", "20:", "htb", "default", "100" })
  must({ "tc", "class", "add", "dev", a, "parent", "20:", "classid", "20:1", "htb", "rate", "1gbit", "ceil", "1gbit" })

  -- Leaf classes: default + two targets
  must({ "tc", "class", "add", "dev", a, "parent", "20:1", "classid", "20:100",  "htb", "rate", "1gbit", "ceil", "1gbit" })
  must({ "tc", "class", "add", "dev", a, "parent", "20:1", "classid", "20:102",  "htb", "rate", "1gbit", "ceil", "1gbit" })
  must({ "tc", "class", "add", "dev", a, "parent", "20:1", "classid", "20:1002", "htb", "rate", "1gbit", "ceil", "1gbit" })

  -- OUTER prefix gate (NO chain)
  must({ "tc", "filter", "add", "dev", a, "parent", "1:", "protocol", "ip", "prio", "100",
        "u32", "match", "ip", "dst", "10.12.0.0/20", "flowid", "1:20" })

  -- INNER u32 hashtable
  must({ "tc", "filter", "add", "dev", a, "parent", "20:", "protocol", "ip", "prio", "99",
        "handle", "1:", "u32", "divisor", "256" }, "create u32 table 1:")

  -- Link to table 1: using the same selector you used
  must({ "tc", "filter", "add", "dev", a, "parent", "20:", "protocol", "ip", "prio", "1",
        "u32", "link", "1:", "hashkey", "mask", "0x000000ff", "at", "16",
        "match", "ip", "dst", "10.12.0.0/20" }, "link to table 1: (mask 0x000000ff @16)")

  -- Install duplicate bucket entries for the same /32 into likely buckets:
  --  0  (third octet low byte / other)
  --  2  (last octet expected in network-order)
  -- 10  (first octet expected if host-order is used)
  -- 12  (second octet expected if host-order + different mask behaviour)
  local buckets = { "0", "2", "10", "12" }

  local function add_bucket_rule(bucket, ip, flowid)
    must({ "tc", "filter", "add", "dev", a, "parent", "20:", "protocol", "ip", "prio", "99",
          "u32", "ht", "1:" .. bucket .. ":", "match", "ip", "dst", ip .. "/32", "flowid", flowid },
        "bucket " .. bucket .. " rule for " .. ip .. " -> " .. flowid)
  end

  for _, bkt in ipairs(buckets) do
    add_bucket_rule(bkt, "10.12.0.2",  "20:102")
    add_bucket_rule(bkt, "10.12.15.2", "20:1002")
  end

  -- Traffic
  must({ "ping", "-c", "20", "-I", "10.12.0.1", "10.12.0.2" })
  must({ "ping", "-c", "20", "-I", "10.12.0.1", "10.12.15.2" })

  -- Class counters
  local cls = must({ "tc", "-s", "class", "show", "dev", a }, "tc -s class show")
  local b_1_20  = parse_sent_bytes(cls, "1:20")  or 0
  local b_20_100  = parse_sent_bytes(cls, "20:100")  or 0
  local b_20_102  = parse_sent_bytes(cls, "20:102")  or 0
  local b_20_1002 = parse_sent_bytes(cls, "20:1002") or 0

  io.stdout:write("Sent bytes 1:20     = " .. tostring(b_1_20) .. "\n")
  io.stdout:write("Sent bytes 20:100   = " .. tostring(b_20_100) .. "\n")
  io.stdout:write("Sent bytes 20:102   = " .. tostring(b_20_102) .. "\n")
  io.stdout:write("Sent bytes 20:1002  = " .. tostring(b_20_1002) .. "\n\n")

  -- Filter hit counters
  local f = must({ "tc", "-s", "filter", "show", "dev", a, "parent", "20:" }, "tc -s filter show parent 20:")
  io.stdout:write("Filters under parent 20: (with stats)\n" .. f .. "\n")

  -- Cleanup
  best_effort({ "tc", "qdisc", "del", "dev", a, "root" })
  best_effort({ "ip", "link", "del", a })

  if b_1_20 == 0 then
    io.stdout:write("\nFAIL: traffic never reached class 1:20 (outer prefix gate not matching)\n")
    os.exit(2)
  end

  if b_20_102 > 0 and b_20_1002 > 0 then
    io.stdout:write("PASS: inner u32 table is being consulted and leaf classes get bytes\n")
    io.stdout:write("Next step: choose a hash mask that distributes buckets as desired (usually last octet).\n")
  else
    io.stdout:write("FAIL: inner leaf classes still not seeing bytes\n")
    os.exit(2)
  end
end)
