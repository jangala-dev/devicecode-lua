local file = require 'fibers.stream.file'
local fiber = require "fibers.fiber"
local sleep = require "fibers.sleep"
local queue = require "fibers.queue"
local channel = require "fibers.channel"
local cond = require "fibers.cond"
local op = require "fibers.op"
local sc = require "fibers.utils.syscall"
local context = require "fibers.context"
local cjson = require "cjson.safe"
local log = require "services.log"
local shaping = require "services.net.shaping"
local speedtest = require "services.net.speedtest"
local new_msg = require "bus".new_msg
-- local cursor = uci.cursor("/tmp/test", "/tmp/.uci") -- runtime-safe!

-- top-level service
local net_service = {
    name = 'net'
}
net_service.__index = net_service
-------------------------------------------------------
-- Constants
local tracking_ips = { "8.8.8.8", "1.1.1.1" }
local BUS_TIMEOUT = 10
-------------------------------------------------------
-- Helper functions

local function add_to_uci_list(main, section_name, list_name, list_value)
    -- Read current networks assigned to the zone
    local uci_get_sub = net_service.conn:request(new_msg(
        { 'hal', 'capability', 'uci', '1', 'control', 'get' },
        { main, section_name, list_name }
    ))
    local ret, ctx_err = uci_get_sub:next_msg_with_context(context.with_timeout(net_service.ctx, BUS_TIMEOUT))
    uci_get_sub:unsubscribe()
    if ctx_err then
        log.error(string.format(
            "%s - %s: Get (%s, %s, %s) failed, reason: %s",
            net_service.ctx:value("service_name"),
            net_service.ctx:value("fiber_name"),
            main,
            section_name,
            list_name,
            ctx_err
        ))
    end
    local list_elements = ret.payload.result

    -- Convert to table if necessary
    local network_list = {}
    if type(list_elements) == "string" then
        network_list = { list_elements }
    elseif type(list_elements) == "table" then
        network_list = list_elements
    end

    -- Add this value if not already included
    local already_present = false
    for _, v in ipairs(network_list) do
        if v == list_value then
            already_present = true
            break
        end
    end

    if not already_present then
        table.insert(network_list, list_value)
        net_service.conn:publish(new_msg(
            { 'hal', 'capability', 'uci', '1', 'control', 'set' },
            { main, section_name, list_name, network_list }
        ))
        log.debug("NET: Added", list_value, "to", main, section_name, list_name)
    end
end

local function round(num, numDecimalPlaces)
    local mult = 10 ^ (numDecimalPlaces or 0)
    return math.floor(num * mult + 0.5) / mult
end
local function make_counter()
    local count = 10
    return {
        next = function()
            count = count + 1
            return count
        end,
        reset = function()
            count = 10
        end
    }
end

local metric_counter = make_counter()

-- Channel definitions
local config_channel = channel.new()             -- For config updates
local interface_channel = channel.new()          -- For gsm/interface mappings
local speedtest_result_channel = channel.new()   -- For speedtest requests
local wan_status_channel = channel.new()         -- For wan status supdates
local modem_on_connected_channel = channel.new() -- For wan status supdates
local report_period_channel = channel.new()      -- For config updates

-- Queue definitions
local speedtest_queue = queue.new() -- Unbounded queue for holding speedtest requests
local shaping_queue = queue.new()

--- Conditional variable definitions
local config_signal = cond.new() -- Conditional varibale to signal inital config

local function config_receiver(ctx)
    log.trace("NET: Config receiver starting")
    local sub = net_service.conn:subscribe({ "config", "net" })
    while not ctx:err() do
        op.choice(
            sub:next_msg_op():wrap(function(msg, err)
                if err then
                    log.error("NET: Config receive error:", err)
                end
                log.info("NET: Config Received")
                config_channel:put(msg.payload)
            end),
            ctx:done_op()
        ):perform()
    end
    sub:unsubscribe()
end

local function interface_listener(ctx)
    config_signal:wait() -- Block interface listener until initial configs
    log.trace("NET: Interface listener starting")
    local sub = net_service.conn:subscribe({ "gsm", "modem", "+", "interface" })
    while not ctx:err() do
        op.choice(
            sub:next_msg_op():wrap(function(msg, err)
                if err then
                    log.error("NET: Interface listen error:", err)
                else
                    -- Extract modem_id from topic gsm/modem/<modem_id>/interface
                    local modem_id = msg.topic[3]
                    interface_channel:put {
                        modem_id = modem_id,
                        interface = msg.payload
                    }
                end
            end),
            ctx:done_op()
        ):perform()
    end
    sub:unsubscribe()
end

