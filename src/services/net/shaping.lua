local log = require "services.log"
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
    local cmd = string.format("ip addr show dev %s", iface)
    local handle = io.popen(cmd .. " 2>&1")

    if not handle then
        return nil, "failed to run command: " .. cmd
    end

    local out = handle:read("*a")
    handle:close()

    local raw = string.match(out, "inet%s(%S+)")
    if not raw then
        return nil, "interface has no ipv4 address"
    end

    local ip, err = parse_ip(raw)
    if err then return nil, err end

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
    -- Check if already exists
    local exists = os.execute(string.format("ip link show %s >/dev/null 2>&1", ifbname)) == 0

    if exists then
        log.info("IFB already exists:", ifbname)
    else
        -- Try to create IFB
        local cmd_add = string.format("ip link add name %s type ifb", ifbname)
        local cmd_status = os.execute(cmd_add)
        if cmd_status ~= 0 then
            return "Failed to create IFB" .. cmd_add
        end
    end

    -- Ensure IFB is up
    local cmd_up = string.format("ip link set dev %s up", ifbname)
    local cmd_status = os.execute(cmd_up)
    if cmd_status ~= 0 then
        local err_msg = "Failed to bring IFB up: " .. cmd_up
        return err_msg
    end

    return nil
end

local function clear(iface)
    local cmd_root = string.format("tc qdisc del dev %s root", iface)
    local cmd_status = os.execute(cmd_root)
    if cmd_status ~= 0 then
        log.warn("Failed to delete root qdisc:", cmd_root)
    end

    local cmd_ingress = string.format("tc qdisc del dev %s ingress", iface)
    cmd_status = os.execute(cmd_ingress)
    if cmd_status ~= 0 then
        log.warn("Failed to delete ingress qdisc:", cmd_ingress)
    end

    return nil
end

local function ingress_mirror(iface, ifbiface)
    local cmd_qdisc = string.format("tc qdisc add dev %s handle ffff: ingress", iface)
    local cmd_status = os.execute(cmd_qdisc)
    if cmd_status ~= 0 then
        log.error("Failed to add ingress qdisc:", cmd_qdisc)
        return "Failed to add ingress qdisc"
    end

    local cmd_filter = string.format(
        "tc filter add dev %s parent ffff: protocol ip u32 match u32 0 0 action mirred egress redirect dev %s",
        iface, ifbiface
    )
    cmd_status = os.execute(cmd_filter)
    if cmd_status ~= 0 then
        log.error("Failed to add mirred redirect filter:", cmd_filter)
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

    local function run(cmd)
        local status = os.execute(cmd)
        if status ~= 0 then error("tc command failed: " .. cmd) end
    end

    -- 1. Root qdisc
    run(string.format("tc qdisc add dev %s root handle 1: htb", iface))

    -- 2. 4th octet hasher
    run(string.format("tc filter add dev %s parent 1:0 prio 1 protocol ip u32", iface))
    run(string.format("tc filter add dev %s parent 1:0 prio 1 handle 100: protocol ip u32 divisor 256", iface))
    run(string.format(
        "tc filter add dev %s protocol ip parent 1:0 prio 1 u32 ht 800:: " ..
        "match ip %s %s/24 hashkey mask 0x000000ff at %s link 100:",
        iface,
        hostsdir,
        table.concat(ipnet, "."),
        octet
    ))

    -- 3. Per-host shaping
    for i, ip in usable_ips(ipnet) do
        local classid = string.format("1:%x", i)
        local fq_handle = string.format("%x:0", i + 1)
        local ipstr = table.concat(ip, ".")
        local ip4 = ip[4]

        run(string.format(
            "tc class add dev %s parent 1: classid %s htb rate %s ceil %s burst %s",
            iface, classid, rate.rate, rate.ceil, rate.burst
        ))

        run(string.format(
            "tc qdisc add dev %s parent %s handle %s fq_codel memory_limit %s flows %d",
            iface, classid, fq_handle, fqcmemorylimit, fqcflows
        ))

        run(string.format(
            "tc filter add dev %s parent 1:0 protocol ip prio 1 u32 ht 100:%x: match ip %s %s/32 flowid %s",
            iface, ip4, hostsdir, ipstr, classid
        ))
    end

    return nil
end

local function shape_wan(net_cfg, iface)
    local wan = iface
    log.info("Shaping wan started", wan)
    local wanifb = wan .. ifbsuffix

    local err = setup_ifb(wanifb)

    if err then
        log.error(err)
    end

    clear(iface)
    clear(wanifb)
    ingress_mirror(iface, wanifb)

    local shaping = net_cfg.shaping or {}

    -- Downlink (ingress from WAN, redirected to IFB)
    local ingress = shaping.ingress
    if ingress and ingress.qdisc == "cake" then
        local cmd_down = string.format("tc qdisc replace dev %s root cake dual-dsthost nat", wanifb)
        if ingress.bandwidth then
            cmd_down = cmd_down .. " bandwidth " .. ingress.bandwidth
        end
        local status = os.execute(cmd_down)
        if status ~= 0 then
            log.warn("Failed to set downlink shaping:", cmd_down)
        end
    end

    -- Uplink (egress directly from WAN)
    local egress = shaping.egress
    if egress and egress.qdisc == "cake" then
        local cmd_up = string.format("tc qdisc replace dev %s root cake dual-srchost nat", wan)
        if egress.bandwidth then
            cmd_up = cmd_up .. " bandwidth " .. egress.bandwidth
        end
        local status = os.execute(cmd_up)
        if status ~= 0 then
            log.warn("Failed to set uplink shaping:", cmd_up)
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
