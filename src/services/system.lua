-- services/system.lua
--
-- System Service
--
-- Two long-running fibers:
--   • System Main   — config, alarm management, shutdown orchestration
--   • System Sysinfo — periodic metrics reporting via HAL capabilities
--
-- All hardware interaction is through HAL capability RPCs on the bus.
-- No direct file reads or exec calls are performed here.

local fibers  = require "fibers"
local op      = require "fibers.op"
local sleep   = require "fibers.sleep"
local channel = require "fibers.channel"

local perform = fibers.perform

local base           = require 'devicecode.service_base'
local alarms         = require "services.system.alarms"
local external_types = require "services.hal.types.external"

-- ── topic helpers ────────────────────────────────

-- local function t(...) return { ... } end
local function t_cfg(name) return { 'cfg', name } end

local function t_cap_rpc(class, id, method)
    return { 'cap', class, id, 'rpc', method }
end

local function t_obs_metric(key)
    return { 'obs', 'v1', 'system', 'metric', key }
end

local function t_svc_time_synced()
    return { 'svc', 'time', 'synced' }
end

local function t_thermal_meta()
    return { 'cap', 'thermal', '+', 'meta' }
end

local function t_platform_state_identity()
    return { 'cap', 'platform', '1', 'state', 'identity' }
end

local function t_shutdown_control()
    return { 'svc', 'system', 'shutdown' }
end

-- ── config validation ──────────────────────────────

local function validate_config(cfg)
    if type(cfg) ~= 'table' then
        return nil, "config must be a table"
    end
    if type(cfg.report_period) ~= 'number' or cfg.report_period <= 0 then
        return nil, "config.report_period must be a positive number"
    end
    if type(cfg.usb3_enabled) ~= 'boolean' then
        return nil, "config.usb3_enabled must be a boolean"
    end
    -- alarms is optional
    if cfg.alarms ~= nil and type(cfg.alarms) ~= 'table' then
        return nil, "config.alarms must be nil or a table"
    end
    return cfg, ""
end

-- ── RPC helper ─────────────────────────────────

local REQUEST_TIMEOUT = 10

local function cap_call(conn, class, id, method, payload, timeout)
    local reply, err = conn:call(
        t_cap_rpc(class, id, method),
        payload or {},
        { timeout = timeout or REQUEST_TIMEOUT }
    )
    if not reply then
        return nil, err or "rpc failed"
    end
    if reply.ok ~= true then
        return nil, reply.reason or "rpc returned not ok"
    end
    return reply.reason, ""
end

-- ── publish helpers ───────────────────────────────

local function publish_metric(conn, key, value, namespace)
    local payload = { value = value }
    if namespace then payload.namespace = namespace end
    conn:retain(t_obs_metric(key), payload)
end

-- ── sysinfo fiber ────────────────────────────────

local SYSINFO_METRICS = {
    { class = 'cpu',    id = '1', method = 'get', field = 'utilisation', metric_key = 'cpu_utilisation',
      mk_opts = external_types.new.CpuGetOpts },
    { class = 'cpu',    id = '1', method = 'get', field = 'frequency',   metric_key = 'cpu_frequency',
      mk_opts = external_types.new.CpuGetOpts },
    { class = 'memory', id = '1', method = 'get', field = 'total',       metric_key = 'mem_total',
      mk_opts = external_types.new.MemoryGetOpts },
    { class = 'memory', id = '1', method = 'get', field = 'used',        metric_key = 'mem_used',
      mk_opts = external_types.new.MemoryGetOpts },
    { class = 'memory', id = '1', method = 'get', field = 'free',        metric_key = 'mem_free',
      mk_opts = external_types.new.MemoryGetOpts },
    { class = 'memory', id = '1', method = 'get', field = 'util',        metric_key = 'mem_util',
      mk_opts = external_types.new.MemoryGetOpts },
}

-- Temperature from zone0 (preserved metric name for historical continuity).
local THERMAL_ZONE0_ID = 'zone0'