local function set_firewall_base_config(fw_cfg)
    log.info("NET: Applying base firewall config")

    -- Set default policies
    net_service.conn:publish(new_msg(
        { 'hal', 'capability', 'uci', '1', 'control', 'set' },
        { "firewall", "defaults", "defaults" }
    ))
    for k, v in pairs(fw_cfg.defaults or {}) do
        net_service.conn:publish(new_msg(
            { 'hal', 'capability', 'uci', '1', 'control', 'set' },
            { "firewall", "defaults", k, v }
        ))
    end
    -- Zones
    for _, zone in ipairs(fw_cfg.zones or {}) do
        local id = zone.config.name
        net_service.conn:publish(new_msg(
            { 'hal', 'capability', 'uci', '1', 'control', 'set' },
            { "firewall", id, "zone" }
        ))
        for k, v in pairs(zone.config) do
            net_service.conn:publish(new_msg(
                { 'hal', 'capability', 'uci', '1', 'control', 'set' },
                { "firewall", id, k, v }
            ))
        end
        for _, fwrule in ipairs(zone.forwarding or {}) do
            local forwarding_sub = net_service.conn:request(new_msg(
                { 'hal', 'capability', 'uci', '1', 'control', 'add' },
                { "firewall", "forwarding" }
            ))
            local ret = forwarding_sub:next_msg_with_context(context.with_timeout(net_service.ctx, BUS_TIMEOUT))
            forwarding_sub:unsubscribe()
            local fw_id, err = ret.payload.result, ret.payload.err
            if err then
                log.error("NET: Failed to get forwarding ID:", err)
                return
            end
            net_service.conn:publish(new_msg(
                { 'hal', 'capability', 'uci', '1', 'control', 'set' },
                { "firewall", fw_id, "src", zone.config.name }
            ))
            for k, v in pairs(fwrule) do
                net_service.conn:publish(new_msg(
                    { 'hal', 'capability', 'uci', '1', 'control', 'set' },
                    { "firewall", fw_id, k, v }
                ))
            end
        end
    end

    -- Firewall rules
    for _, rule in ipairs(fw_cfg.rules or {}) do
        local rule_sub = net_service.conn:request(new_msg(
            { 'hal', 'capability', 'uci', '1', 'control', 'add' },
            { "firewall", "rule" }
        ))
        local ret = rule_sub:next_msg_with_context(context.with_timeout(net_service.ctx, BUS_TIMEOUT))
        rule_sub:unsubscribe()
        local rule_id, err = ret.payload.result, ret.payload.err
        if err then
            log.error("NET: Failed to get rule ID:", err)
            return
        end
        for k, v in pairs(rule.config) do
            net_service.conn:publish(new_msg(
                { 'hal', 'capability', 'uci', '1', 'control', 'set' },
                { "firewall", rule_id, k, v }
            ))
        end
    end

    log.info("NET: Base firewall configured")
end

local function set_network_base_config(net_cfg)
    log.info("NET: Applying base network config")

    -- Loopback
    net_service.conn:publish(new_msg(
        { 'hal', 'capability', 'uci', '1', 'control', 'set' },
        { "network", "loopback", "interface" }
    ))
    net_service.conn:publish(new_msg(
        { 'hal', 'capability', 'uci', '1', 'control', 'set' },
        { "network", "loopback", "device", "lo" }
    ))
    net_service.conn:publish(new_msg(
        { 'hal', 'capability', 'uci', '1', 'control', 'set' },
        { "network", "loopback", "proto", "static" }
    ))
    net_service.conn:publish(new_msg(
        { 'hal', 'capability', 'uci', '1', 'control', 'set' },
        { "network", "loopback", "ipaddr", "127.0.0.1" }
    ))
    net_service.conn:publish(new_msg(
        { 'hal', 'capability', 'uci', '1', 'control', 'set' },
        { "network", "loopback", "netmask", "255.0.0.0" }
    ))

    -- Globals
    net_service.conn:publish(new_msg(
        { 'hal', 'capability', 'uci', '1', 'control', 'set' },
        { "network", "globals", "globals" }
    ))
    net_service.conn:publish(new_msg(
        { 'hal', 'capability', 'uci', '1', 'control', 'set' },
        { "network", "globals", "ula_prefix", "auto" }
    ))

    -- Static Routes
    for i, route in ipairs(net_cfg.static_routes or {}) do
        local id = "route_" .. i
        net_service.conn:publish(new_msg(
            { 'hal', 'capability', 'uci', '1', 'control', 'set' },
            { "network", id, "route" }
        ))
        net_service.conn:publish(new_msg(
            { 'hal', 'capability', 'uci', '1', 'control', 'set' },
            { "network", id, "target", route.target }
        ))
        net_service.conn:publish(new_msg(
            { 'hal', 'capability', 'uci', '1', 'control', 'set' },
            { "network", id, "interface", route.interface }
        ))
        if route.netmask then
            net_service.conn:publish(new_msg(
                { 'hal', 'capability', 'uci', '1', 'control', 'set' },
                { "network", id, "netmask", route.netmask }
            ))
        end
        if route.gateway then
            net_service.conn:publish(new_msg(
                { 'hal', 'capability', 'uci', '1', 'control', 'set' },
                { "network", id, "gateway", route.gateway }
            ))
        end
    end

    log.info("NET: Base network configured")
end

local function set_mwan3_base_config(multiwan_cfg)
    log.info("NET: Applying base mwan3 config")

    -- Globals
    net_service.conn:publish(new_msg(
        { 'hal', 'capability', 'uci', '1', 'control', 'set' },
        { "mwan3", "globals", "globals" }
    ))
    net_service.conn:publish(new_msg(
        { 'hal', 'capability', 'uci', '1', 'control', 'set' },
        { "mwan3", "globals", "mmx_mask", "0x3F00" }
    ))

    -- HTTPS Rule
    net_service.conn:publish(new_msg(
        { 'hal', 'capability', 'uci', '1', 'control', 'set' },
        { "mwan3", "https", "rule" }
    ))
    net_service.conn:publish(new_msg(
        { 'hal', 'capability', 'uci', '1', 'control', 'set' },
        { "mwan3", "https", "sticky", "1" }
    ))
    net_service.conn:publish(new_msg(
        { 'hal', 'capability', 'uci', '1', 'control', 'set' },
        { "mwan3", "https", "dest_port", "443" }
    ))
    net_service.conn:publish(new_msg(
        { 'hal', 'capability', 'uci', '1', 'control', 'set' },
        { "mwan3", "https", "proto", "tcp" }
    ))
    net_service.conn:publish(new_msg(
        { 'hal', 'capability', 'uci', '1', 'control', 'set' },
        { "mwan3", "https", "use_policy", "def_pol" }
    ))

    -- Default Rule
    net_service.conn:publish(new_msg(
        { 'hal', 'capability', 'uci', '1', 'control', 'set' },
        { "mwan3", "default_ipv4", "rule" }
    ))
    net_service.conn:publish(new_msg(
        { 'hal', 'capability', 'uci', '1', 'control', 'set' },
        { "mwan3", "default_ipv4", "dest_ip", "0.0.0.0/0" }
    ))
    net_service.conn:publish(new_msg(
        { 'hal', 'capability', 'uci', '1', 'control', 'set' },
        { "mwan3", "default_ipv4", "use_policy", "def_pol" }
    ))

    -- Policy
    net_service.conn:publish(new_msg(
        { 'hal', 'capability', 'uci', '1', 'control', 'set' },
        { "mwan3", "def_pol", "policy" }
    ))
    net_service.conn:publish(new_msg(
        { 'hal', 'capability', 'uci', '1', 'control', 'set' },
        { "mwan3", "def_pol", "last_resort", "unreachable" }
    ))

    log.info("NET: Base mwan3 configured")
