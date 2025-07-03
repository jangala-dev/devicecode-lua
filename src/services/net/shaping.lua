local log = require "services.log"
local exec = require 'fibers.exec'
local unpack = table.unpack or unpack -- luacheck: ignore -- Compatibility fallback
local bit = rawget(_G, "bit") or require "bit32"
local fqcmemorylimit = "1Mb"
local fqcflows = 256
local ifbsuffix = "-i"

-- Ip functions
local function parse_ip(s)
    local ip = {}
    ip[1], ip[2], ip[3], ip[4] = string.match(s, "(%d+)%.(%d+)%.(%d+)%.(%d+)")
    ip.subnetmask = string.match(s, ".*/(%d+)")
    for i, j in pairs(ip) do
        ip[i] = assert(tonumber(j))
    end
    -- aargh no error checking
    return ip, nil
end

local function get_ipv4(iface)
    local output, err = exec.command("ip", "addr", "show", "dev", iface):output()

    if err then
        return nil, "failed to run command: ip addr show dev " .. iface
    end

    local raw = string.match(output, "inet%s+(%S+)")
    if not raw then
        return nil, "interface has no ipv4 address"
    end

    local ip, parse_err = parse_ip(raw)
    if parse_err then
        return nil, parse_err
    end

    return ip
end

local function ip_to_number(ip)
    local n = 0

    for i, v in ipairs(ip) do
        n = n + bit.lshift(v, 8 * (4 - i))
    end

    return n
end

local function number_to_ip(number)
    local ip = {}

    for i = 1, 4 do
        ip[i] = bit.band(bit.rshift(number, 8 * (4 - i)), bit.lshift(1, 8) - 1)
    end

    return ip
end

local function usable_ips(ip)
    -- check the ip address and subnet mask
    local number = ip_to_number(ip)
    local mask = bit.lshift(1, 32 - ip.subnetmask) - 1 -- 0b10...0 - 1 --> 0b01...1
    local baseip = bit.band(number, bit.bnot(mask))
    local i = 0

    return function()
        i = i + 1
        if i < mask then return i, number_to_ip(baseip + i) end
    end
end

local function setup_ifb(ifbname)
    -- Check if IFB already exists
    local err = exec.command("ip", "link", "show", ifbname):run()
    local exists = not err

    if exists then
        log.info("IFB already exists:", ifbname)
    else
        err = exec.command("ip", "link", "add", "name", ifbname, "type", "ifb"):run()

        if err then
            return "Failed to create IFB: " .. tostring(err)
        end
    end

    err = exec.command("ip", "link", "set", "dev", ifbname, "up"):run()

    if err then
        return "Failed to bring IFB up: " .. tostring(err)
    end

    return nil
end

local function clear(iface)
    local err = exec.command("tc", "qdisc", "del", "dev", iface, "root"):run()

    if err then
        log.warn("Failed to delete root qdisc:", "tc qdisc del dev " .. iface .. " root")
    end

    err = exec.command("tc", "qdisc", "del", "dev", iface, "ingress"):run()

    if err then
        log.warn("Failed to delete ingress qdisc:", "tc qdisc del dev " .. iface .. " ingress")
    end

    return nil
end

local function ingress_mirror(iface, ifbiface)
    local err = exec.command("tc", "qdisc", "add", "dev", iface, "handle", "ffff:", "ingress"):run()

    if err then
        log.error("Failed to add ingress qdisc:", "tc qdisc add dev " .. iface .. " handle ffff: ingress")
        return "Failed to add ingress qdisc"
    end

    err = exec.command(
        "tc", "filter", "add", "dev", iface, "parent", "ffff:", "protocol", "ip", "u32",
        "match", "u32", "0", "0",
        "action", "mirred", "egress", "redirect", "dev", ifbiface
    ):run()

    if err then
        log.error("Failed to add mirred redirect filter:",
        "tc filter add dev " .. iface .. " ... redirect dev " .. ifbiface)
        return "Failed to add mirred redirect filter"
    end

    return nil
end

