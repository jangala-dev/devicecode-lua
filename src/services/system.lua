local service = require "service"
local log = require "services.log"
local op = require "fibers.op"
local sleep = require "fibers.sleep"
local channel = require "fibers.channel"
local context = require "fibers.context"
local exec = require "fibers.exec"
local new_msg = require("bus").new_msg
local sysinfo = require "services.hal.sysinfo"
local usb3 = require "services.hal.usb3"
local alarms = require "services.system.alarms"
local sc = require "fibers.utils.syscall"

local system_service = {
    name = 'System'
}
system_service.__index = system_service

local function get_boot_time(_)
    local uptime, err = sysinfo.get_uptime()
    if err then
        return nil, err
    end
    return math.floor(os.time() - uptime)
end

local function get_mem_stats(_)
    local stats, err = sysinfo.get_ram_info()
    if err then
        return nil, err
    end
    return {
        total = stats.total,
        used = stats.used,
        free = stats.free,
        util = (stats.used / stats.total) * 100
    }
end

local METRICS = {
    -- static metrics
    { method = sysinfo.get_hw_revision, key = { 'hardware', 'revision' } },
    { method = sysinfo.get_fw_version, key = { 'firmware', 'version' } },
    -- Boot time should not be retrieved until time is synced
    { method = get_boot_time, key = { 'boot_time' }, needs_time_sync = true },
    { method = sysinfo.get_board_revision, key = { 'hardware', 'board', 'revision' } },
    { method = sysinfo.get_serial, key = { 'hardware', 'serial' } },
    -- dynamic metrics
    { method = sysinfo.get_cpu_model, key = { 'cpu', 'cpu_model' } },
    { method = sysinfo.get_cpu_utilisation_and_freq, key = { 'cpu' } },
    { method = get_mem_stats, key = { 'mem' } },
    { method = sysinfo.get_temperature, key = { 'temperature' } },
}

---Configure USB hub and alarms
---@param config_msg table
function system_service:_handle_config(ctx, config_msg)
    if config_msg.payload == nil then
        log.error("System: Invalid configuration message")
        return
    end
    local usb3_enabled = config_msg.payload.usb3_enabled
    local report_period = config_msg.payload.report_period

    if usb3_enabled == nil or report_period == nil then
        log.error("System: Missing required configuration fields")
        return
    end

    self.report_period_channel:put(report_period)

    if not usb3_enabled then
        -- this is just a copy-paste job, look at this again during mvp
        -- and think about abstraction and renablement(?) etc
        log.info(string.format("%s - %s: Disabling USB3",
            ctx:value("service_name"),
            ctx:value("fiber_name")
        ))
        usb3.disable_usb3(ctx, self.model)
    end

    local cfg_alarms = config_msg.payload.alarms
    if cfg_alarms and type(cfg_alarms) == "table" then
        self.alarm_manager:delete_all()
        for _, alarm in ipairs(cfg_alarms) do
            local add_err = self.alarm_manager:add(alarm)
            if add_err then
                log.error("Failed to add alarm: ", add_err)
            end
        end
    end
end