end

local function set_dhcp_base_config(dhcp_cfg)
    log.info("NET: Applying base dhcp config")

    -- DHCP domains
    for _, domain in ipairs(dhcp_cfg.domains or {}) do
        local id_sub = net_service.conn:request(new_msg(
            { 'hal', 'capability', 'uci', '1', 'control', 'add' },
            { "dhcp", "domain" }
        ))
        local ret = id_sub:next_msg_with_context(context.with_timeout(net_service.ctx, BUS_TIMEOUT))
        id_sub:unsubscribe()
        local id, err = ret.payload.result, ret.payload.err
        if err then
            log.error("NET: Failed to add domain:", err)
        else
            net_service.conn:publish(new_msg(
                { 'hal', 'capability', 'uci', '1', 'control', 'set' },
                { "dhcp", id, "name", domain.name }
            ))
            net_service.conn:publish(new_msg(
                { 'hal', 'capability', 'uci', '1', 'control', 'set' },
                { "dhcp", id, "ip", domain.ip }
            ))
            log.info("NET: Added static DNS", domain.name, "->", domain.ip)
        end
    end

    log.info("NET: Base dhcp configured")
end

local function set_network_config(instance)
    local net_cfg = instance.cfg
    assert(net_cfg.id, "network config must have an 'id'")
    local net_id = net_cfg.id

    log.info("NET: Applying network config for:", net_id)

    -- 1. Network interface config
    if net_cfg.type == "local" then
        local devicename_sub = net_service.conn:request(new_msg(
            { 'hal', 'capability', 'uci', '1', 'control', 'add' },
            { "network", "device" }
        ))
        local ret = devicename_sub:next_msg_with_context(context.with_timeout(net_service.ctx, BUS_TIMEOUT))
        devicename_sub:unsubscribe()
        local devicename, err = ret.payload.result, ret.payload.err
        if err then
            log.error("NET: Failed to add network device:", err)
            return
        end
        net_service.conn:publish(new_msg(
            { 'hal', 'capability', 'uci', '1', 'control', 'set' },
            { "network", devicename, "name", "br-" .. net_id }
        ))
        net_service.conn:publish(new_msg(
            { 'hal', 'capability', 'uci', '1', 'control', 'set' },
            { "network", devicename, "type", "bridge" }
        ))
        net_service.conn:publish(new_msg(
            { 'hal', 'capability', 'uci', '1', 'control', 'set' },
            { "network", devicename, "ports", net_cfg.interfaces or {} }
        ))
    end

    net_service.conn:publish(new_msg(
        { 'hal', 'capability', 'uci', '1', 'control', 'set' },
        { "network", net_id, "interface" }
    ))
    if net_cfg.type == "local" then
        net_service.conn:publish(new_msg(
            { 'hal', 'capability', 'uci', '1', 'control', 'set' },
            { "network", net_id, "device", "br-" .. net_id }
        ))
    elseif net_cfg.type == "backhaul" then
        net_service.conn:publish(new_msg(
            { 'hal', 'capability', 'uci', '1', 'control', 'set' },
            { "network", net_id, "peerdns", "0" }
        ))
        net_service.conn:publish(new_msg(
            { 'hal', 'capability', 'uci', '1', 'control', 'set' },
            { "network", net_id, "device", net_cfg.interfaces[1] }
        ))
        net_service.conn:publish(new_msg(
            { 'hal', 'capability', 'uci', '1', 'control', 'set' },
            { "network", net_id, "metric", metric_counter.next() }
        ))
    end

    if net_cfg.ipv4.proto == "dhcp" then
        net_service.conn:publish(new_msg(
            { 'hal', 'capability', 'uci', '1', 'control', 'set' },
            { "network", net_id, "proto", "dhcp" }
        ))
    elseif net_cfg.ipv4.proto == "static" then
        net_service.conn:publish(new_msg(
            { 'hal', 'capability', 'uci', '1', 'control', 'set' },
            { "network", net_id, "proto", "static" }
        ))
        net_service.conn:publish(new_msg(
            { 'hal', 'capability', 'uci', '1', 'control', 'set' },
            { "network", net_id, "ipaddr", net_cfg.ipv4.ip_address }
        ))
        net_service.conn:publish(new_msg(
            { 'hal', 'capability', 'uci', '1', 'control', 'set' },
            { "network", net_id, "netmask", net_cfg.ipv4.netmask }
        ))
        if net_cfg.ipv4.gateway then
            net_service.conn:publish(new_msg(
                { 'hal', 'capability', 'uci', '1', 'control', 'set' },
                { "network", net_id, "gateway", net_cfg.ipv4.gateway }
            ))
        end
    end

    -- 2. DHCP
    if net_cfg.dhcp_server then
        net_service.conn:publish(new_msg(
            { 'hal', 'capability', 'uci', '1', 'control', 'set' },
            { "dhcp", net_id, "dhcp" }
        ))
        net_service.conn:publish(new_msg(
            { 'hal', 'capability', 'uci', '1', 'control', 'set' },
            { "dhcp", net_id, "interface", net_id }
        ))
        net_service.conn:publish(new_msg(
            { 'hal', 'capability', 'uci', '1', 'control', 'set' },
            { "dhcp", net_id, "start", net_cfg.dhcp_server.range_skip or "10" }
        ))
        net_service.conn:publish(new_msg(
            { 'hal', 'capability', 'uci', '1', 'control', 'set' },
            { "dhcp", net_id, "limit", net_cfg.dhcp_server.range_extent or "240" }
        ))
        net_service.conn:publish(new_msg(
            { 'hal', 'capability', 'uci', '1', 'control', 'set' },
            { "dhcp", net_id, "leasetime", net_cfg.dhcp_server.lease_time or "12h" }
        ))
    else
        net_service.conn:publish(new_msg(
            { 'hal', 'capability', 'uci', '1', 'control', 'set' },
            { "dhcp", net_id, "dhcp" }
        ))
        net_service.conn:publish(new_msg(
            { 'hal', 'capability', 'uci', '1', 'control', 'set' },
            { "dhcp", net_id, "interface", net_id }
        ))
        net_service.conn:publish(new_msg(
            { 'hal', 'capability', 'uci', '1', 'control', 'set' },
            { "dhcp", net_id, "ignore", "1" }
        ))
    end

    -- connects DHCP to instance and DNS to interface
    if instance.dns_id then
        net_service.conn:publish(new_msg(
            { 'hal', 'capability', 'uci', '1', 'control', 'set' },
            { "dhcp", net_id, "instance", instance.dns_id }
        ))
        net_service.conn:publish(new_msg(
            { 'hal', 'capability', 'uci', '1', 'control', 'set' },
            { "dhcp", instance.dns_id, "local", "/" .. net_id .. "/" }
        ))
        net_service.conn:publish(new_msg(
            { 'hal', 'capability', 'uci', '1', 'control', 'set' },
            { "dhcp", instance.dns_id, "domain", net_id }
        ))
        net_service.conn:publish(new_msg(
            { 'hal', 'capability', 'uci', '1', 'control', 'set' },
            { "dhcp", instance.dns_id, "listen_address", { net_cfg.ipv4.ip_address } }
        ))
        -- add_to_uci_list("dhcp", instance.dns_id, "interface", net_id)
    end

    -- 3. Associate this network with an existing firewall zone
    if net_cfg.firewall and net_cfg.firewall.zone then
        local zone_id = net_cfg.firewall.zone

        add_to_uci_list("firewall", zone_id, "network", net_id)
    end

    -- 4. Add MWAN3 configuration
    if net_cfg.type == 'backhaul' then
        -- first, add the interface
        net_service.conn:publish(new_msg(
            { 'hal', 'capability', 'uci', '1', 'control', 'set' },
            { "mwan3", net_id, "interface" }
        ))
        net_service.conn:publish(new_msg(
            { 'hal', 'capability', 'uci', '1', 'control', 'set' },
            { "mwan3", net_id, "enabled", 1 }
        ))
        net_service.conn:publish(new_msg(
            { 'hal', 'capability', 'uci', '1', 'control', 'set' },
            { "mwan3", net_id, "interval", 1 }
        ))
        net_service.conn:publish(new_msg(
            { 'hal', 'capability', 'uci', '1', 'control', 'set' },
            { "mwan3", net_id, "up", 1 }
        ))
        net_service.conn:publish(new_msg(
            { 'hal', 'capability', 'uci', '1', 'control', 'set' },
            { "mwan3", net_id, "down", 2 }
        ))
        net_service.conn:publish(new_msg(
            { 'hal', 'capability', 'uci', '1', 'control', 'set' },
            { "mwan3", net_id, "family", "ipv4" }
        ))
        net_service.conn:publish(new_msg(
            { 'hal', 'capability', 'uci', '1', 'control', 'set' },
            { "mwan3", net_id, "track_ip", tracking_ips }
        ))
        net_service.conn:publish(new_msg(
            { 'hal', 'capability', 'uci', '1', 'control', 'set' },
            { "mwan3", net_id, "initial_state", instance.online and "online" or "offline" }
        ))
        -- now add the member
        local member_id = net_id .. "_member"
        net_service.conn:publish(new_msg(
            { 'hal', 'capability', 'uci', '1', 'control', 'set' },
            { "mwan3", member_id, "member" }
        ))
        net_service.conn:publish(new_msg(
            { 'hal', 'capability', 'uci', '1', 'control', 'set' },
            { "mwan3", member_id, "interface", net_id }
        ))
        net_service.conn:publish(new_msg(
            { 'hal', 'capability', 'uci', '1', 'control', 'set' },
            { "mwan3", member_id, "metric", instance.speed and net_cfg.multiwan.metric or 99 }
        ))
        net_service.conn:publish(new_msg(
            { 'hal', 'capability', 'uci', '1', 'control', 'set' },
            { "mwan3", member_id, "weight", instance.speed and instance.speed * 10 or 1 }
        ))
        -- now add member to policy
        add_to_uci_list("mwan3", "def_pol", "use_member", member_id)
    end
    log.info("NET: Network config applied successfully for:", net_id)
