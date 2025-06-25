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
    local ok, _, code = handle:close()

    if not ok or code ~= 0 then
        return nil, "failed to get IP: " .. cmd
    end

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
    local cmd_add = string.format("ip link add name %s type ifb", ifbname)
    local cmd_status = os.execute(cmd_add)

    if cmd_status ~= 0 then
        -- Special case: ignore if already exists
        local check = io.popen(string.format("ip link show %s 2>&1", ifbname)):read("*a")
        if not check:match("^[0-9]+: " .. ifbname) then
            local err_msg = "Failed to create IFB: " .. cmd_add .. " " .. check
            log.error(err_msg)
            return err_msg
        end
    end

    local cmd_up = string.format("ip link set dev %s up", ifbname)
    cmd_status = os.execute(cmd_up)

    if cmd_status ~= 0 then
        local err_msg = "Failed to bring IFB up: " .. cmd_up
        log.error(err_msg)
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

local function shape_wan(shaping)
    local wan = shaping.iface
    log.info("Shaping wan started", wan)

    local wanifb = wan .. ifbsuffix
    setup_ifb(wanifb)
    clear(wan)
    clear(wanifb)
    ingress_mirror(wan, wanifb)

    -- Downlink (rx via IFB)
    local cmd_down = string.format("tc qdisc replace dev %s root cake dual-dsthost nat", wanifb)
    if shaping.rx and shaping.rx.rate then
        cmd_down = cmd_down .. " bandwidth " .. shaping.rx.rate
    end
    local status = os.execute(cmd_down)
    if status ~= 0 then
        log.warn("Failed to set downlink shaping:", cmd_down)
    end

    -- Uplink (tx direct)
    local cmd_up = string.format("tc qdisc replace dev %s root cake dual-srchost nat", wan)
    if shaping.tx and shaping.tx.rate then
        cmd_up = cmd_up .. " bandwidth " .. shaping.tx.rate
    end
    status = os.execute(cmd_up)
    if status ~= 0 then
        log.warn("Failed to set uplink shaping:", cmd_up)
    end

    log.info("Shaping wan completed", wan)
end

local function shape_lan(shaping)
    local lan = "br-" .. shaping.network_name
    log.info("Shaping lan started", lan)

    if not shaping.perhost then
        log.warn("Shaping lan: no per-host shaping specified")
    end

    local lanifb = lan .. ifbsuffix
    setup_ifb(lanifb)
    clear(lan)
    clear(lanifb)
    ingress_mirror(lan, lanifb)

    local ip, err = get_ipv4(lan)
    if not ip then
        log.error("Failed to get LAN IP for shaping:", err)
        return
    end

    if shaping.perhost and shaping.perhost.tx then
        host_shape(lan, ip, "dst", shaping.perhost.tx)
    end

    if shaping.perhost and shaping.perhost.rx then
        host_shape(lanifb, ip, "src", shaping.perhost.rx)
    end

    log.info("Shaping lan completed", lan)
end

local function apply(shapings)
    for _, j in ipairs(shapings) do
        if j.network_type == "lan" then
            log.info("Shaping lan", j.network_name)
            shape_lan(j)
        elseif j.network_type == "wan" then
            log.info("Shaping wan", j.network_name)
            shape_wan(j)
        end
    end
end

return {
    apply = apply
}
