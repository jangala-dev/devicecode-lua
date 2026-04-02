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

local fibers         = require "fibers"
local op             = require "fibers.op"
local sleep          = require "fibers.sleep"
local channel        = require "fibers.channel"

local perform        = fibers.perform

local base           = require 'devicecode.service_base'
local cap_sdk        = require 'services.hal.sdk.cap'
local alarms         = require "services.system.alarms"

local SCHEMA_TARGET  = "devicecode.config/system/1"

-- ── topic helpers ────────────────────────────────

---@param name string
---@return Topic
local function t_cfg(name) return { 'cfg', name } end

---@param key string
---@return Topic
local function t_obs_metric(key)
    return { 'obs', 'v1', 'system', 'metric', key }
end

---@return Topic
local function t_svc_time_synced()
    return { 'svc', 'time', 'synced' }
end

---@return Topic
local function t_shutdown_control()
    return { 'svc', 'system', 'shutdown' }
end

-- ── config validation ──────────────────────────────

---@param cfg any
---@return { report_period: number, usb3_enabled: boolean, alarms?: table }?
---@return string error
local function validate_config(cfg)
    if type(cfg) ~= 'table' then
        return nil, "config must be a table"
    end
    if cfg.schema ~= SCHEMA_TARGET then
        return nil, "config.schema is not currently supported"
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

---@param cap_ref CapabilityReference
---@param method string
---@param opts any
---@param timeout? number
---@return any value
---@return string error
local function cap_rpc(cap_ref, method, opts, timeout)
    timeout = timeout or REQUEST_TIMEOUT
    local reply, err = perform(cap_ref:call_control_op(method, opts, { timeout = timeout }))
    if not reply then return nil, err or "rpc failed" end
    if reply.ok ~= true then return nil, reply.reason or "rpc returned not ok" end
    return reply.reason, ""
end

---@param class CapabilityClass
---@param id CapabilityId
---@return string
local function cap_ref_key(class, id)
    return tostring(class) .. ':' .. tostring(id)
end

---@param conn Connection
---@param svc ServiceBase
---@param class CapabilityClass
---@param id CapabilityId
---@return CapabilityReference?
---@return string error
local function wait_for_cap(conn, svc, class, id)
    local cap_ref, cap_err = cap_sdk.new_cap_listener(conn, class, id):wait_for_cap({
        timeout = REQUEST_TIMEOUT,
    })
    if not cap_ref then
        svc:obs_log('warn', {
            what = 'cap_unavailable',
            class = class,
            id = id,
            err = cap_err,
        })
        return nil, cap_err
    end
    return cap_ref, ""
end

---@param conn Connection
---@param svc ServiceBase
---@param specs { class: CapabilityClass, id: CapabilityId }[]
---@return table<string, CapabilityReference>
local function discover_caps(conn, svc, specs)
    local refs = {}
    local seen = {}

    for _, spec in ipairs(specs) do
        local key = cap_ref_key(spec.class, spec.id)
        if not seen[key] then
            local cap_ref = wait_for_cap(conn, svc, spec.class, spec.id)
            if cap_ref then
                refs[key] = cap_ref
            end
            seen[key] = true
        end
    end

    return refs
end

---@param refs table<string, CapabilityReference>
---@param class CapabilityClass
---@param id CapabilityId
---@return CapabilityReference?
local function get_cap_ref(refs, class, id)
    return refs[cap_ref_key(class, id)]
end

-- ── publish helpers ───────────────────────────────

---@param conn Connection
---@param key string
---@param value number|string
---@param namespace? string
local function publish_metric(conn, key, value, namespace)
    local payload = { value = value }
    if namespace then payload.namespace = namespace end
    conn:retain(t_obs_metric(key), payload)
end

-- ── sysinfo fiber ────────────────────────────────

-- Temperature from zone0 (preserved metric name for historical continuity).
local THERMAL_ZONE0_ID = 'zone0'


local SYSINFO_METRICS = {
    {
        class = 'cpu',
        id = '1',
        method = 'get',
        field = 'utilisation',
        metric_key = 'cpu_util',
        mk_opts = cap_sdk.args.new.CpuGetOpts
    },
    {
        class = 'cpu',
        id = '1',
        method = 'get',
        field = 'frequency',
        metric_key = 'cpu_frequency',
        mk_opts = cap_sdk.args.new.CpuGetOpts
    },
    {
        class = 'memory',
        id = '1',
        method = 'get',
        field = 'util',
        metric_key = 'mem_util',
        mk_opts = cap_sdk.args.new.MemoryGetOpts
    },
    {
        class = 'thermal',
        id = THERMAL_ZONE0_ID,
        method = 'get',
        field = '',
        metric_key = 'temp',
        mk_opts = function (_, max_age) return cap_sdk.args.new.ThermalGetOpts(max_age) end
    }
}