local function sysinfo_fiber(_, svc, report_period_ch)
    local conn = svc.conn
    svc:obs_log('debug', 'sysinfo started')

    fibers.current_scope():finally(function()
        local _, primary = fibers.current_scope():status()
        svc:obs_log('debug', { what = 'sysinfo_stopped', reason = tostring(primary or 'ok') })
    end)

    -- Subscribe to time sync and thermal meta before blocking on config.
    local time_sub    = conn:subscribe(t_svc_time_synced())
    local thermal_sub = conn:subscribe(t_thermal_meta())

    -- Block until System Main sends us the initial report_period.
    local report_period = report_period_ch:get()
    if not report_period then
        svc:obs_log('warn', 'sysinfo: report_period channel closed before config received')
        return
    end
    svc:obs_log('debug', { what = 'report_period_set', value = report_period })

    -- Read platform retained state once at startup.
    local identity_sub = conn:subscribe(t_platform_state_identity())
    local identity_msg = perform(op.choice(
        identity_sub:recv_op(),
        sleep.sleep_op(REQUEST_TIMEOUT)
    ))
    if identity_msg and type(identity_msg.payload) == 'table' then
        local id = identity_msg.payload
        local static_fields = { 'hw_revision', 'fw_version', 'serial', 'board_revision' }
        for _, field in ipairs(static_fields) do
            if id[field] ~= nil then
                publish_metric(conn, field, id[field])
            end
        end
        svc:obs_log('debug', 'sysinfo: published platform identity metrics')
    else
        svc:obs_log('warn', 'sysinfo: platform identity not available within timeout')
    end

    local time_synced = false
    local zone0_present = false

    while true do
        local which, msg = perform(op.named_choice {
            sleep   = sleep.sleep_op(report_period),
            period  = report_period_ch:get_op(),
            time    = time_sub:recv_op(),
            thermal = thermal_sub:recv_op(),
        })

        if which == 'period' then
            if msg then
                report_period = msg
                svc:obs_log('debug', { what = 'report_period_updated', value = report_period })
            else
                svc:obs_log('debug', 'sysinfo: report_period channel closed')
                return
            end
        elseif which == 'time' then
            if not msg then
                svc:obs_log('debug', 'sysinfo: time subscription closed')
                return
            end
            time_synced = (msg.payload == true)
            svc:obs_log('debug', { what = 'time_synced_updated', value = time_synced })
        elseif which == 'thermal' then
            if msg then
                local zone_id = msg.topic and msg.topic[3]
                if zone_id == THERMAL_ZONE0_ID then
                    zone0_present = true
                    svc:obs_log('debug', 'sysinfo: thermal zone0 discovered')
                end
            end
        elseif which == 'sleep' then
            -- ── collect and publish metrics ───────────────────────

            for _, m in ipairs(SYSINFO_METRICS) do
                local opts, opts_err = m.mk_opts(m.field, report_period)
                if opts_err ~= "" then
                    svc:obs_log('warn', { what = 'metric_opts_invalid', class = m.class,
                        id = m.id, field = m.field, err = opts_err })
                else
                    local value, err = cap_call(conn, m.class, m.id, m.method, opts)
                    if err ~= "" then
                        svc:obs_log('warn', { what = 'metric_get_failed', class = m.class,
                            id = m.id, field = m.field, err = err })
                    else
                        publish_metric(conn, m.metric_key, value)
                    end
                end
            end

            -- boot_time: derived from platform uptime, only published when NTP-synced.
            if time_synced then
                local uptime_opts, uptime_opts_err = external_types.new.PlatformGetOpts('uptime', report_period)
                if uptime_opts_err ~= "" then
                    svc:obs_log('warn', { what = 'uptime_opts_invalid', err = uptime_opts_err })
                else
                    local uptime, uptime_err = cap_call(conn, 'platform', '1', 'get', uptime_opts)
                    if uptime == nil or uptime_err ~= "" then
                        svc:obs_log('warn', { what = 'uptime_get_failed', err = uptime_err })
                    else
                        publish_metric(conn, 'boot_time', os.time() - math.floor(uptime))
                    end
                end
            end

            -- temperature from zone0.
            if zone0_present then
                local thermal_opts, thermal_opts_err = external_types.new.ThermalGetOpts(report_period)
                if thermal_opts_err ~= "" then
                    svc:obs_log('warn', { what = 'thermal_opts_invalid', err = thermal_opts_err })
                else
                    local temp, terr = cap_call(conn, 'thermal', THERMAL_ZONE0_ID, 'get', thermal_opts)
                    if terr ~= "" then
                        svc:obs_log('warn', { what = 'thermal_get_failed', err = terr })
                    else
                        publish_metric(conn, 'temperature', temp)
                    end
                end
            end
        end
    end
end

-- ── shutdown orchestration ─────────────────────────────

local SHUTDOWN_GRACE = 10 -- seconds services have to shut down
local USB3_MODEL     = "bigbox-ss" -- only model with controllable USB3 hardware

local function handle_alarm(svc, alarm)
    local conn       = svc.conn
    local payload    = alarm.payload or {}
    local alarm_name = payload.name or "scheduled alarm"
    local alarm_type = payload.type or "reboot"

    svc:obs_log('info', { what = 'alarm_fired', name = alarm_name, type = alarm_type })
    svc:obs_event('alarm_fired', { name = alarm_name, type = alarm_type, ts = svc:now() })

    -- Broadcast shutdown signal so all services can clean up within the deadline.
    conn:retain(t_shutdown_control(), {
        reason   = alarm_name,
        deadline = fibers.now() + SHUTDOWN_GRACE,
    })

    -- After the grace period, issue the power command via the bus.
    local ok, spawn_err = fibers.current_scope():spawn(function()
        perform(sleep.sleep_op(SHUTDOWN_GRACE))
        svc:obs_log('info', { what = 'power_command', type = alarm_type })
        local power_opts = external_types.new.PowerActionOpts()
        local _, err = cap_call(conn, 'power', '1', alarm_type, power_opts)
        if err ~= "" then
            svc:obs_log('error', { what = 'power_command_failed', type = alarm_type, err = err })
        end
    end)
    if not ok then
        svc:obs_log('error', { what = 'power_fiber_spawn_failed', err = tostring(spawn_err) })
    end