end

local function set_network_speed(instance)
    local net_cfg = instance.cfg
    local net_id = net_cfg.id

    log.info("NET: Applying network speed for:", net_id)

    -- first, add the interface
    net_service.conn:publish(new_msg(
        { 'hal', 'capability', 'uci', '1', 'control', 'set' },
        { "mwan3", net_id, "initial_state", instance.status == "online" and "online" or "offline" }
    ))
    -- now add the member
    local member_id = net_id .. "_member"
    net_service.conn:publish(new_msg(
        { 'hal', 'capability', 'uci', '1', 'control', 'set' },
        { "mwan3", member_id, "weight", instance.speed and round(instance.speed * 10) or 1 }
    ))
    -- now add member to policy
    add_to_uci_list("mwan3", "def_pol", "use_member", member_id)
    log.debug("NET: Committing changes for: mwan3")
    net_service.conn:publish(new_msg(
        { 'hal', 'capability', 'uci', '1', 'control', 'commit' },
        { "mwan3" }
    ))
    log.info("NET: Speed config applied successfully for:", net_id)
end
local dnsmasq_instances = {} -- maps host filter keys to instance names
local dnsmasq_counter = 0

local function get_dnsmasq_id(default_hosts)
    local id

    if not default_hosts or #default_hosts == 0 then
        default_hosts = {}
        id = "standard"
    else
        -- Generate a key: sorted to canonicalise combinations
        table.sort(default_hosts)
        id = table.concat(default_hosts, "_")
    end

    if dnsmasq_instances[id] then
        return id
    end

    dnsmasq_counter = dnsmasq_counter + 1
    dnsmasq_instances[id] = true

    -- Create dnsmasq config block
    net_service.conn:publish(new_msg(
        { 'hal', 'capability', 'uci', '1', 'control', 'set' },
        { "dhcp", id, "dnsmasq" }
    ))
    net_service.conn:publish(new_msg(
        { 'hal', 'capability', 'uci', '1', 'control', 'set' },
        { "dhcp", id, "domainneeded", '1' }
    ))
    net_service.conn:publish(new_msg(
        { 'hal', 'capability', 'uci', '1', 'control', 'set' },
        { "dhcp", id, "boguspriv", '1' }
    ))
    net_service.conn:publish(new_msg(
        { 'hal', 'capability', 'uci', '1', 'control', 'set' },
        { "dhcp", id, "localise_queries", '1' }
    ))
    net_service.conn:publish(new_msg(
        { 'hal', 'capability', 'uci', '1', 'control', 'set' },
        { "dhcp", id, "rebind_protection", '1' }
    ))
    net_service.conn:publish(new_msg(
        { 'hal', 'capability', 'uci', '1', 'control', 'set' },
        { "dhcp", id, "rebind_localhost", '1' }
    ))
    net_service.conn:publish(new_msg(
        { 'hal', 'capability', 'uci', '1', 'control', 'set' },
        { "dhcp", id, "expandhosts", '1' }
    ))
    net_service.conn:publish(new_msg(
        { 'hal', 'capability', 'uci', '1', 'control', 'set' },
        { "dhcp", id, "nonegcache", '0' }
    ))
    net_service.conn:publish(new_msg(
        { 'hal', 'capability', 'uci', '1', 'control', 'set' },
        { "dhcp", id, "cachesize", '1000' }
    ))
    net_service.conn:publish(new_msg(
        { 'hal', 'capability', 'uci', '1', 'control', 'set' },
        { "dhcp", id, "authoritative", '1' }
    ))
    net_service.conn:publish(new_msg(
        { 'hal', 'capability', 'uci', '1', 'control', 'set' },
        { "dhcp", id, "readethers", '1' }
    ))
    net_service.conn:publish(new_msg(
        { 'hal', 'capability', 'uci', '1', 'control', 'set' },
        { "dhcp", id, "leasefile", "/tmp/dhcp.leases." .. id }
    ))
    net_service.conn:publish(new_msg(
        { 'hal', 'capability', 'uci', '1', 'control', 'set' },
        { "dhcp", id, "resolvfile", '/tmp/resolv.conf.d/resolv.conf.auto' }
    ))
    net_service.conn:publish(new_msg(
        { 'hal', 'capability', 'uci', '1', 'control', 'set' },
        { "dhcp", id, "nonwildcard", '1' }
    ))
    net_service.conn:publish(new_msg(
        { 'hal', 'capability', 'uci', '1', 'control', 'set' },
        { "dhcp", id, "localservice", '1' }
    ))
    net_service.conn:publish(new_msg(
        { 'hal', 'capability', 'uci', '1', 'control', 'set' },
        { "dhcp", id, "port", '53' }
    ))
    net_service.conn:publish(new_msg(
        { 'hal', 'capability', 'uci', '1', 'control', 'set' },
        { "dhcp", id, "server", { "8.8.8.8", "1.1.1.1" } }
    ))
    net_service.conn:publish(new_msg(
        { 'hal', 'capability', 'uci', '1', 'control', 'set' },
        { "dhcp", id, "noresolv", "1" }
    ))

    -- Add any blocklist host files
    if #default_hosts > 0 then
        local path_list = {}
        for _, list in ipairs(default_hosts) do
            table.insert(path_list, "/etc/jng/hosts/" .. list)
        end
        net_service.conn:publish(new_msg(
            { 'hal', 'capability', 'uci', '1', 'control', 'set' },
            { "dhcp", id, "addnhosts", path_list }
        ))
    end

    return id
