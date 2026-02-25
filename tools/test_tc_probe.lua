local fibers   = require 'fibers'
local exec     = require 'fibers.io.exec'
local perform  = require 'fibers.performer'.perform

local unpack_ = (table and table.unpack) or _G.unpack

local function cmd(argv)
  local c = exec.command(unpack_(argv))
  local out, st, code, sig, err = perform(c:combined_output_op())
  local ok = (st == 'exited' and code == 0)
  return ok, (out or ''), st, code, sig, err
end

local function best_effort(argv)
  cmd(argv)
end

local function ok_detail(ok, out, st, code, sig, err)
  if ok then return true, "ok" end
  local d = err or out or ("status=" .. tostring(st))
  if st == 'exited' then
    d = d .. " (exit " .. tostring(code) .. ")"
  elseif st == 'signalled' then
    d = d .. " (signal " .. tostring(sig) .. ")"
  end
  return false, d
end

local function record(results, name, ok, out, st, code, sig, err)
  local pass, detail = ok_detail(ok, out, st, code, sig, err)
  results[#results + 1] = { name = name, pass = pass, detail = detail, out = out }
  return pass, detail, out
end

local function divider()
  io.stdout:write(string.rep("=", 72) .. "\n")
end

local function parse_sent_bytes(tc_class_show, class_tag)
  local start = tc_class_show:find("class%s+htb%s+" .. class_tag)
  if not start then return nil, "class not found: " .. class_tag end
  local block = tc_class_show:sub(start)
  local sent = block:match("Sent%s+(%d+)%s+bytes")
  if not sent then return nil, "Sent bytes not found for class " .. class_tag end
  return tonumber(sent), nil
end

fibers.run(function()
  local results = {}

  divider()
  io.stdout:write("tc probe v2 (Lua 5.1 compatible)\n")
  divider()

  record(results, "run as root (id -u == 0)",
    cmd({ "sh", "-c", "test \"$(id -u)\" = 0" }))

  local tc_ok = record(results, "tc present (tc -V)", cmd({ "tc", "-V" }))
  local ip_ok = record(results, "ip present (ip -V)", cmd({ "ip", "-V" }))

  -- BusyBox ping has no -V: just do a trivial ping.
  local ping_ok = record(results, "ping usable (ping -c1 127.0.0.1)", cmd({ "ping", "-c", "1", "127.0.0.1" }))

  if not tc_ok or not ip_ok then
    divider()
    io.stdout:write("Missing tc/ip; aborting.\n")
    divider()
  else
    divider()
    io.stdout:write("Kernel feature probe: cls_flow\n")
    divider()

    local cfg_ok, cfg_out = cmd({ "sh", "-c", "zcat /proc/config.gz 2>/dev/null | grep -E '^CONFIG_NET_CLS_FLOW=' || true" })
    local cfg_line = (cfg_out or ""):match("CONFIG_NET_CLS_FLOW=[^\n]*") or ""
    if cfg_line ~= "" then
      results[#results + 1] = { name = "/proc/config.gz CONFIG_NET_CLS_FLOW", pass = true, detail = cfg_line }
    else
      results[#results + 1] = { name = "/proc/config.gz CONFIG_NET_CLS_FLOW", pass = false, detail = "not found (no /proc/config.gz or option absent)" }
    end

    if cfg_line:match("=m") then
      record(results, "modprobe cls_flow", cmd({ "modprobe", "cls_flow" }))
    else
      results[#results + 1] = { name = "modprobe cls_flow", pass = true, detail = "skipped (kernel config not '=m')" }
    end

    divider()
    io.stdout:write("Set up veth pair for deterministic traffic\n")
    divider()

    local a = "dc0"
    local b = "dc1"
    local ifb = "ifb_dc0"

    best_effort({ "ip", "link", "del", a })
    best_effort({ "ip", "link", "del", ifb })

    local veth_ok = record(results, "ip link add veth pair",
      cmd({ "ip", "link", "add", a, "type", "veth", "peer", "name", b }))

    if not veth_ok then
      divider()
      io.stdout:write("Could not create veth; skipping remaining tests.\n")
      divider()
    else
      record(results, "ip addr add 10.12.0.1/20 dev dc0", cmd({ "ip", "addr", "add", "10.12.0.1/20", "dev", a }))
      record(results, "ip addr add 10.12.0.2/20 dev dc1", cmd({ "ip", "addr", "add", "10.12.0.2/20", "dev", b }))
      record(results, "ip link set dc0 up", cmd({ "ip", "link", "set", "dev", a, "up" }))
      record(results, "ip link set dc1 up", cmd({ "ip", "link", "set", "dev", b, "up" }))

      divider()
      io.stdout:write("Egress test on dc0 (dst mapping)\n")
      divider()

      best_effort({ "tc", "qdisc", "del", "dev", a, "root" })
      best_effort({ "tc", "qdisc", "del", "dev", a, "ingress" })

      record(results, "htb root qdisc add", cmd({ "tc", "qdisc", "add", "dev", a, "root", "handle", "1:", "htb", "default", "10" }))
      record(results, "htb root class 1:1", cmd({ "tc", "class", "add", "dev", a, "parent", "1:", "classid", "1:1", "htb", "rate", "1gbit", "ceil", "1gbit" }))
      record(results, "htb pool class 1:20", cmd({ "tc", "class", "add", "dev", a, "parent", "1:1", "classid", "1:20", "htb", "rate", "1gbit", "ceil", "1gbit" }))
      record(results, "inner htb qdisc 20:", cmd({ "tc", "qdisc", "add", "dev", a, "parent", "1:20", "handle", "20:", "htb", "default", "100" }))
      record(results, "inner root class 20:1", cmd({ "tc", "class", "add", "dev", a, "parent", "20:", "classid", "20:1", "htb", "rate", "1gbit", "ceil", "1gbit" }))
      record(results, "host bucket 20:100", cmd({ "tc", "class", "add", "dev", a, "parent", "20:1", "classid", "20:100", "htb", "rate", "1gbit", "ceil", "1gbit" }))
      record(results, "host bucket 20:102", cmd({ "tc", "class", "add", "dev", a, "parent", "20:1", "classid", "20:102", "htb", "rate", "1gbit", "ceil", "1gbit" }))

      local chain_ok = record(results, "outer u32 filter with chain (probe)",
        cmd({ "tc", "filter", "add", "dev", a, "parent", "1:", "chain", "9000", "protocol", "ip", "prio", "100",
              "u32", "match", "ip", "dst", "10.12.0.0/20", "flowid", "1:20" }))

      if not chain_ok then
        record(results, "outer u32 filter without chain (fallback)",
          cmd({ "tc", "filter", "add", "dev", a, "parent", "1:", "protocol", "ip", "prio", "100",
                "u32", "match", "ip", "dst", "10.12.0.0/20", "flowid", "1:20" }))
      end

      local flow_ok = record(results, "inner cls_flow mapping (dst /20)",
        cmd({ "tc", "filter", "add", "dev", a, "parent", "20:", "protocol", "ip", "prio", "1",
              "flow", "map", "key", "dst", "addend", "-10.12.0.0", "divisor", "4096", "baseclass", "20:100" }))

      record(results, "fq_codel leaf attach (flows/limit/memory_limit)",
        cmd({ "tc", "qdisc", "replace", "dev", a, "parent", "20:102", "fq_codel", "flows", "1024", "limit", "4096", "memory_limit", "16Mb" }))

      divider()
      io.stdout:write("IFB ingress redirect + IFB egress test (src mapping)\n")
      divider()

      record(results, "ip link add ifb (best effort)", cmd({ "ip", "link", "add", ifb, "type", "ifb" }))
      record(results, "ip link set ifb up", cmd({ "ip", "link", "set", "dev", ifb, "up" }))

      best_effort({ "tc", "qdisc", "del", "dev", a, "ingress" })
      record(results, "ingress qdisc ffff:", cmd({ "tc", "qdisc", "add", "dev", a, "handle", "ffff:", "ingress" }))
      record(results, "mirred egress redirect to IFB",
        cmd({ "tc", "filter", "add", "dev", a, "parent", "ffff:", "protocol", "ip", "prio", "1",
              "u32", "match", "u32", "0", "0", "action", "mirred", "egress", "redirect", "dev", ifb }))

      best_effort({ "tc", "qdisc", "del", "dev", ifb, "root" })
      record(results, "ifb htb root qdisc", cmd({ "tc", "qdisc", "add", "dev", ifb, "root", "handle", "1:", "htb", "default", "10" }))
      record(results, "ifb htb root class 1:1", cmd({ "tc", "class", "add", "dev", ifb, "parent", "1:", "classid", "1:1", "htb", "rate", "1gbit", "ceil", "1gbit" }))
      record(results, "ifb pool class 1:20", cmd({ "tc", "class", "add", "dev", ifb, "parent", "1:1", "classid", "1:20", "htb", "rate", "1gbit", "ceil", "1gbit" }))
      record(results, "ifb inner htb qdisc 20:", cmd({ "tc", "qdisc", "add", "dev", ifb, "parent", "1:20", "handle", "20:", "htb", "default", "100" }))
      record(results, "ifb inner root class 20:1", cmd({ "tc", "class", "add", "dev", ifb, "parent", "20:", "classid", "20:1", "htb", "rate", "1gbit", "ceil", "1gbit" }))
      record(results, "ifb bucket 20:100", cmd({ "tc", "class", "add", "dev", ifb, "parent", "20:1", "classid", "20:100", "htb", "rate", "1gbit", "ceil", "1gbit" }))
      record(results, "ifb bucket 20:102", cmd({ "tc", "class", "add", "dev", ifb, "parent", "20:1", "classid", "20:102", "htb", "rate", "1gbit", "ceil", "1gbit" }))

      record(results, "ifb outer u32 filter (src prefix)",
        cmd({ "tc", "filter", "add", "dev", ifb, "parent", "1:", "protocol", "ip", "prio", "100",
              "u32", "match", "ip", "src", "10.12.0.0/20", "flowid", "1:20" }))

      local flow_ok_ifb = record(results, "ifb inner cls_flow mapping (src /20)",
        cmd({ "tc", "filter", "add", "dev", ifb, "parent", "20:", "protocol", "ip", "prio", "1",
              "flow", "map", "key", "src", "addend", "-10.12.0.0", "divisor", "4096", "baseclass", "20:100" }))

      divider()
      io.stdout:write("Traffic test and counters\n")
      divider()

      if ping_ok then
        record(results, "ping -c 20 -I 10.12.0.1 10.12.0.2", cmd({ "ping", "-c", "20", "-I", "10.12.0.1", "10.12.0.2" }))
      end

      local okc, out = cmd({ "tc", "-s", "class", "show", "dev", a })
      record(results, "tc -s class show dev dc0", okc, out)
      if okc then
        local bytes, berr = parse_sent_bytes(out, "20:102")
        results[#results + 1] = {
          name = "dc0 bucket 20:102 Sent bytes > 0",
          pass = (bytes ~= nil and bytes > 0),
          detail = bytes and ("Sent " .. tostring(bytes) .. " bytes") or berr
        }
      end

      local okc2, out2 = cmd({ "tc", "-s", "class", "show", "dev", ifb })
      record(results, "tc -s class show dev ifb_dc0", okc2, out2)
      if okc2 then
        local bytes, berr = parse_sent_bytes(out2, "20:102")
        results[#results + 1] = {
          name = "ifb_dc0 bucket 20:102 Sent bytes > 0",
          pass = (bytes ~= nil and bytes > 0),
          detail = bytes and ("Sent " .. tostring(bytes) .. " bytes") or berr
        }
      end

      divider()
      io.stdout:write("Cleanup\n")
      divider()

      best_effort({ "tc", "qdisc", "del", "dev", a, "root" })
      best_effort({ "tc", "qdisc", "del", "dev", a, "ingress" })
      best_effort({ "tc", "qdisc", "del", "dev", ifb, "root" })
      best_effort({ "ip", "link", "del", ifb })
      best_effort({ "ip", "link", "del", a })

      -- Add explicit notes based on flow status
      if not flow_ok or not flow_ok_ifb then
        results[#results + 1] = {
          name = "note: cls_flow mapping",
          pass = false,
          detail = "flow map failed; likely missing kmod-cls-flow / CONFIG_NET_CLS_FLOW"
        }
      end
    end
  end

  divider()
  io.stdout:write("Summary\n")
  divider()

  local fail = 0
  for _, r in ipairs(results) do
    local mark = r.pass and "PASS" or "FAIL"
    if not r.pass then fail = fail + 1 end
    io.stdout:write(string.format("%-4s  %-55s  %s\n", mark, r.name, r.detail))
  end

  divider()
  if fail == 0 then
    io.stdout:write("All checks passed.\n")
  else
    io.stdout:write(string.format("%d check(s) failed.\n", fail))
  end
  divider()

  if fail ~= 0 then
    io.stdout:write("\nIf flow map fails, check:\n")
    io.stdout:write("  zcat /proc/config.gz | grep CONFIG_NET_CLS_FLOW\n")
    io.stdout:write("  lsmod | grep cls_flow\n")
    io.stdout:write("  opkg list-installed | grep cls-flow\n")
  end
end)
