local file = require 'fibers.stream.file'
local fiber = require "fibers.fiber"
local sleep = require "fibers.sleep"
local queue = require "fibers.queue"
local exec = require "fibers.exec"
local channel = require "fibers.channel"
local cond = require "fibers.cond"
local op = require "fibers.op"
local sc = require "fibers.utils.syscall"
local cjson = require "cjson.safe"
local log = require "services.log"
local shaping = require "services.net.shaping"
local uci = require "uci"
local speedtest = require "services.net.speedtest"
local new_msg = require "bus".new_msg
local cursor = uci.cursor() -- runtime-safe!
-- local cursor = uci.cursor("/tmp/test", "/tmp/.uci") -- runtime-safe!

-- top-level service
local net_service = {
    name = 'net'
}
net_service.__index = net_service
-------------------------------------------------------
-- Constants
local tracking_ips = { "8.8.8.8", "1.1.1.1" }
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
local config_channel = channel.new()           -- For config updates
local interface_channel = channel.new()        -- For gsm/interface mappings
local speedtest_result_channel = channel.new() -- For speedtest requests
local wan_status_channel = channel.new()       -- For wan status supdates
local modem_on_connected_channel = channel.new()       -- For wan status supdates
local report_period_channel = channel.new()           -- For config updates

-- Queue definitions
local speedtest_queue = queue.new()      -- Unbounded queue for holding speedtest requests
local config_applier_queue = queue.new() -- Unbounded queue for holding config changes

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
    cursor:set("firewall", "defaults", "defaults")
    for k, v in pairs(fw_cfg.defaults or {}) do
        cursor:set("firewall", "defaults", k, v)
    end
    -- Zones
    for _, zone in ipairs(fw_cfg.zones or {}) do
        local id = zone.config.name
        cursor:set("firewall", id, "zone")
        for k, v in pairs(zone.config) do
            cursor:set("firewall", id, k, v)
        end
        for _, fwrule in ipairs(zone.forwarding or {}) do
            local id = cursor:add("firewall", "forwarding")
            cursor:set("firewall", id, "src", zone.config.name)
            for k, v in pairs(fwrule) do
                cursor:set("firewall", id, k, v)
            end
        end
    end

    -- Firewall rules
    for _, rule in ipairs(fw_cfg.rules or {}) do
        local id = cursor:add("firewall", "rule")
        for k, v in pairs(rule.config) do
            cursor:set("firewall", id, k, v)
        end
    end

    log.info("NET: Base firewall configured")
end

local function set_network_base_config(net_cfg)
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

    log.info("NET: Base network configured")
end

local function set_mwan3_base_config(multiwan_cfg)
    log.info("NET: Applying base mwan3 config")

    -- Globals
    cursor:set("mwan3", "globals", "globals")
    cursor:set("mwan3", "globals", "mmx_mask", "0x3F00")

    -- HTTPS Rule
    cursor:set("mwan3", "https", "rule")
    cursor:set("mwan3", "https", "sticky", "1")
    cursor:set("mwan3", "https", "dest_port", "443")
    cursor:set("mwan3", "https", "proto", "tcp")
    cursor:set("mwan3", "https", "use_policy", "def_pol")

    -- Default Rule
    cursor:set("mwan3", "default_ipv4", "rule")
    cursor:set("mwan3", "default_ipv4", "dest_ip", "0.0.0.0/0")
    cursor:set("mwan3", "default_ipv4", "use_policy", "def_pol")

    -- Policy
    cursor:set("mwan3", "def_pol", "policy")
    cursor:set("mwan3", "def_pol", "last_resort", "unreachable")

    log.info("NET: Base mwan3 configured")
end