end

local function uci_manager(ctx)
    log.trace("NET: UCI manager starting")

    local uci_sub = net_service.conn:subscribe({ 'hal', 'capability', 'uci', '1' })
    uci_sub:next_msg_with_context(ctx) -- wait for uci capability to appear
    uci_sub:unsubscribe()

    -- setup restart policies for each config
    net_service.conn:publish(new_msg(
        { 'hal', 'capability', 'uci', '1', 'control', 'set_restart_actions' },
        { "network", { { "/etc/init.d/network", "reload" } } }
    ))
    net_service.conn:publish(new_msg(
        { 'hal', 'capability', 'uci', '1', 'control', 'set_restart_actions' },
        { "firewall", { { "/etc/init.d/firewall", "restart" } } }
    ))
    net_service.conn:publish(new_msg(
        { 'hal', 'capability', 'uci', '1', 'control', 'set_restart_actions' },
        { "dhcp", {
            { "/etc/init.d/dnsmasq", "restart" },
            { "/etc/init.d/odhcpd",  "restart" }
        } }
    ))
    net_service.conn:publish(new_msg(
        { 'hal', 'capability', 'uci', '1', 'control', 'set_restart_actions' },
        { "mwan3", { { "/etc/init.d/mwan3", "restart" } } }
    ))

    local networks = {}
    local resolved_interfaces = {} -- key = modem_id or ifname, value = resolved interface string

    local function on_config(cfg)
        local start = sc.monotime()
        -- cleanup
        local areas = { "network", "firewall", "dhcp", "mwan3" }
        for _, area in ipairs(areas) do
            -- Delete all sections in each UCI config area
            local foreach_sub = net_service.conn:request(new_msg(
                { 'hal', 'capability', 'uci', '1', 'control', 'foreach' },
                { area, nil,
                    function(cursor, s)
                        cursor:delete(area, s[".name"])
                    end
                }
            ))
            local ret = foreach_sub:next_msg_with_context(context.with_timeout(net_service.ctx, BUS_TIMEOUT))
            foreach_sub:unsubscribe()
            if ret.payload.err then
                log.error("NET: Failed to clear UCI area", area, ":", ret.payload.err)
            end
        end
        metric_counter.reset()
        -- config application
        set_firewall_base_config(cfg.firewall)
        set_network_base_config(cfg.network)
        set_mwan3_base_config(cfg.multiwan) -- NEED TO CREATE MULTIWAN GLOBALS SECTION
        set_dhcp_base_config(cfg.dhcp)

        for _, net_cfg in ipairs(cfg.network or {}) do
            local net_id = net_cfg.id
            networks[net_id] = {
                cfg = net_cfg,
                dns_id = net_cfg.type == "local" and
                    get_dnsmasq_id(net_cfg.dns_server and net_cfg.dns_server.default_hosts or {}),
                status = networks[net_id] and networks[net_id].status or "offline",
                speed = networks[net_id] and networks[net_id].speed,
                resolved = net_cfg.interfaces and net_cfg.interfaces[1] and true or false
            }
            local modem_id = net_cfg.modem_id
            local iface = net_cfg.interfaces and net_cfg.interfaces[1]

            if modem_id and not resolved_interfaces[modem_id] then
                -- Modem-dependent and unresolved
                log.debug("NET: Deferring config for", net_id, "— waiting for modem", modem_id)
            elseif iface or (modem_id and resolved_interfaces[modem_id]) then
                -- Ready to apply
                if modem_id then net_cfg.interfaces = { resolved_interfaces[modem_id] } end
                set_network_config(networks[net_id])
            else
                log.warn("NET: Network", net_id, "has no usable interface or modem_id")
            end
        end
        for _, area in ipairs(areas) do
            log.debug("NET: Committing changes for:", area)
            net_service.conn:publish(new_msg(
                { 'hal', 'capability', 'uci', '1', 'control', 'commit' },
                { area }
            ))
        end
        print("That took:", sc.monotime() - start)

        for _, net_cfg in ipairs(cfg.network or {}) do
            shaping_queue:put(net_cfg)
        end
        -- If this is the initial config, signal config applied
        config_signal:signal()

        local report_period = cfg.report_period
        if report_period ~= nil then
            report_period_channel:put(report_period)
        end
    end

    local function on_wan_status(msg)
        local network, status = msg.network, msg.status
        if not networks[network] then
            networks[network] = { status = status }
            log.info("NET: Status for unknown network", network, "set to", status, ", skipping speedtest")
            return
        elseif (not networks[network].cfg) or (not networks[network].cfg.interfaces) then
            networks[network].status = status
            log.info("NET: Status for network", network, "with unknown interface set to", status, ", skipping speedtest")
            return
        end
        local old_status = networks[network].status
        networks[network].status = status
        if old_status ~= status then
            log.debug("NET: WAN state change", network, status)

            -- Trigger speedtest only on new connections
            if status == "online" then
                if not networks[network].speed or sc.monotime() - networks[network].speed_time > 180 then
                    local interface = networks[network].cfg.interfaces[1]
                    log.info("NET: network", network, ": newly online, scheduling speedtest")
                    speedtest_queue:put({ network = network, interface = interface })
                else
                    log.info("NET: network", network, ": has recent speed, skipping speedtest")
                end
            end
        end
    end

    local function on_interface(msg)
        local areas = { "network", "firewall", "dhcp", "mwan3" }
        local modem_id = msg.modem_id
        local iface = msg.interface
        if not modem_id or not iface then return end

        resolved_interfaces[modem_id] = iface
        log.info("NET: Interface", iface, "resolved for modem", modem_id)

        -- Check pending networks that depend on this modem
        for net_id, net in pairs(networks) do
            if net.cfg and net.cfg.modem_id == modem_id then
                net.cfg.interfaces = { iface }
                set_network_config(net)
                log.info("NET: Applied deferred network config for", net_id)
                for _, area in ipairs(areas) do
                    log.debug("NET: Committing changes for:", area)
                    net_service.conn:publish(new_msg(
                        { 'hal', 'capability', 'uci', '1', 'control', 'commit' },
                        { area }
                    ))
                end
            end
        end
    end

    local function on_speedtest_result(result)
        networks[result.network].speed = result.speed
        networks[result.network].speed_time = sc.monotime()
        set_network_speed(networks[result.network])
        net_service.conn:publish(new_msg({ "net", result.network, "download_speed" }, result.speed))
    end

    local function on_modem_connected(modem_id)
        for _, net in pairs(networks) do
            if net.cfg and net.cfg.modem_id == modem_id then
                local ifup_sub = net_service.conn:request(new_msg(
                    { 'hal', 'capability', 'uci', '1', 'control', 'ifup' },
                    { net.cfg.id }
                ))
                local ret, ctx_err = ifup_sub:next_msg_with_context(context.with_timeout(net_service.ctx, BUS_TIMEOUT))
                if ctx_err or ret.payload.err then
                    log.error(string.format(
                        "%s - %s: Failed to bring up network %s: %s",
                        net_service.ctx:value("service_name"),
                        net_service.ctx:value("fiber_name"),
                        net.cfg.id,
                        ctx_err or ret.payload.err
                    ))
                    return
                else
                    log.trace(string.format(
                        "%s - %s: Successfully brought up network %s",
                        net_service.ctx:value("service_name"),
                        net_service.ctx:value("fiber_name"),
                        net.cfg.id
                    ))
                end
                ifup_sub:unsubscribe()
            end
        end
    end

    ---Periodic gathering a publish of net information
    local function report_metrics(ctx)
        local function read_interface_file_numeric(id, stat_name)
            local path = "/sys/class/net/" .. id .. "/statistics/" .. stat_name
            local f = file.open(path, "r")
            if not f then return nil, "Failed to open interface file: " .. path end

            f:seek(0) -- Rewind to beginning
            local metric = tonumber(f:read_all_chars())
            f:close()
            return metric
        end

        local report_period = report_period_channel:get()
        while not ctx:err() do
            local net_metrics = {}
            for net_id, net in pairs(networks) do
                if net.cfg and net.cfg.interfaces ~= nil and #net.cfg.interfaces > 0 then
                    local iface_metrics = {}

                    local rx_bytes, e = read_interface_file_numeric(net.cfg.interfaces[1], "rx_bytes")
                    if e == nil then iface_metrics.rx_bytes = rx_bytes end

                    local rx_packets, e = read_interface_file_numeric(net.cfg.interfaces[1], "rx_packets")
                    if e == nil then iface_metrics.rx_packets = rx_packets end

                    local rx_dropped, e = read_interface_file_numeric(net.cfg.interfaces[1], "rx_dropped")
                    if e == nil then iface_metrics.rx_dropped = rx_dropped end

                    local rx_errors, e = read_interface_file_numeric(net.cfg.interfaces[1], "rx_errors")
                    if e == nil then iface_metrics.rx_errors = rx_errors end

                    local tx_bytes, e = read_interface_file_numeric(net.cfg.interfaces[1], "tx_bytes")
                    if e == nil then iface_metrics.tx_bytes = tx_bytes end

                    local tx_packets, e = read_interface_file_numeric(net.cfg.interfaces[1], "tx_packets")
                    if e == nil then iface_metrics.tx_packets = tx_packets end

                    local tx_dropped, e = read_interface_file_numeric(net.cfg.interfaces[1], "tx_dropped")
                    if e == nil then iface_metrics.tx_dropped = tx_dropped end

                    local tx_errors, e = read_interface_file_numeric(net.cfg.interfaces[1], "tx_errors")
                    if e == nil then iface_metrics.tx_errors = tx_errors end

                    if next(iface_metrics) ~= nil then
                        net_metrics[net_id] = iface_metrics
                    end
                end
            end

            if next(net_metrics) ~= nil then
                net_service.conn:publish_multiple({ 'net' }, net_metrics, { retained = true })
            end

            op.choice(
                sleep.sleep_op(report_period),
                report_period_channel:get_op():wrap(function(new_period)
                    report_period = new_period
                end),
                ctx:done_op()
            ):perform()
        end
    end

    fiber.spawn(function() report_metrics(ctx) end)

    while ctx:err() == nil do
        op.choice(
            config_channel:get_op():wrap(on_config),
            interface_channel:get_op():wrap(on_interface),
            speedtest_result_channel:get_op():wrap(on_speedtest_result),
            wan_status_channel:get_op():wrap(on_wan_status),
            modem_on_connected_channel:get_op():wrap(on_modem_connected),
            ctx:done_op()
        ):perform()
    end
