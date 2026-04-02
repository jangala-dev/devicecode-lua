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

local function must(argv, label)
  local ok, out, st, code, sig, err = cmd(argv)
  if not ok then
    io.stderr:write("FAIL: " .. (label or table.concat(argv, " ")) .. "\n")
    if out and out ~= "" then io.stderr:write(out .. "\n") end
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
  local ns = "dcns"

  -- Clean slate
  best_effort({ "tc", "qdisc", "del", "dev", a, "root" })
  best_effort({ "ip", "link", "del", a })
  best_effort({ "ip", "netns", "del", ns })
  -- OpenWrt sometimes needs the netns dir
  best_effort({ "sh", "-c", "mkdir -p /var/run/netns" })

  -- Create namespace and veth
  must({ "ip", "netns", "add", ns }, "ip netns add")
  must({ "ip", "link", "add", a, "type", "veth", "peer", "name", b }, "veth add")
  must({ "ip", "link", "set", b, "netns", ns }, "move peer into netns")

  -- Addressing
  must({ "ip", "addr", "add", "10.12.0.1/20", "dev", a }, "addr dc0")
  must({ "ip", "link", "set", "dev", a, "up" }, "up dc0")

  must({ "ip", "netns", "exec", ns, "ip", "link", "set", "dev", "lo", "up" }, "up lo in netns")
  must({ "ip", "netns", "exec", ns, "ip", "addr", "add", "10.12.0.2/20", "dev", b }, "addr dc1 10.12.0.2")
  must({ "ip", "netns", "exec", ns, "ip", "addr", "add", "10.12.15.2/20", "dev", b }, "addr dc1 10.12.15.2")
  must({ "ip", "netns", "exec", ns, "ip", "link", "set", "dev", b, "up" }, "up dc1")

  -- HTB root + pool + inner HTB
  must({ "tc", "qdisc", "add", "dev", a, "root", "handle", "1:", "htb", "default", "10" }, "htb root")
  must({ "tc", "class", "add", "dev", a, "parent", "1:", "classid", "1:1", "htb", "rate", "1gbit", "ceil", "1gbit" }, "class 1:1")
  must({ "tc", "class", "add", "dev", a, "parent", "1:1", "classid", "1:10", "htb", "rate", "1gbit", "ceil", "1gbit" }, "class 1:10")
  must({ "tc", "class", "add", "dev", a, "parent", "1:1", "classid", "1:20", "htb", "rate", "1gbit", "ceil", "1gbit" }, "class 1:20")
  must({ "tc", "qdisc", "add", "dev", a, "parent", "1:20", "handle", "20:", "htb", "default", "100" }, "inner htb qdisc 20:")
  must({ "tc", "class", "add", "dev", a, "parent", "20:", "classid", "20:1", "htb", "rate", "1gbit", "ceil", "1gbit" }, "class 20:1")

  -- Leaf classes we intend to hit
  must({ "tc", "class", "add", "dev", a, "parent", "20:1", "classid", "20:100",  "htb", "rate", "1gbit", "ceil", "1gbit" }, "class 20:100")
  must({ "tc", "class", "add", "dev", a, "parent", "20:1", "classid", "20:102",  "htb", "rate", "1gbit", "ceil", "1gbit" }, "class 20:102")
  must({ "tc", "class", "add", "dev", a, "parent", "20:1", "classid", "20:1002", "htb", "rate", "1gbit", "ceil", "1gbit" }, "class 20:1002")

  -- OUTER: prefix gate into pool class (no chain)
  must({ "tc", "filter", "add", "dev", a, "parent", "1:", "protocol", "ip", "prio", "100",
        "u32", "match", "ip", "dst", "10.12.0.0/20", "flowid", "1:20" }, "outer gate")

  -- INNER: u32 hash table
  -- divisor must be power of 2 with exponent <= 8 (max 256 buckets). :contentReference[oaicite:3]{index=3}
  must({ "tc", "filter", "add", "dev", a, "parent", "20:", "protocol", "ip", "prio", "99",
        "handle", "1:", "u32", "divisor", "256" }, "u32 table 1: divisor 256")

  -- Link into the table using a hashkey selector; hashkey requires link. :contentReference[oaicite:4]{index=4}
  must({ "tc", "filter", "add", "dev", a, "parent", "20:", "protocol", "ip", "prio", "1",
        "u32", "link", "1:", "hashkey", "mask", "0x000000ff", "at", "16",
        "match", "ip", "dst", "10.12.0.0/20" }, "link+hashkey")

  -- Put both /32 rules into the bucket we expect for last-octet == 2.
  -- If this build hashes a different byte, we will see it in the filter stats.
  must({ "tc", "filter", "add", "dev", a, "parent", "20:", "protocol", "ip", "prio", "99",
        "u32", "ht", "1:2:", "match", "ip", "dst", "10.12.0.2/32",  "flowid", "20:102" }, "bucket rule 10.12.0.2")
  must({ "tc", "filter", "add", "dev", a, "parent", "20:", "protocol", "ip", "prio", "99",
        "u32", "ht", "1:2:", "match", "ip", "dst", "10.12.15.2/32", "flowid", "20:1002" }, "bucket rule 10.12.15.2")

  -- Traffic (now actually remote)
  must({ "ping", "-c", "20", "-I", "10.12.0.1", "10.12.0.2" }, "ping 10.12.0.2")
  must({ "ping", "-c", "20", "-I", "10.12.0.1", "10.12.15.2" }, "ping 10.12.15.2")

  -- Counters
  local cls = must({ "tc", "-s", "class", "show", "dev", a }, "tc -s class show")
  local b_1_20   = parse_sent_bytes(cls, "1:20")   or 0
  local b_20_102 = parse_sent_bytes(cls, "20:102") or 0
  local b_20_1002= parse_sent_bytes(cls, "20:1002")or 0

  io.stdout:write("Sent bytes 1:20    = " .. tostring(b_1_20) .. "\n")
  io.stdout:write("Sent bytes 20:102  = " .. tostring(b_20_102) .. "\n")
  io.stdout:write("Sent bytes 20:1002 = " .. tostring(b_20_1002) .. "\n")

  local f1 = must({ "tc", "-s", "filter", "show", "dev", a, "parent", "1:" }, "tc -s filter show parent 1:")
  io.stdout:write("\nFilters under parent 1: (with stats)\n" .. f1 .. "\n")

  local f2 = must({ "tc", "-s", "filter", "show", "dev", a, "parent", "20:" }, "tc -s filter show parent 20:")
  io.stdout:write("\nFilters under parent 20: (with stats)\n" .. f2 .. "\n")

  -- Cleanup
  best_effort({ "tc", "qdisc", "del", "dev", a, "root" })
  best_effort({ "ip", "link", "del", a })
  best_effort({ "ip", "netns", "del", ns })

  if b_1_20 == 0 then
    die("FAIL: still not reaching 1:20; outer match is not being exercised")
  end

  if b_20_102 > 0 and b_20_1002 > 0 then
    io.stdout:write("PASS: outer gate works, inner u32 rules classify into per-host classes\n")
  else
    io.stdout:write("NOTE: reached 1:20 but did not hit both buckets; likely hashkey selects a different byte on this build\n")
    io.stdout:write("      Inspect 'tc -s filter show parent 20:' above to see which bucket got hits.\n")
    os.exit(2)
  end
end)
