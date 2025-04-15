local service = require "service"
local log = require "log"
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
    name = 'system'
}
system_service.__index = system_service

---Turn off the USB3 hub and move peripherals to USB2
---@param ctx Context
---@param model string?
local function disable_usb3(ctx, model)
    if model ~= "bigbox-ss" then return end
    -- VL805 (usb hub controller) firmware needs to be past a certain version
    -- version was added 2019-09-10 so let's check our version is 2019-09-10 or later
    local vl805_supported_from = os.time({ year = 2019, month = 09, day = 10, hour = 0, min = 0, sec = 0 })
    local vl805_timestamp, err = usb3.get_vl805_version_timestamp(ctx)
    if err ~= nil or vl805_timestamp < vl805_supported_from then
        err = err or ""
        log.warn(string.format(
            "System: VL805 firmware version is %s, expected version >= %s %s",
            vl805_timestamp,
            vl805_supported_from,
            err
        ))
        return
    end
    -- deactivating any current usb 3.0 connections via deauthorisation
    local usb_3_0_used, err = usb3.clear_usb_3_0_hub(ctx)
    if err ~= nil then
        -- need to reauth devices just in case
        log.error(string.format("System: Error clearing usb 3.0 hub, attempting repopulation, %s", err))
        _, err = usb3.repopulate_usb_3_0_hub(ctx)
        if err ~= nil then
            log.error(string.format("System: Error reactivating usb 3.0 connections, %s", err))
        end
        err = usb3.set_usb_hub_auth_default(ctx, true, 2)
        if err ~= nil then
            log.error(string.format("System: Error default-reauthorising usb 3.0 connections, %s", err))
        end
        return
    elseif not usb_3_0_used then
        -- no need to make any changes
        log.info("System: NO_USB3")
        return
    end
    -- default deauthorising usb 3.0 hub, prevents future connections
    err = usb3.set_usb_hub_auth_default(ctx, false, 2)
    if err ~= nil then
        log.warn(string.format("System: Error default-deauthorising usb 3.0 connections, %s", err))
    end
    -- powering down usb 3.0 hub to initiate usb 2.0 connections
    err = usb3.set_usb_hub_power(ctx, false, 2)
    if err ~= nil then
        -- need to try power up the hub just in case, and reauth devices
        log.error(string.format("System: Error powering down usb 3.0 hub, attempting power up, %s", err))
        err = usb3.set_usb_hub_power(ctx, true, 2)
        if err ~= nil then
            log.error("System: Error powering up usb 3.0 hub, attempting repopulation, %s", err)
        end
        _, err = usb3.repopulate_usb_3_0_hub(ctx)
        if err ~= nil then
            log.error(string.format("System: Error reactivating usb 3.0 connections, %s", err))
        end
        err = usb3.set_usb_hub_auth_default(ctx, true, 2)
        if err ~= nil then log.warn(string.format("System: Error default-reauthorising usb 3.0 connections, %s", err)) end
        return
    end
    -- waiting to see any usb 3.0 devices detected on usb 2.0 before moving on
    local detection_retries = 10
    local awaiting_port_1, err = usb3.is_device_on_hub_port(2, 1)
    if err ~= nil then log.warn(string.format("System: Error detecting device on usb 3.0 hub port: %s ", err)) end
    local awaiting_port_2, err = usb3.is_device_on_hub_port(2, 2)
    if err ~= nil then log.warn(string.format("System: Error detecting device on usb 3.0 hub port: %s", err)) end
    for _ = 1, detection_retries do
        local port_1_ready = not (awaiting_port_1 and not usb3.is_device_on_hub_port(1, 1))
        local port_2_ready = not (awaiting_port_2 and not usb3.is_device_on_hub_port(1, 2))
        if port_1_ready and port_2_ready then return else sleep.sleep(1) end
    end
    log.warn(string.format("System: Deactivated usb 3.0 devices not detected on usb 2.0 hub ports, may be unstable"))
end

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
        disable_usb3(self.ctx, self.model)
    end

    local alarms = config_msg.payload.alarms
    if alarms then
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
                free = free
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
    log.info("SHUTTING DOWN", name, type)
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
        local cmd = exec.command('shutdown', '-h', 'now')
        cmd:run()
    elseif type == 'reboot' then
        local cmd = exec.command('reboot')
        cmd:run()
    end
    os.exit()
end

---Gets static information (hw model, hw/fw version, boot time)
---@return table?
local function get_static_infos()
    local model, version, hw_err = sysinfo.get_hw_revision()
    if hw_err then
        log.error(string.format("System: Failed to get model and version: %s", hw_err))
    end

    local firmware_version, fw_err = sysinfo.get_fw_version()
    if fw_err then
        log.error(string.format("System: Failed to get firmware version: %s", fw_err))
    end

    local uptime, uptime_err = sysinfo.get_uptime()
    local boot_time
    if uptime_err then
        log.error("Failed to get uptime: ", uptime_err)
    else
        boot_time = math.floor(os.time() - uptime)
    end
    -- only need to publish if some info was retrieved
    if not (hw_err and fw_err and uptime_err) then
        local system_data = {
            device = {
                model = model,
                version = version
            },
            firmware = {
                version = firmware_version
            },
            boot_time = boot_time
        }
        return system_data
    end
    return nil
end

--- Main system service loop
function system_service:_system_main()
    -- Subscribe to system-related topics
    local config_sub = self.conn:subscribe({ 'config', 'system' })

    local static_info = get_static_infos()
    self.model = static_info.device.model
    if static_info then
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
            self.alarm_manager:next_alarm_op():wrap(function(alarm)
                self:_handle_alarm(alarm)
            end)
        ):perform()
    end
    config_sub:unsubscribe()
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