end

local function wan_monitor(ctx)
    config_signal:wait()       -- Block wan monitor until initial configs
    local ubus_active_sub = net_service.conn:subscribe({ 'hal', 'capability', 'ubus', '1' })
    ubus_active_sub:next_msg() -- Block wan monitor until ubus capability is active

    log.trace("NET: WAN monitor starting")

    -- first, we get the initial state of the interfaces, we use command line ubus for consistency with `ubus listen`
    local status_sub = net_service.conn:request(new_msg(
        { 'hal', 'capability', 'ubus', '1', 'control', 'call' },
        { "mwan3", "status" }
    ))
    local status_response, ctx_err = status_sub:next_msg_with_context(context.with_timeout(ctx, BUS_TIMEOUT))
    status_sub:unsubscribe()

    if ctx_err or status_response.payload.err then
        local err = ctx_err or status_response.payload.err
        log.error("NET: WAN monitor: could not get initial state: " .. err)
        return
    end

    local res = status_response.payload.result

    for network, data in pairs(res.interfaces or {}) do
        local status = data.status == "online" and "online" or "offline"
        wan_status_channel:put({ network = network, status = status })

        net_service.conn:publish(new_msg({ "net", network, "status" }, status))
        net_service.conn:publish(new_msg(
            { "net", data.interface, "curr_uptime" },
            status == "online" and os.time() or 0
        ))
    end

    -- now we start a continuous loop to monitor for changes in interface state
    local listen_sub = net_service.conn:request(new_msg(
        { 'hal', 'capability', 'ubus', '1', 'control', 'listen' },
        { 'hotplug.mwan3' }
    ))
    local listen_response, ctx_err = listen_sub:next_msg_with_context(context.with_timeout(ctx, BUS_TIMEOUT))
    listen_sub:unsubscribe()
    if ctx_err or listen_response.payload.err then
        local err = ctx_err or listen_response.payload.err
        log.error("NET: ubus listen failed:", err)
        return
    end
    local stream_id = listen_response.payload.result.stream_id
    local hotplug_sub = net_service.conn:subscribe(
        { 'hal', 'capability', 'ubus', '1', 'info', 'stream', stream_id }
    )
    local stream_end_sub = net_service.conn:subscribe(
        { 'hal', 'capability', 'ubus', '1', 'info', 'stream', stream_id, 'closed' }
    )

    local process_ended = false

    while not ctx:err() and not process_ended do
        op.choice(
            hotplug_sub:next_msg_op():wrap(function(msg)
                local event = msg.payload
                if not event then return end
                local data = event["hotplug.mwan3"]
                log.debug("MWAN3 hotplug event received!")

                local status = data.action == "connected" and "online" or "offline"
                wan_status_channel:put({
                    network = data.interface,
                    status = status
                })
                net_service.conn:publish(new_msg({ "net", data.interface, "status" }, status))
                net_service.conn:publish(new_msg(
                    { "net", data.interface, "curr_uptime" },
                    status == "online" and os.time() or 0
                ))
            end),
            stream_end_sub:next_msg_op():wrap(function(stream_ended)
                if stream_ended.payload then
                    process_ended = true
                end
            end),
            ctx:done_op():wrap(function()
                net_service.conn:publish(new_msg(
                    { 'hal', 'capability', 'ubus', '1', 'control', 'stop_stream' },
                    { stream_id }
                ))
            end)
        ):perform()
    end