end

-- ── system main fiber ──────────────────────────────

local function system_main(svc, report_period_ch)
    local conn = svc.conn
    svc:obs_log('debug', 'main started')

    local parent_scope = fibers.current_scope()
    parent_scope:finally(function()
        local _, primary = parent_scope:status()
        svc:obs_log('debug', { what = 'main_stopped', reason = tostring(primary or 'ok') })
        svc:status('stopped', { reason = tostring(primary or 'ok') })
    end)

    local alarm_mgr = alarms.AlarmManager.new()

    -- Read the hardware model before entering the main loop.
    -- USB3 control is only safe on bigbox-ss hardware.
    local hw_revision = nil
    do
        local id_sub = conn:subscribe(t_platform_state_identity())
        local id_msg = perform(op.choice(
            id_sub:recv_op(),
            sleep.sleep_op(REQUEST_TIMEOUT)
        ))
        if id_msg and type(id_msg.payload) == 'table' and id_msg.payload.hw_revision then
            hw_revision = id_msg.payload.hw_revision:match('(%S+)')
            svc:obs_log('debug', { what = 'hw_revision_detected', value = hw_revision })
        else
            svc:obs_log('warn', 'platform identity not available at startup; USB3 control disabled')
        end
    end

    local cfg_sub  = conn:subscribe(t_cfg(svc.name))
    local time_sub = conn:subscribe(t_svc_time_synced())

    while true do
        local choices = {
            cfg   = cfg_sub:recv_op(),
            time  = time_sub:recv_op(),
            alarm = alarm_mgr:next_alarm_op(),
        }

        local which, msg = perform(op.named_choice(choices))

        if not msg and (which == 'cfg' or which == 'time') then
            svc:obs_log('debug', { what = 'subscription_closed', source = which })
            return
        end

        if which == 'cfg' then
            local cfg, err = validate_config(msg.payload)
            if cfg == nil or err ~= "" then
                svc:obs_log('warn', { what = 'config_invalid', err = err })
            else
                svc:obs_event('config_applied', { ts = svc:now() })

                -- Forward report_period to sysinfo fiber.
                -- Drain any stale unconsumed value first (non-blocking via or_else so
                -- the channel is tried first), then put the latest value.
                perform(report_period_ch:get_op():or_else(function() return nil end))
                report_period_ch:put(cfg.report_period)

                -- Handle USB3 control (bigbox-ss hardware only).
                if hw_revision == USB3_MODEL then
                    local usb_verb = cfg.usb3_enabled and 'enable' or 'disable'
                    local _, usb_err = cap_call(conn, 'usb', 'usb3', usb_verb)
                    if usb_err ~= "" then
                        svc:obs_log('warn', { what = 'usb3_control_failed', verb = usb_verb, err = usb_err })
                    end
                end

                -- Reload alarms.
                alarm_mgr:delete_all()
                if type(cfg.alarms) == 'table' then
                    for _, alarm_cfg in ipairs(cfg.alarms) do
                        local add_err = alarm_mgr:add(alarm_cfg)
                        if add_err ~= "" then
                            svc:obs_log('warn', { what = 'alarm_add_failed', err = add_err })
                        end
                    end
                end
            end
        elseif which == 'time' then
            local is_synced = (msg.payload == true)
            if is_synced then
                alarm_mgr:sync()
                svc:obs_log('debug', 'alarm manager synced')
            else
                alarm_mgr:desync()
                svc:obs_log('debug', 'alarm manager desynced')
            end
        elseif which == 'alarm' then
            handle_alarm(svc, msg)
        end
    end
end

-- ── service entry point ──────────────────────────────

local SystemService = {}

---@param conn Connection
---@param opts table?
function SystemService.start(conn, opts)
    opts = opts or {}

    local svc = base.new(conn, { name = opts.name or 'system', env = opts.env })
    local heartbeat_s = (type(opts.heartbeat_s) == 'number') and opts.heartbeat_s or 30.0

    svc:obs_state('boot', { at = svc:wall(), ts = svc:now(), state = 'entered' })
    svc:obs_log('info', 'service start() entered')
    svc:status('starting')
    svc:spawn_heartbeat(heartbeat_s, 'tick')

    -- Channel carries report_period from System Main → System Sysinfo.
    -- Buffer of 1 so a rapid double-update does not block Main.
    local report_period_ch = channel.new(1)

    fibers.current_scope():finally(function()
        local _, primary = fibers.current_scope():status()
        svc:status('stopped', { reason = tostring(primary or 'ok') })
        svc:obs_log('info', 'service stopped')
    end)

    -- Spawn Sysinfo first so it is ready to receive from report_period_ch.
    fibers.current_scope():spawn(sysinfo_fiber, svc, report_period_ch)

    svc:status('running')
    svc:obs_log('info', 'service running')

    -- Run System Main in the calling fiber.
    system_main(svc, report_period_ch)
end

return SystemService
