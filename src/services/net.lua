local fiber = require "fibers.fiber"
local queue = require "fibers.queue"
local exec = require "fibers.exec"
local channel = require "fibers.channel"
local op = require "fibers.op"
local sc = require "fibers.utils.syscall"
local cjson = require "cjson.safe"
local log = require "log"
local uci = require "uci"
local speedtest = require "services.net.speedtest"
local new_msg = require "bus".new_msg

local cursor = uci.cursor("/tmp/test", "/tmp/.uci") -- runtime-safe!

-------------------------------------------------------
-- Helper functions

local function add_to_uci_list(main, section_name, list_name, list_value)
    -- Read current networks assigned to the zone
    local list_elements = cursor:get(main, section_name, list_name)

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
        cursor:set(main, section_name, list_name, network_list)
        log.debug("NET: Added", list_value, "to", main, section_name, list_name)
    end
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


-- top-level service
local net_service = {
    name = 'net'
}
net_service.__index = net_service

-- Channel definitions
local config_channel = channel.new()      -- For config updates
local interface_channel = channel.new()   -- For gsm/interface mappings
local speedtest_result_channel = channel.new() -- For speedtest requests

-- Queue definitions
local speedtest_queue = queue.new()       -- Unbounded queue for holding speedtest requests

local function config_receiver(ctx, conn)
    log.trace("NET: Config receiver starting")
    local sub = conn:subscribe({"config", "net"})
    while not ctx:err() do
        op.choice(
            sub:next_msg_op():wrap(function (msg, err)
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

local function interface_listener(ctx, conn)
    log.trace("NET: Interface listener starting")
    local sub = conn:subscribe({"gsm", "modem", "+", "interface"})
    while not ctx:err() do
        op.choice(
            sub:next_msg_op():wrap(function (msg, err)
                if err then
                    log.error("NET: Interface listen error:", err)
                end
                -- Extract modem_id from topic gsm/<modem_id>/interface
                local modem_id = msg.topic[3]
                interface_channel:put{
                    modem_id = modem_id,
                    interface = msg.payload
                }
            end),
            ctx:done_op()
        ):perform()
    end
    sub:unsubscribe()
end

local function apply_firewall_base_config(fw_cfg)
    log.info("NET: Applying base firewall config")

    -- Set default policies
    cursor:set("firewall", "defaults", "defaults")
    cursor:set("firewall", "defaults", "syn_flood", "1")
    cursor:set("firewall", "defaults", "input", "ACCEPT")
    cursor:set("firewall", "defaults", "forward", "REJECT")
    cursor:set("firewall", "defaults", "output", "ACCEPT")
    cursor:set("firewall", "defaults", "disable_ipv6", "1")

    -- Zones
    for _, zone in ipairs(fw_cfg.zones or {}) do
        local name = zone.id
        cursor:set("firewall", name, "zone")
        cursor:set("firewall", name, "name", name)
        cursor:set("firewall", name, "input", zone.input)
        cursor:set("firewall", name, "output", zone.output)
        cursor:set("firewall", name, "forward", zone.forward)
        if zone.masquerade then
            cursor:set("firewall", name, "masq", "1")
        end
        if zone.mtu_fix then
            cursor:set("firewall", name, "mtu_fix", "1")
        end
    end

    -- Forwarding rules
    for i, rule in ipairs(fw_cfg.forwarding or {}) do
        local id = cursor:add("firewall", "forwarding")
        cursor:set("firewall", id, "src", rule.src)
        cursor:set("firewall", id, "dest", rule.dest)
    end

    -- Firewall rules
    for _, rule in ipairs(fw_cfg.rules or {}) do
        local id = cursor:add("firewall", "rule")
        for k, v in pairs(rule) do
            cursor:set("firewall", id, k, v)
        end
    end

    log.info("NET: Base firewall config committed")
end

local function apply_network_base_config(net_cfg)
    log.info("NET: Applying base network config")

    -- Loopback
    cursor:set("network", "loopback", "interface")
    cursor:set("network", "loopback", "device", "lo")
    cursor:set("network", "loopback", "proto", "static")
    cursor:set("network", "loopback", "ipaddr", "127.0.0.1")
    cursor:set("network", "loopback", "netmask", "255.0.0.0")

    -- Globals
    cursor:set("network", "globals", "globals")
    cursor:set("network", "globals", "ula_prefix", "auto")

    -- Static Routes
    for i, route in ipairs(net_cfg.static_routes or {}) do
        local id = "route_" .. i
        cursor:set("network", id, "route")
        cursor:set("network", id, "target", route.target)
        cursor:set("network", id, "interface", route.interface)
        if route.netmask then
            cursor:set("network", id, "netmask", route.netmask)
        end
        if route.gateway then
            cursor:set("network", id, "gateway", route.gateway)
        end
    end

    log.info("NET: Base network config committed")
end

local function apply_network_config(instance)
    local net_cfg = instance.cfg
    assert(net_cfg.id, "network config must have an 'id'")
    local net_id = net_cfg.id

    log.info("NET: Applying network config for:", net_id)

    -- 1. Network interface config
    if net_cfg.type == "local" then
        local devicename = cursor:add("network", "device")
        cursor:set("network", devicename, "name", "br-" .. net_id)
        cursor:set("network", devicename, "type", "bridge")
        cursor:set("network", devicename, "ports", net_cfg.interfaces or {})
    end

    cursor:set("network", net_id, "interface")
    if net_cfg.type == "local" then
        cursor:set("network", net_id, "device", "br-" .. net_id)
    elseif net_cfg.type == "backhaul" then
        cursor:set("network", net_id, "device", net_cfg.interfaces[1])
        cursor:set("network", net_id, "metric", metric_counter.next())
    end

    if net_cfg.ipv4.proto == "dhcp" then
        cursor:set("network", net_id, "proto", "dhcp")
    elseif net_cfg.ipv4.proto == "static" then
        cursor:set("network", net_id, "proto", "static")
        cursor:set("network", net_id, "ipaddr", net_cfg.ipv4.ip_address)
        cursor:set("network", net_id, "netmask", net_cfg.ipv4.netmask)
        if net_cfg.ipv4.gateway then cursor:set("network", net_id, "gateway", net_cfg.ipv4.gateway) end
    end

    -- 2. DHCP
    if net_cfg.dhcp_server then
        cursor:set("dhcp", net_id, "dhcp")
        cursor:set("dhcp", net_id, "interface", net_id)
        cursor:set("dhcp", net_id, "start", net_cfg.dhcp_server.range_skip or "10")
        cursor:set("dhcp", net_id, "limit", net_cfg.dhcp_server.range_extent or "240")
        cursor:set("dhcp", net_id, "leasetime", net_cfg.dhcp_server.lease_time or "12h")
    else
        cursor:set("dhcp", net_id, "dhcp")
        cursor:set("dhcp", net_id, "interface", net_id)
        cursor:set("dhcp", net_id, "ignore", "1")
    end

    -- connects DHCP to instance and DNS to interface
    if instance.dns_id then
        cursor:set("dhcp", net_id, "instance", instance.dns_id)
        add_to_uci_list("dhcp", instance.dns_id, "interface", net_id)
    end

    -- 3. Associate this network with an existing firewall zone
    if net_cfg.firewall and net_cfg.firewall.zone then
        local zone_id = net_cfg.firewall.zone

        add_to_uci_list("firewall", zone_id, "network", net_id)
    end

    log.info("NET: Network config applied successfully for:", net_id)
end

local dnsmasq_instances = {}  -- maps host filter keys to instance names
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
    cursor:set("dhcp", id, "dnsmasq")
    cursor:set("dhcp", id, "domain", "lan")
    cursor:set("dhcp", id, "authoritative", "1")
    cursor:set("dhcp", id, "localservice", "1")
    cursor:set("dhcp", id, "nonwildcard", "1")
    cursor:set("dhcp", id, "localise_queries", "1")
    cursor:set("dhcp", id, "rebind_protection", "1")
    cursor:set("dhcp", id, "rebind_localhost", "1")
    cursor:set("dhcp", id, "expandhosts", "1")
    cursor:set("dhcp", id, "boguspriv", "1")
    cursor:set("dhcp", id, "leasefile", "/tmp/dhcp.leases." .. id)
    cursor:set("dhcp", id, "local", "/lan/")
    cursor:set("dhcp", id, "domainneeded", "1")
    cursor:set("dhcp", id, "nonegcache", "0")
    cursor:set("dhcp", id, "filterwin2k", "0")
    cursor:set("dhcp", id, "readethers", "1")
    cursor:set("dhcp", id, "server", { "8.8.8.8", "1.1.1.1" })
    cursor:set("dhcp", id, "cachesize", "1000")

    -- Add any blocklist host files
    if #default_hosts > 0 then
        local path_list = {}
        for _, list in ipairs(default_hosts) do
            table.insert(path_list, "/etc/jng/hosts/" .. list)
        end
        cursor:set("dhcp", id, "addnhosts", path_list)
    end

    return id
end

local function uci_applier(ctx)
    log.info("NET: applying UCI config")
    exec.command("/etc/init.d/network", "reload"):run()
    exec.command("/etc/init.d/firewall", "restart"):run()
    exec.command("/etc/init.d/dnsmasq", "restart"):run()
    exec.command("/etc/init.d/odhcpd", "restart"):run()
    log.info("NET: UCI config applied")
end
local function uci_manager(ctx)
    log.trace("NET: UCI manager starting")

    local networks = {}
    local resolved_interfaces = {} -- key = modem_id or ifname, value = resolved interface string

    local function on_config(cfg)
        local start = sc.monotime()
        -- cleanup
        local areas = { "network", "firewall", "dhcp" }
        for _, area in ipairs(areas) do
            cursor:foreach(area, nil, function(s)
                cursor:delete(area, s[".name"])
            end)
        end
        metric_counter.reset()
        -- config application
        apply_firewall_base_config(cfg.firewall)
        apply_network_base_config(cfg.network)
        for _, net_cfg in ipairs(cfg.network or {}) do
            local net_id = net_cfg.id
            networks[net_id] = {
                cfg = net_cfg,
                dns_id = net_cfg.type == "local" and
                    get_dnsmasq_id(net_cfg.dns_server and net_cfg.dns_server.default_hosts or {}),
                pending = true
            }
            local modem_id = net_cfg.modem_id
            local iface = net_cfg.interfaces and net_cfg.interfaces[1]

            if modem_id and not resolved_interfaces[modem_id] then
                -- Modem-dependent and unresolved
                log.debug("NET: Deferring config for", net_id, "— waiting for modem", modem_id)
            elseif iface or (modem_id and resolved_interfaces[modem_id]) then
                -- Ready to apply
                if modem_id then net_cfg.interfaces = { resolved_interfaces[modem_id] } end
                apply_network_config(networks[net_id])
            else
                log.warn("NET: Network", net_id, "has no usable interface or modem_id")
            end
        end
        for _, area in ipairs(areas) do
            cursor:commit(area)
        end
        print("That took:", sc.monotime() - start)
    end

    local function on_interface(msg)
        local modem_id = msg.modem_id
        local iface = msg.interface
        if not modem_id or not iface then return end

        resolved_interfaces[modem_id] = iface
        log.info("NET: Interface", iface, "resolved for modem", modem_id)

        -- Check pending networks that depend on this modem
        for net_id, net in pairs(networks) do
            if net.cfg.modem_id == modem_id then
                net.cfg.interfaces = { iface }
                apply_network_config(net)
                log.info("NET: Applied deferred network config for", net_id)
            end
        end
    end

    local function on_speedtest_result(result)
        networks[result.network].speed = result.speed
        apply_network_config(networks[result.network])
    end
    while ctx:err() == nil do
        op.choice(
            config_channel:get_op():wrap(on_config),
            interface_channel:get_op():wrap(on_interface),
            speedtest_result_channel:get_op():wrap(on_speedtest_result),
            ctx:done_op()
        ):perform()
    end
end

local function wan_monitor(ctx)
    log.trace("NET: WAN monitor starting")

    -- State tracking table
    local interface_states = {}

    local function handle_event(iface, status)
        local prev_status = interface_states[iface]
        if prev_status ~= status then
            log.debug("NET: WAN state change", iface, status)
            interface_states[iface] = status

            -- Trigger speedtest only on new connections
            if status == "online" then
                log.info("NET: network", iface, ": newly online, scheduling speedtest")
                speedtest_queue:put(iface)
            end
        end
    end

    -- first, we get the initial state of the interfaces, we use command line ubus for consistency with `ubus listen`
    local output, err = exec.command("ubus", "call", "mwan3", "status"):output()
    if err then log.error("NET: WAN monitor: could not start ubus call") return end

    local res, err = cjson.decode(output)
    if err then log.error("NET: WAN monitor: could not get initial state: "..err) return end

    for iface, data in pairs(res.interfaces or {}) do
        local status = data.status == "online" and "online" or "offline"
        handle_event(iface, status)
    end

    -- now we start a continuous loop to monitor for changes in interface state
    local cmd = exec.command("ubus", "listen", "hotplug.mwan3")
    local stdout = cmd:stdout_pipe()
    if not stdout then log.error("NET: could not create stdout pipe for ubus listen") return end

    local err = cmd:start()
    if err then log.error("NET: ubus listen failed:", err) return end

    local process_ended = false

    while not ctx:err() and not process_ended do
        op.choice(
            stdout:read_line_op():wrap(function (line)
                if not line then
                    log.error("NET: ubus listen unexpectedly exited")
                    process_ended = true
                else
                    local event, err = cjson.decode(line)
                    if err then log.error("NET: ubus listen line decode failed:", err) return end
                    local data = event["hotplug.mwan3"]
                    for k,v in pairs(data) do print(k,v) end

                    if data.action == "connected" then
                        handle_event(data.interface, "online")
                    elseif data.action == "disconnected" then
                        handle_event(data.interface, "offline")
                    end
                end
            end),
            ctx:done_op():wrap(function ()
                cmd:kill()
            end)
        ):perform()
    end
    cmd:wait()
    stdout:close()
end

local function speedtest_worker(ctx)
    log.trace("NET: Speedtest worker starting")
    while not ctx:err() do
        log.trace("NET: Speedtest worker waiting for jobs")
        local owrt_iface, linux_iface = speedtest_queue:get()
        local results, err = speedtest.run(ctx, owrt_iface, "eth0")
        if err then log.error("NET:","Speedtest error:", err) end
        log.info(string.format(
            "Speedtest complete for network: wan. %.2f Mbps, data used: %.2f MB in %.2f Secs",
             results.peak, results.data, results.time
        ))

    end
end


function net_service:start(ctx, conn)
    log.trace("Starting NET Service")

    -- Spawn core components
    fiber.spawn(function() config_receiver(ctx, conn) end)
    fiber.spawn(function() interface_listener(ctx, conn) end)
    fiber.spawn(function() uci_manager(ctx, conn) end)
    fiber.spawn(function() wan_monitor(ctx, conn) end)
    fiber.spawn(function() speedtest_worker(ctx, conn) end)
end

return net_service