---@param _ Scope
---@param svc ServiceBase
---@param report_period_ch Channel
local function sysinfo_fiber(_, svc, report_period_ch)
    local conn = svc.conn
    svc:obs_log('debug', 'sysinfo started')

    fibers.current_scope():finally(function()
        local _, primary = fibers.current_scope():status()
        svc:obs_log('debug', { what = 'sysinfo_stopped', reason = tostring(primary or 'ok') })
    end)

    local cap_specs = {
        { class = 'platform', id = '1' },
    }
    for _, metric in ipairs(SYSINFO_METRICS) do
        cap_specs[#cap_specs + 1] = { class = metric.class, id = metric.id }
    end

    local cap_refs = discover_caps(conn, svc, cap_specs)
    local platform_cap = get_cap_ref(cap_refs, 'platform', '1')

    -- Block until System Main sends us the initial report_period.
    local report_period = report_period_ch:get()
    if not report_period then
        svc:obs_log('warn', 'sysinfo: report_period channel closed before config received')
        return
    end
    svc:obs_log('debug', { what = 'report_period_set', value = report_period })

    -- Read platform retained identity once at startup and publish static metrics.
    if platform_cap then
        local identity_sub = platform_cap:get_state_sub('identity')
        local identity_msg = perform(op.choice(
            identity_sub:recv_op(),
            sleep.sleep_op(REQUEST_TIMEOUT)
        ))
        if identity_msg and type(identity_msg.payload) == 'table' then
            local id = identity_msg.payload
            for _, field in ipairs({ 'hw_revision', 'fw_version', 'serial', 'board_revision' }) do
                if id[field] ~= nil then publish_metric(conn, field, id[field]) end
            end
            svc:obs_log('debug', 'sysinfo: published platform identity metrics')
        else
            svc:obs_log('warn', 'sysinfo: platform identity not available within timeout')
        end
    end

    -- Subscribe to time sync.
    local time_sub = conn:subscribe(t_svc_time_synced())

    local time_synced = false

    while true do
        local choices = {
            sleep  = sleep.sleep_op(report_period),
            period = report_period_ch:get_op(),
            time   = time_sub:recv_op(),
            -- time = time_synced and op.never() or op.always( { payload = true } )
        }

        local which, msg = perform(op.named_choice(choices))

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
        elseif which == 'sleep' then
            -- ── collect and publish metrics ───────────────────────

            for _, m in ipairs(SYSINFO_METRICS) do
                local cap_ref = get_cap_ref(cap_refs, m.class, m.id)
                if cap_ref then
                    local opts, opts_err = m.mk_opts(m.field, report_period)
                    if opts_err ~= "" then
                        svc:obs_log('warn', {
                            what = 'metric_opts_invalid',
                            class = m.class,
                            id = m.id,
                            field = m.field,
                            err = opts_err
                        })
                    else
                        local value, err = cap_rpc(cap_ref, m.method, opts)
                        if err ~= "" then
                            svc:obs_log('warn', {
                                what = 'metric_get_failed',
                                class = m.class,
                                id = m.id,
                                field = m.field,
                                err = err
                            })
                        else
                            publish_metric(conn, m.metric_key, value)
                        end
                    end
                end
            end

            -- boot_time: derived from platform uptime, only published when NTP-synced.
            if time_synced and platform_cap then
                local uptime_opts, uptime_opts_err = cap_sdk.args.new.PlatformGetOpts('uptime', report_period)
                if uptime_opts_err ~= "" then
                    svc:obs_log('warn', { what = 'uptime_opts_invalid', err = uptime_opts_err })
                else
                    local uptime, uptime_err = cap_rpc(platform_cap, 'get', uptime_opts)
                    if uptime == nil or uptime_err ~= "" then
                        svc:obs_log('warn', { what = 'uptime_get_failed', err = uptime_err })
                    else
                        publish_metric(conn, 'boot_time', os.time() - math.floor(uptime))
                    end
                end
            end

        end
    end
end

-- ── shutdown orchestration ─────────────────────────────

local SHUTDOWN_GRACE = 10          -- seconds services have to shut down
local USB3_MODEL     = "bigbox-ss" -- only model with controllable USB3 hardware

---@param svc ServiceBase
---@param power_cap CapabilityReference?
---@param alarm SystemAlarm
local function handle_alarm(svc, power_cap, alarm)
    local conn       = svc.conn
    local payload    = alarm.payload or {}
    local alarm_name = payload.name or "scheduled alarm"
    local alarm_type = payload.type or "reboot"

    svc:obs_log('info', { what = 'alarm_fired', name = alarm_name, type = alarm_type })
    svc:obs_event('alarm_fired', { name = alarm_name, type = alarm_type, ts = svc:now() })

    if not power_cap then
        svc:obs_log('error', { what = 'alarm_aborted', reason = 'power cap unavailable', alarm = alarm_name })
        return
    end

    -- Broadcast shutdown signal so all services can clean up within the deadline.
    conn:retain(t_shutdown_control(), {
        reason   = alarm_name,
        deadline = fibers.now() + SHUTDOWN_GRACE,
    })

    -- After the grace period, issue the power command via the capability.
    local ok, spawn_err = fibers.current_scope():spawn(function()
        perform(sleep.sleep_op(SHUTDOWN_GRACE))
        svc:obs_log('info', { what = 'power_command', type = alarm_type })
        local power_opts = cap_sdk.args.new.PowerActionOpts()
        local _, err = cap_rpc(power_cap, alarm_type, power_opts)
        if err ~= "" then
            svc:obs_log('error', { what = 'power_command_failed', type = alarm_type, err = err })
        end
    end)
    if not ok then
        svc:obs_log('error', { what = 'power_fiber_spawn_failed', err = tostring(spawn_err) })
    end
end

-- ── system main fiber ──────────────────────────────

---@param svc ServiceBase
---@param report_period_ch Channel
local function system_main(svc, report_period_ch)
    local conn = svc.conn
    svc:obs_log('debug', 'main started')

    local parent_scope = fibers.current_scope()
    parent_scope:finally(function()
        local _, primary = parent_scope:status()
        svc:obs_log('debug', { what = 'main_stopped', reason = tostring(primary or 'ok') })
        svc:status('stopped', { reason = tostring(primary or 'ok') })
    end)

    -- Acquire platform cap to read hw_revision from identity state.
    local platform_cap = wait_for_cap(conn, svc, 'platform', '1')

    -- Read hw_revision to gate USB3 control to bigbox-ss hardware only.
    local hw_revision = nil
    if platform_cap then
        local identity_sub = platform_cap:get_state_sub('identity')
        local identity_msg = perform(op.choice(
            identity_sub:recv_op(),
            sleep.sleep_op(REQUEST_TIMEOUT)
        ))
        if identity_msg and type(identity_msg.payload) == 'table' and identity_msg.payload.hw_revision then
            hw_revision = identity_msg.payload.hw_revision:match('(%S+)')
            svc:obs_log('debug', { what = 'hw_revision_detected', value = hw_revision })
        else
            svc:obs_log('warn', 'platform identity not available at startup; USB3 control disabled')
        end
    end

    -- Acquire USB cap only if this is bigbox-ss hardware.
    local usb_cap = nil
    if hw_revision == USB3_MODEL then
        usb_cap = wait_for_cap(conn, svc, 'usb', 'usb3')
    end

    -- Acquire power cap upfront — needed when alarms fire.
    local power_cap = wait_for_cap(conn, svc, 'power', '1')

    local alarm_mgr = alarms.AlarmManager.new()
    local cfg_sub   = conn:subscribe(t_cfg(svc.name))
    local time_sub  = conn:subscribe(t_svc_time_synced())

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
            local cfg, err = validate_config(msg.payload and msg.payload.data)
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
                if usb_cap then
                    local usb_verb = cfg.usb3_enabled and 'enable' or 'disable'
                    local _, usb_err = cap_rpc(usb_cap, usb_verb, {})
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
            handle_alarm(svc, power_cap, msg)
        end
    end
end

-- ── service entry point ──────────────────────────────

---@class SystemService
local SystemService = {}

---@param conn Connection
---@param opts? { name?: string, env?: string, heartbeat_s?: number }
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
