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

---Configure USB hub and alarms
---@param config_msg table
function system_service:_handle_config(config_msg)
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
            self.ctx:value("service_name"),
            self.ctx:value("fiber_name")
        ))
        usb3.disable_usb3(self.ctx, self.model)
    end

    local alarms = config_msg.payload.alarms
    if alarms and type(alarms) == "table" then
        self.alarm_manager:delete_all()
        for _, alarm in ipairs(alarms) do
            local add_err = self.alarm_manager:add(alarm)
            if add_err then
                log.error("Failed to add alarm: ", add_err)
            end
        end
    end
end

---Periodic gathering a publish of system information
function system_service:_report_sysinfo()
    local report_period = self.report_period_channel:get()
    while not self.ctx:err() do
        local cpu_model, cpu_model_err = sysinfo.get_cpu_model()
        if cpu_model_err then
            log.debug("Failed to get CPU model: ", cpu_model_err)
        end

        local all_util, core_util, avg_freq, core_freq, err = sysinfo.get_cpu_utilisation_and_freq(self.ctx)
        if err then
            log.debug("Failed to get CPU utilisation and frequency: ", err)
        end

        local total, used, free, ram_err = sysinfo.get_ram_info()
        if ram_err then
            log.debug("Failed to get RAM info: ", ram_err)
        end

        local temperature, temp_err = sysinfo.get_temperature()
        if temp_err then
            log.debug("Failed to get temperature: ", temp_err)
        end

        local sysinfo_data = {
            cpu = {
                cpu_model = cpu_model,
                overall_utilisation = all_util,
                core_utilisations = core_util,
                average_frequency = avg_freq,
                core_frequencies = core_freq
            },
            mem = {
                total = total,
                used = used,
                free = free,
                util = (used / total) * 100
            },
            temperature = temperature,
            heartbeat = 0
        }

        self.conn:publish_multiple(
            { 'system', 'info' },
            sysinfo_data,
            { retained = true }
        )

        op.choice(
            sleep.sleep_op(report_period),
            self.report_period_channel:get_op():wrap(function(new_period)
                report_period = new_period
            end),
            self.ctx:done_op()
        ):perform()
    end
end

---Performs shutdown or reboot of the system
---@param alarm Alarm
function system_service:_handle_alarm(alarm)
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
            self.ctx:value("service_name"),
            self.ctx:value("fiber_name")
        ))
        local cmd = exec.command('shutdown', '-h', 'now')
        cmd:run()
    elseif type == 'reboot' then
        log.info(string.format("%s - %s: Rebooting system",
            self.ctx:value("service_name"),
            self.ctx:value("fiber_name")
        ))
        local cmd = exec.command('reboot')
        cmd:run()
    end
end

---Gets static information (hw model, hw/fw version, boot time)
---@return table?
local function get_static_infos()
    local info = {}
    local hw_revision, hw_err = sysinfo.get_hw_revision()
    if hw_err then
        log.error(string.format("System: Failed to get model and version: %s", hw_err))
    else
        info.hardware = {
            revision = hw_revision
        }
    end

    local firmware_version, fw_err = sysinfo.get_fw_version()
    if fw_err then
        log.error(string.format("System: Failed to get firmware version: %s", fw_err))
    else
        info.firmware = {
            version = firmware_version
        }
    end

    local uptime, uptime_err = sysinfo.get_uptime()
    local boot_time
    if uptime_err then
        log.error("Failed to get uptime: ", uptime_err)
    else
        boot_time = math.floor(os.time() - uptime)
        info.boot_time = boot_time
    end

    local board_revision, revision_err = sysinfo.get_board_revision()
    if revision_err then
        log.error("Failed to get board revision: ", revision_err)
    else
        info.hardware = info.hardware or {}
        info.hardware.board = {revision = board_revision}
    end

    local serial, serial_err = sysinfo.get_serial()
    if serial_err then
        log.debug("Failed to get serial number: ", serial_err)
    else
        info.hardware = info.hardware or {}
        info.hardware.serial = serial
    end

    if next(info) then
        return info
    else
        log.error("System: No static information available")
        return nil
    end
end

--- Main system service loop
function system_service:_system_main()
    -- Subscribe to system-related topics
    local config_sub = self.conn:subscribe({ 'config', 'system' })
    local time_sync_sub = self.conn:subscribe({ 'time', 'ntp_synced' })

    local static_info = get_static_infos()
    if static_info then
        if static_info.hardware and static_info.hardware.revision then
            -- Extract model and version from hw revision
            local hw_revision = static_info.hardware.revision
            local model, version = hw_revision:match('(%S+)%s+(%S+)')
            self.model = model
        end
        self.conn:publish_multiple(
            { 'system', 'info' },
            static_info,
            { retained = true }
        )
    end

    while not self.ctx:err() do
        op.choice(
            self.ctx:done_op(),
            config_sub:next_msg_op():wrap(function(config_msg)
                self:_handle_config(config_msg)
            end),
            time_sync_sub:next_msg_op():wrap(function(msg)
                if msg.payload then
                    self.alarm_manager:sync()
                else
                    self.alarm_manager:desync()
                end
            end),
            self.alarm_manager:next_alarm_op():wrap(function(alarm)
                self:_handle_alarm(alarm)
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
    self.ctx = ctx
    self.conn = conn
    self.report_period_channel = channel.new()
    self.alarm_manager = alarms.AlarmManager.new()
    log.trace("Starting System Service")
    service.spawn_fiber('System Main', conn, ctx, function()
        self:_system_main()
    end)
    service.spawn_fiber('System Sysinfo', conn, ctx, function()
        self:_report_sysinfo()
    end)
end

return system_service