end

local function speedtest_worker(ctx)
    log.trace("NET: Speedtest worker starting")
    while not ctx:err() do
        log.trace("NET: Speedtest worker waiting for jobs")
        local msg = speedtest_queue:get()
        -- halt any config restarts from happening during speedtest
        local halt_sub = net_service.conn:request(new_msg(
            { 'hal', 'capability', 'uci', '1', 'control', 'halt_restarts' },
            {}
        ))
        halt_sub:next_msg_with_context(ctx)
        halt_sub:unsubscribe()
        local results, err = speedtest.run(ctx, msg.network, msg.interface)
        -- allow config restarts to take place
        net_service.conn:publish(new_msg(
            { 'hal', 'capability', 'uci', '1', 'control', 'continue_restarts' },
            {}
        ))
        if err then
            log.error("NET:", "Speedtest error:", err)
        else
            log.info(string.format(
                "Speedtest complete for network: wan. %.2f Mbps, data used: %.2f MB in %.2f Secs",
                results.peak, results.data, results.time
            ))
            speedtest_result_channel:put({
                network = msg.network,
                speed = results.peak
            })
        end
    end
end

local function shaping_worker(ctx)
    log.trace("NET: Shaping worker starting")
    while not ctx:err() do
        local net_cfg = shaping_queue:get()
        if net_cfg.shaping and net_cfg.interfaces then
            log.trace("NET: Shaping worker got config for:", net_cfg.id)

            local ifup_sub = net_service.conn:request(new_msg(
                { 'hal', 'capability', 'uci', '1', 'control', 'ifup' },
                { net_cfg.id }
            ))
            local ret, ctx_err = ifup_sub:next_msg_with_context(net_service.ctx)
            ifup_sub:unsubscribe()
            if ctx_err or ret.payload.err then
                log.error(string.format(
                    "%s - %s: Failed to bring up network %s: %s",
                    net_service.ctx:value("service_name"),
                    net_service.ctx:value("fiber_name"),
                    net_cfg.id,
                    ctx_err or ret.payload.err
                ))
                fiber.spawn(function()
                    sleep.sleep(2)
                    shaping_queue:put(net_cfg)
                end)
            else
                log.trace(string.format(
                    "%s - %s: Successfully brought up network %s",
                    net_service.ctx:value("service_name"),
                    net_service.ctx:value("fiber_name"),
                    net_cfg.id
                ))
                -- halt any config restarts from happening during shaping
                local halt_sub = net_service.conn:request(new_msg(
                    { 'hal', 'capability', 'uci', '1', 'control', 'halt_restarts' },
                    {}
                ))
                halt_sub:next_msg_with_context(ctx)
                halt_sub:unsubscribe()
                shaping.apply(net_cfg)
                -- allow config restarts to take place
                net_service.conn:publish(new_msg(
                    { 'hal', 'capability', 'uci', '1', 'control', 'continue_restarts' },
                    {}
                ))
            end
        end
    end