local function host_shape(iface, ipnet, hostsdir, rate)
    if ipnet.subnetmask < 24 then
        return "error: subnet must be /24 or smaller"
    end

    local octet

    if hostsdir == "dst" then
        octet = "16"
    elseif hostsdir == "src" then
        octet = "12"
    else
        return "error: invalid dir"
    end

    local function run(...)
        local err = exec.command(...):run()
        if err then error("tc command failed: " .. table.concat({ ... }, " ")) end
    end

    -- 1. Root qdisc
    run("tc", "qdisc", "add", "dev", iface, "root", "handle", "1:", "htb")

    -- 2. 4th octet hasher
    run("tc", "filter", "add", "dev", iface, "parent", "1:0", "prio", "1", "protocol", "ip", "u32")
    run("tc", "filter", "add", "dev", iface, "parent", "1:0", "prio", "1", "handle", "100:", "protocol", "ip", "u32",
        "divisor", "256")
    run("tc", "filter", "add", "dev", iface, "protocol", "ip", "parent", "1:0", "prio", "1", "u32", "ht", "800::",
        "match", "ip", hostsdir, table.concat(ipnet, ".") .. "/24",
        "hashkey", "mask", "0x000000ff", "at", octet, "link", "100:")

    -- 3. Per-host shaping
    for i, ip in usable_ips(ipnet) do
        local classid = string.format("1:%x", i)
        local fq_handle = string.format("%x:0", i + 1)
        local ipstr = table.concat(ip, ".")
        local ip4 = ip[4]

        run("tc", "class", "add", "dev", iface, "parent", "1:", "classid", classid,
            "htb", "rate", rate.rate, "ceil", rate.ceil, "burst", rate.burst)

        run("tc", "qdisc", "add", "dev", iface, "parent", classid, "handle", fq_handle,
            "fq_codel", "memory_limit", fqcmemorylimit, "flows", tostring(fqcflows))

        run("tc", "filter", "add", "dev", iface, "parent", "1:0", "protocol", "ip", "prio", "1", "u32",
            "ht", "100:" .. string.format("%x", ip4) .. ":", "match", "ip", hostsdir, ipstr .. "/32", "flowid", classid)
    end

    return nil
end

local function shape_wan(net_cfg, iface)
    local wan = iface
    log.info("Shaping wan started", wan)
    local wanifb = wan .. ifbsuffix

    local err_wanifb = setup_ifb(wanifb)

    if err_wanifb then
        log.error(err_wanifb)
    end

    clear(iface)
    clear(wanifb)
    ingress_mirror(iface, wanifb)

    local shaping = net_cfg.shaping or {}

    -- Downlink (ingress from WAN, redirected to IFB)
    local ingress = shaping.ingress

    if ingress and ingress.qdisc == "cake" then
        local args = { "tc", "qdisc", "replace", "dev", wanifb, "root", "cake", "dual-dsthost", "nat" }

        if ingress.bandwidth then
            table.insert(args, "bandwidth")
            table.insert(args, ingress.bandwidth)
        end

        local err = exec.command(unpack(args)):run()

        if err then
            log.warn("Failed to set downlink shaping:", table.concat(args, " "))
        end
    end

    -- Uplink (egress directly from WAN)
    local egress = shaping.egress

    if egress and egress.qdisc == "cake" then
        local args = { "tc", "qdisc", "replace", "dev", wan, "root", "cake", "dual-srchost", "nat" }

        if egress.bandwidth then
            table.insert(args, "bandwidth")
            table.insert(args, egress.bandwidth)
        end

        local err = exec.command(unpack(args)):run()

        if err then
            log.warn("Failed to set uplink shaping:", table.concat(args, " "))
        end
    end

    log.info("Shaping wan completed", wan)
end

local function shape_lan(net_cfg)
    local lan = "br-" .. net_cfg.id
    log.info("Shaping lan started", lan)
    local lanifb = lan .. ifbsuffix

    local err_lanifb = setup_ifb(lanifb)

    if err_lanifb then
        log.error(err_lanifb)
    end

    clear(lan)
    clear(lanifb)
    ingress_mirror(lan, lanifb)

    local ip, err_ip = get_ipv4(lan)

    if err_ip then
        log.error("Failed to get LAN IP for shaping:", err_ip)
        return
    end

    local shaping = net_cfg.shaping or {}

    local function apply_direction(dir, dev, expected_hash)
        local dir_cfg = shaping[dir]

        if not dir_cfg then return end

        local filter = dir_cfg.filters and dir_cfg.filters[1]
        local class = dir_cfg.class_template and dir_cfg.class_template.classes[1]

        if not filter or not class then return end

        if filter.kind ~= "u32" or filter.hash_key ~= expected_hash then return end

        local hostsdir = expected_hash == "src_ip" and "src" or "dst"
        host_shape(dev, ip, hostsdir, class.config)
    end

    apply_direction("egress", lan, "dest_ip")
    apply_direction("ingress", lanifb, "src_ip")

    log.info("Shaping lan completed", lan)
end

local function apply(net_cfg)
    local net_type = net_cfg.type
    local interfaces = net_cfg.interfaces

    if not interfaces or #interfaces == 0 then
        log.warn("No interfaces to shape for network:", net_cfg.id)
        return
    end

    for _, iface in ipairs(interfaces) do
        if net_type == "local" then
            log.info("Shaping LAN:", net_cfg.id, iface)
            shape_lan(net_cfg)
        elseif net_type == "backhaul" then
            log.info("Shaping WAN:", net_cfg.id, iface)
            shape_wan(net_cfg, iface)
        else
            log.warn("Unknown network type:", net_type)
        end
    end
end

return {
    apply = apply
}