local function build_table(keys, values)
    local tbl = {}
    local head = tbl
    for i = 1, #keys-1 do
        head[keys[i]] = {}
        head = head[keys[i]]
    end
    head[keys[#keys]] = values
    return tbl
end

local function merge_tables(primary, secondary)
    for k, v in pairs(secondary) do
        if type(v) == "table" and type(primary[k]) == "table" then
            merge_tables(primary[k], v)
        else
            primary[k] = v
        end
    end
end

---Periodic gathering a publish of system information
function system_service:_report_sysinfo(ctx)
    local time_synced_sub = self.conn:subscribe({ 'time', 'ntp_synced' })
    local time_synced = false
    local hw_revision = sysinfo.get_hw_revision()
    if hw_revision then
        self.model = hw_revision:match('(%S+)') -- this should be put on a channel
    end

    local report_period = self.report_period_channel:get()
    while not ctx:err() do
        local stats = {}
        for _, metric in ipairs(METRICS) do
            if (metric.needs_time_sync and time_synced) or (not metric.needs_time_sync) then
                local result, err
                if metric.method then
                    result, err = metric.method(ctx)
                else
                    err = "No method defined for metric"
                end
                if err then
                    log.error(string.format("System: Failed to get metric for %s: %s",
                        table.concat(metric.key, '.'), err))
                else
                    local keyed_table = build_table(metric.key, result)
                    merge_tables(stats, keyed_table)
                end
            end
        end

        self.conn:publish_multiple(
            { 'system', 'info' },
            stats,
            { retained = true }
        )

        op.choice(
            sleep.sleep_op(report_period),
            self.report_period_channel:get_op():wrap(function(new_period)
                report_period = new_period
            end),
            time_synced_sub:next_msg_op():wrap(function(msg)
                time_synced = (msg.payload == true)
            end),
            ctx:done_op()
        ):perform()
    end
end

---Performs shutdown or reboot of the system
---@param alarm Alarm
function system_service:_handle_alarm(ctx, alarm)
    local name = alarm.payload and alarm.payload.name
    local type = alarm.payload and alarm.payload.type
    if type ~= 'reboot' and type ~= 'shutdown' then return end
    local deadline = sc.monotime() + 10
    self.conn:publish(new_msg(
        { '+', 'control', 'shutdown' },
        { reason = name, deadline = deadline },
        { retained = true }
    ))

    -- need to create context that is independent from the service context
    -- as the broadcast shutdown message will also shutdown the system service
    local shutdown_timeout = context.with_deadline(context.background(), deadline + 1)
    local shutdown_sub = self.conn:subscribe({ '+', 'health' })

    local active_services = {}

    while not shutdown_timeout:err() do
        local msg, timeout_err = shutdown_sub:next_msg_with_context_op(shutdown_timeout):perform()
        if timeout_err then break end
        local service_name = msg.topic[1]
        if service_name ~= self.name then
            if msg.payload.state == 'disabled' and active_services[service_name] then
                active_services[service_name] = nil
            end
            if msg.payload.state ~= 'disabled' and not active_services[service_name] then
                active_services[service_name] = true
            end
        end
    end
    shutdown_sub:unsubscribe()

    for service_name, _ in pairs(active_services) do
        local err_msg = string.format("Service %s did not shut down safely due to hanging fibers:\n", service_name)
        local service_fibers_status_sub = self.conn:subscribe(
            { service_name, 'health', 'fibers', '+' }
        )
        while true do
            local msg, is_break = service_fibers_status_sub:next_msg_op():perform_alt(function()
                return nil, true
            end)
            if is_break then break end
            if msg.payload.state ~= 'disabled' then
                err_msg = err_msg .. string.format("\tFiber %s is stuck in state %s\n", msg.topic[4], msg.payload.state)
            end
        end
        service_fibers_status_sub:unsubscribe()
        log.debug(err_msg)
    end

    if type == 'shutdown' then
        log.info(string.format("%s - %s: Shutting down system",
            ctx:value("service_name"),
            ctx:value("fiber_name")
        ))
        local cmd = exec.command('shutdown', '-h', 'now')
        cmd:run()
    elseif type == 'reboot' then
        log.info(string.format("%s - %s: Rebooting system",
            ctx:value("service_name"),
            ctx:value("fiber_name")
        ))
        local cmd = exec.command('reboot')
        cmd:run()
    end
end

--- Main system service loop
function system_service:_system_main(ctx)
    -- Subscribe to system-related topics
    local config_sub = self.conn:subscribe({ 'config', 'system' })
    local time_sync_sub = self.conn:subscribe({ 'time', 'ntp_synced' })

    while not ctx:err() do
        op.choice(
            ctx:done_op(),
            config_sub:next_msg_op():wrap(function(config_msg)
                self:_handle_config(ctx, config_msg)
            end),
            time_sync_sub:next_msg_op():wrap(function(msg)
                if msg.payload then
                    self.alarm_manager:sync()
                else
                    self.alarm_manager:desync()
                end
            end),
            self.alarm_manager:next_alarm_op():wrap(function(alarm)
                self:_handle_alarm(ctx, alarm)
            end)
        ):perform()
    end
    config_sub:unsubscribe()
    time_sync_sub:unsubscribe()
end

---Start the system service
---@param ctx Context
---@param conn Connection
function system_service:start(ctx, conn)
    self.conn = conn
    self.report_period_channel = channel.new()
    self.alarm_manager = alarms.AlarmManager.new()
    log.trace("Starting System Service")
    service.spawn_fiber('System Main', conn, ctx, function(fctx)
        self:_system_main(fctx)
    end)
    service.spawn_fiber('System Sysinfo', conn, ctx, function(fctx)
        self:_report_sysinfo(fctx)
    end)
end

if _G._TEST then
    return {
        system_service = system_service,
        build_table = build_table,
        merge_tables = merge_tables
    }
else
    return system_service
end