end

local function modem_state_listener(ctx)
    log.trace("NET: Interface listener starting")
    local sub = net_service.conn:subscribe({ "gsm", "modem", "+", "state" })
    while not ctx:err() do
        op.choice(
            sub:next_msg_op():wrap(function(msg, err)
                if err then
                    log.error("NET: Interface listen error:", err)
                else
                    local payload = msg.payload
                    if payload and payload.prev_state ~= "connected" and payload.curr_state == "connected" then
                        -- Extract modem_id from topic gsm/modem/<modem_id>/state
                        local modem_id = msg.topic[3]
                        modem_on_connected_channel:put(modem_id)
                    end
                end
            end),
            ctx:done_op()
        ):perform()
    end
    sub:unsubscribe()
end

function net_service:start(ctx, conn)
    log.trace("Starting NET Service")
    self.ctx = ctx
    self.conn = conn

    -- Spawn core components
    fiber.spawn(function() config_receiver(ctx) end)
    fiber.spawn(function() interface_listener(ctx) end)
    fiber.spawn(function() uci_manager(ctx) end)
    fiber.spawn(function() wan_monitor(ctx) end)
    fiber.spawn(function() speedtest_worker(ctx) end)
    fiber.spawn(function() shaping_worker(ctx) end)
    fiber.spawn(function() modem_state_listener(ctx) end)
end

return net_service