local function set_dhcp_base_config(dhcp_cfg)
    log.info("NET: Applying base dhcp config")

    -- DHCP domains
    for _, domain in ipairs(dhcp_cfg.domains or {}) do
        local id = cursor:add("dhcp", "domain")
        cursor:set("dhcp", id, "name", domain.name)
        cursor:set("dhcp", id, "ip", domain.ip)
        log.info("NET: Added static DNS", domain.name, "->", domain.ip)
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
        local devicename = cursor:add("network", "device")
        cursor:set("network", devicename, "name", "br-" .. net_id)
        cursor:set("network", devicename, "type", "bridge")
        cursor:set("network", devicename, "ports", net_cfg.interfaces or {})
    end

    cursor:set("network", net_id, "interface")
    if net_cfg.type == "local" then
        cursor:set("network", net_id, "device", "br-" .. net_id)
    elseif net_cfg.type == "backhaul" then
        cursor:set("network", net_id, "peerdns", "0")
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

    -- 4. Add MWAN3 configuration
    if net_cfg.type == 'backhaul' then
        -- first, add the interface
        cursor:set("mwan3", net_id, "interface")
        cursor:set("mwan3", net_id, "enabled", 1)
        cursor:set("mwan3", net_id, "interval", 1)
        cursor:set("mwan3", net_id, "up", 1)
        cursor:set("mwan3", net_id, "down", 2)
        cursor:set("mwan3", net_id, "family", "ipv4")
        cursor:set("mwan3", net_id, "track_ip", tracking_ips)
        cursor:set("mwan3", net_id, "initial_state", instance.online and "online" or "offline")
        -- now add the member
        local member_id = net_id .. "_member"
        cursor:set("mwan3", member_id, "member")
        cursor:set("mwan3", member_id, "interface", net_id)
        cursor:set("mwan3", member_id, "metric", instance.speed and net_cfg.multiwan.metric or 99)
        cursor:set("mwan3", member_id, "weight", instance.speed and instance.speed * 10 or 1)
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
    cursor:set("mwan3", net_id, "initial_state", instance.status == "online" and "online" or "offline")
    -- now add the member
    local member_id = net_id .. "_member"
    cursor:set("mwan3", member_id, "weight", instance.speed and round(instance.speed * 10) or 1)
    -- now add member to policy
    add_to_uci_list("mwan3", "def_pol", "use_member", member_id)
    log.debug("NET: Committing changes for: mwan3")
    cursor:commit("mwan3")
    config_applier_queue:put({ "mwan3" })
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

local function config_applier(ctx)
    log.trace("NET: Config applier starting")

    local services = {
        { service = "network",  actions = { { "/etc/init.d/network", "reload" } } },
        { service = "firewall", actions = { { "/etc/init.d/firewall", "restart" } } },
        { service = "dhcp",     actions = { { "/etc/init.d/dnsmasq", "restart" }, { "/etc/init.d/odhcpd", "restart" } } },
        { service = "mwan3",    actions = { { "/etc/init.d/mwan3", "restart" } } },
    }

    local next_deadline = sc.monotime() + 1
    local to_be_restarted = {}
    while not ctx:err() do
        op.choice(
            config_applier_queue:get_op():wrap(function(msg)
                if msg.ifup then -- this is a temporary ad-hoc special case. config application needs to move to HAL and be made more logical
                    -- Directly handle ifup here
                    local err = exec.command("ifup", msg.ifup):run()
                    if err then
                        log.warn("NET: Could not ifup", msg.ifup)
                    end
                elseif msg.shaping then
                    local net_cfg = msg.shaping
                    if net_cfg.shaping and net_cfg.interfaces then
                        log.info("NET: Applying shaping for:", net_cfg.id)

                        local err = exec.command("ifup", net_cfg.id):run()
                        if err then
                            log.warn("NET: ifup failed, retrying shaping later for:", net_cfg.id)
                            fiber.spawn(function()
                                sleep.sleep(2)
                                config_applier_queue:put(msg)
                            end)
                        else
                            shaping.apply(net_cfg)
                        end
                    end
                else
                    -- Existing logic
                    for _, v in ipairs(msg) do
                        to_be_restarted[v] = true
                    end
                end
            end),
            sleep.sleep_until_op(next_deadline):wrap(function()
                for _, v in ipairs(services) do
                    if to_be_restarted[v.service] then
                        log.info("NET:", "Restarting", v.service)
                        for i, action in ipairs(v.actions) do
                            local err = exec.command(table.unpack(action)):run()
                            if err then
                                log.warn("NET: Could not run", table.concat(action, " "))
                            else
                                log.info("NET:", v.service, "restart action", i, "completed successfully")
                            end
                        end
                    end
                end
                next_deadline = sc.monotime() + 1
                to_be_restarted = {}
            end)
        ):perform()
    end
end

local function uci_manager(ctx)
    log.trace("NET: UCI manager starting")

    local networks = {}
    local resolved_interfaces = {} -- key = modem_id or ifname, value = resolved interface string

    local function on_config(cfg)
        local start = sc.monotime()
        -- cleanup
        local areas = { "network", "firewall", "dhcp", "mwan3" }
        for _, area in ipairs(areas) do
            cursor:foreach(area, nil, function(s)
                cursor:delete(area, s[".name"])
            end)
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
            cursor:commit(area)
        end
        print("That took:", sc.monotime() - start)
        config_applier_queue:put({ "network", "firewall", "dhcp", "mwan3" })

        for _, net_cfg in ipairs(cfg.network or {}) do
            config_applier_queue:put({ shaping = net_cfg })
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
        end
        local old_status = networks[network].status
        networks[network].status = status
        if old_status ~= status then
            log.debug("NET: WAN state change", network, status)

            -- Trigger speedtest only on new connections
            if status == "online" then
                if not networks[network].speed or sc.monotime() - networks[network].speed_time > 30 then
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
            if net.cfg.modem_id == modem_id then
                net.cfg.interfaces = { iface }
                set_network_config(net)
                log.info("NET: Applied deferred network config for", net_id)
                for _, area in ipairs(areas) do
                    log.debug("NET: Committing changes for:", area)
                    cursor:commit(area)
                end
                config_applier_queue:put(areas)
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
            if net.cfg.modem_id == modem_id then
                config_applier_queue:put({ ifup = net.cfg.id })
            end
        end
    end

    ---Periodic gathering a publish of net information
    local function report_metrics(ctx)
        local function read_interface_file_numeric(id, stat_name)
            local path = "/sys/class/net/" .. id .. "/statistics/" .. stat_name
            local f = file.open(path, "r")
            if not f then return nil, "Failed to open interface file: "..path end

            f:seek(0)  -- Rewind to beginning
            local metric = tonumber(f:read_all_chars())
            f:close()
            return metric
        end

        local report_period = report_period_channel:get()
        while not ctx:err() do
            local net_metrics = {}
            for net_id, net in pairs(networks) do
                if net.cfg.interfaces ~= nil and #net.cfg.interfaces > 0 then
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
                net_service.conn:publish_multiple({'net'}, net_metrics, { retained = true })
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
    config_signal:wait() -- Block wan monitor until initial configs
    log.trace("NET: WAN monitor starting")

    -- first, we get the initial state of the interfaces, we use command line ubus for consistency with `ubus listen`
    local output, err = exec.command("ubus", "call", "mwan3", "status"):output()
    if err then
        log.error("NET: WAN monitor: could not start ubus call")
        return
    end

    local res, err = cjson.decode(output)
    if err then
        log.error("NET: WAN monitor: could not get initial state: " .. err)
        return
    end

    for network, data in pairs(res.interfaces or {}) do
        local status = data.status == "online" and "online" or "offline"
        wan_status_channel:put({ network = network, status = status })
        net_service.conn:publish(new_msg({ "net", network, "status" }, status))
    end

    -- now we start a continuous loop to monitor for changes in interface state
    local cmd = exec.command("ubus", "listen", "hotplug.mwan3")
    cmd:setprdeathsig(sc.SIGKILL) -- Ensure the process is killed on parent death
    local stdout = cmd:stdout_pipe()
    if not stdout then
        log.error("NET: could not create stdout pipe for ubus listen")
        return
    end

    local err = cmd:start()
    if err then
        log.error("NET: ubus listen failed:", err)
        return
    end

    local process_ended = false

    while not ctx:err() and not process_ended do
        op.choice(
            stdout:read_line_op():wrap(function(line)
                if not line then
                    log.error("NET: ubus listen unexpectedly exited")
                    process_ended = true
                else
                    local event, err = cjson.decode(line)
                    if err then
                        log.error("NET: ubus listen line decode failed:", err)
                        return
                    end
                    local data = event["hotplug.mwan3"]
                    log.debug("MWAN3 hotplug event received!")

                    local status = data.action == "connected" and "online" or "offline"
                    wan_status_channel:put({
                        network = data.interface,
                        status = status
                    })
                    net_service.conn:publish(new_msg({ "net", data.interface, "status" }, status))
                end
            end),
            ctx:done_op():wrap(function()
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
        local msg = speedtest_queue:get()
        local results, err = speedtest.run(ctx, msg.network, msg.interface)
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
    self.conn = conn

    -- Spawn core components
    fiber.spawn(function() config_receiver(ctx) end)
    fiber.spawn(function() interface_listener(ctx) end)
    fiber.spawn(function() uci_manager(ctx) end)
    fiber.spawn(function() wan_monitor(ctx) end)
    fiber.spawn(function() speedtest_worker(ctx) end)
    fiber.spawn(function() config_applier(ctx) end)
    fiber.spawn(function() modem_state_listener(ctx) end)
end

return net_service
