local queue = require "fibers.queue"
local op = require "fibers.op"
local fiber = require "fibers.fiber"
local log = require "services.log"
local hal_capabilities = require "services.hal.hal_capabilities"
local utils = require "services.hal.utils"
local service = require "service"
local new_msg = require "bus".new_msg
local unpack = table.unpack or unpack

local BandDriver = {}
BandDriver.__index = BandDriver

local BAND_MAPPING = {
    ["2G"] = "802_11g",
    ["5G"] = "802_11a"
}
local KICK_MODES = {
    none = 0,
    compare = 1,
    absolute = 2,
    both = 3
}
local SUPPORT_OPTIONS = {
    'ht', 'vht'
}
local VALID_UPDATE_KEYS = {
    'client', 'chan_util', 'hostapd', 'beacon_reports', 'tcp_con', ''
}
local VALID_TIMEOUTS = {
    'probe', 'client', 'ap'
}
local VALID_RRM_MODES = {
    'PAT'
}
local VALID_LEGACY_OPTIONS = {
    'eval_probe_req', 'eval_assoc_req', 'eval_auth_req',
    'min_probe_count', 'deny_assoc_reason', 'deny_auth_reason'
}
local VALID_NETWORKING_METHODS = {
    'broadcast', 'tcp+umdns', 'tcp',
    broadcast = 0,
    ['tcp+umdns'] = 2,
    ['multicast'] = 2,
    tcp = 3
}

local sections = {
    { name = 'global',  type = 'metric' },
    { name = '802_11g', type = 'metric' },
    { name = '802_11a', type = 'metric' },
    { name = 'gbltime', type = 'times' },
    { name = 'gblnet', type = 'network'},
    { name = 'localcfg', type = 'local' }
}

-------------------------------------------------------------------------
--- BandCapabilities ----------------------------------------------------

function BandDriver:set_log_level(ctx, level)
    if type(level) ~= "number" or level < 0 then
        return nil, "Invalid log level"
    end

    local req = self.conn:request(new_msg(
        { 'hal', 'capability', 'uci', '1', 'control', 'set' },
        { 'dawn', 'localcfg', 'log_level', level }
    ))
    local resp, ctx_err = req:next_msg_with_context(ctx)
    req:unsubscribe()
    if ctx_err or (resp.payload and resp.payload.err) then
        return nil, ctx_err or resp.payload.err
    end

    return true, nil
end

function BandDriver:set_kicking(ctx,
                                mode,
                                bandwidth_threshold,
                                kicking_threshold,
                                evals_before_kick
)
    if not KICK_MODES[mode] then
        return nil, "Invalid kick mode"
    end
    if type(bandwidth_threshold) ~= "number" or bandwidth_threshold < 0 then
        return nil, "Invalid bandwidth threshold"
    end
    if type(kicking_threshold) ~= "number" or kicking_threshold < 0 then
        return nil, "Invalid kicking threshold"
    end
    if type(evals_before_kick) ~= "number" or evals_before_kick < 0 then
        return nil, "Invalid evaluations before kick"
    end

    local reqs = {}

    reqs[#reqs + 1] = self.conn:request(new_msg(
        { 'hal', 'capability', 'uci', '1', 'control', 'set' },
        { 'dawn', 'global', 'kicking', KICK_MODES[mode] }
    ))

    reqs[#reqs + 1] = self.conn:request(new_msg(
        { 'hal', 'capability', 'uci', '1', 'control', 'set' },
        { 'dawn', 'global', 'bandwidth_threshold', bandwidth_threshold }
    ))

    reqs[#reqs + 1] = self.conn:request(new_msg(
        { 'hal', 'capability', 'uci', '1', 'control', 'set' },
        { 'dawn', 'global', 'kicking_threshold', kicking_threshold }
    ))

    reqs[#reqs + 1] = self.conn:request(new_msg(
        { 'hal', 'capability', 'uci', '1', 'control', 'set' },
        { 'dawn', 'global', 'min_number_to_kick', evals_before_kick }
    ))

    for _, req in ipairs(reqs) do
        local resp, ctx_err = req:next_msg_with_context(ctx)
        req:unsubscribe()
        if ctx_err or (resp.payload and resp.payload.err) then
            return nil, ctx_err or resp.payload.err
        end
    end

    return true, nil
end

function BandDriver:set_station_counting(ctx, use_station_count, max_station_diff)
    if type(use_station_count) ~= "boolean" then
        return nil, "Invalid use_station_count"
    end
    if type(max_station_diff) ~= "number" or max_station_diff < 0 then
        return nil, "Invalid max_station_diff"
    end

    local reqs = {}

    reqs[#reqs + 1] = self.conn:request(new_msg(
        { 'hal', 'capability', 'uci', '1', 'control', 'set' },
        { 'dawn', 'global', 'use_station_count', use_station_count}
    ))

    reqs[#reqs + 1] = self.conn:request(new_msg(
        { 'hal', 'capability', 'uci', '1', 'control', 'set' },
        { 'dawn', 'global', 'max_station_diff', max_station_diff }
    ))

    for _, req in ipairs(reqs) do
        local resp, ctx_err = req:next_msg_with_context(ctx)
        req:unsubscribe()
        if ctx_err or (resp.payload and resp.payload.err) then
            return nil, ctx_err or resp.payload.err
        end
    end

    return true, nil
end

function BandDriver:set_rrm_mode(ctx, mode)
    if not utils.is_in(mode, VALID_RRM_MODES) then
        return nil, "Invalid RRM mode"
    end

    local req = self.conn:request(new_msg(
        { 'hal', 'capability', 'uci', '1', 'control', 'set' },
        { 'dawn', 'global', 'rrm_mode', mode }
    ))
    local resp, ctx_err = req:next_msg_with_context(ctx)
    req:unsubscribe()
    if ctx_err or (resp.payload and resp.payload.err) then
        return nil, ctx_err or resp.payload.err
    end

    return true, nil
end

function BandDriver:set_neighbour_reports(ctx, dyn_report_num, disassoc_report_len)
    dyn_report_num = tonumber(dyn_report_num)
    disassoc_report_len = tonumber(disassoc_report_len)

    if type(dyn_report_num) ~= "number" or dyn_report_num < 0 then
        return nil, "Invalid dyn_report_num"
    end
    if type(disassoc_report_len) ~= "number" or disassoc_report_len < 0 then
        return nil, "Invalid disassoc_report_len"
    end

    local reqs = {}
    reqs[#reqs + 1] = self.conn:request(new_msg(
        { 'hal', 'capability', 'uci', '1', 'control', 'set' },
        { 'dawn', 'global', 'set_hostapd_nr', dyn_report_num }
    ))
    reqs[#reqs + 1] = self.conn:request(new_msg(
        { 'hal', 'capability', 'uci', '1', 'control', 'set' },
        { 'dawn', 'global', 'disassoc_nr_length', disassoc_report_len }
    ))

    for _, req in ipairs(reqs) do
        local resp, ctx_err = req:next_msg_with_context(ctx)
        req:unsubscribe()
        if ctx_err or (resp.payload and resp.payload.err) then
            return nil, ctx_err or resp.payload.err
        end
    end

    return true, nil
end

function BandDriver:set_legacy_options(ctx, opts)
    if type(opts) ~= "table" then
        return nil, "Options must be a table"
    end

    for key, value in pairs(opts) do
        if not utils.is_in(key, VALID_LEGACY_OPTIONS) then
            return false, "No entry associated with " .. key
        end
        if type(value) == "nil" then
            return false, "Invalid value for " .. key
        end

        local req = self.conn:request(new_msg(
            { 'hal', 'capability', 'uci', '1', 'control', 'set' },
            { 'dawn', 'hostapd', key, value }
        ))
        local resp, ctx_err = req:next_msg_with_context(ctx)
        req:unsubscribe()
        if ctx_err or (resp.payload and resp.payload.err) then
            return nil, ctx_err or resp.payload.err
        end
    end

    return true, nil
end

function BandDriver:set_band_priority(ctx, band, priority)
    band = band:upper()
    if type(priority) ~= "number" or priority < 0 then
        return nil, "Invalid priority"
    end
    local full_band = BAND_MAPPING[band]
    if not full_band then
        return nil, "Invalid band"
    end

    local req = self.conn:request(new_msg(
        { 'hal', 'capability', 'uci', '1', 'control', 'set' },
        { 'dawn', full_band, 'initial_score', priority }
    ))
    local resp, ctx_err = req:next_msg_with_context(ctx)
    req:unsubscribe()
    if ctx_err or (resp.payload and resp.payload.err) then
        return nil, ctx_err or resp.payload.err
    end

    return true, nil
end

function BandDriver:set_band_kicking(ctx,
                                     band,
                                     options)
    band = band:upper()
    local full_band = BAND_MAPPING[band]
    if not full_band then
        return nil, "Invalid band"
    end

    local configs = {
        rssi_center = {type = "number", entry = { 'dawn', full_band, 'rssi_center' }},
        rssi_reward_threshold = {type = "number", entry = { 'dawn', full_band, 'rssi_val' }},
        rssi_reward = {type = "number", entry = { 'dawn', full_band, 'rssi' }},
        rssi_penalty_threshold = {type = "number", entry = { 'dawn', full_band, 'low_rssi_val' }},
        rssi_penalty = {type = "number", entry = { 'dawn', full_band, 'low_rssi' }},
        rssi_weight = {type = "number", entry = { 'dawn', full_band, 'rssi_weight' }},
        channel_util_reward_threshold = {type = "number", entry = { 'dawn', full_band, 'chan_util_val' }},
        channel_util_reward = {type = "number", entry = { 'dawn', full_band, 'chan_util' }},
        channel_util_penalty_threshold = {type = "number", entry = { 'dawn', full_band, 'max_chan_util_val' }},
        channel_util_penalty = {type = "number", entry = { 'dawn', full_band, 'max_chan_util' }}
    }

    local reqs = {}
    for key, value in pairs(options) do
        local config = configs[key]
        if not config then
            return false, "No entry associated with " .. key
        end
        if type(value) ~= config.type then
            return false, "Invalid type for " .. key
        end

        local config_entry = {unpack(config.entry)}
        table.insert(config_entry, value)
        reqs[#reqs + 1] = self.conn:request(new_msg(
            { 'hal', 'capability', 'uci', '1', 'control', 'set' },
            config_entry
        ))
    end

    for _, req in ipairs(reqs) do
        local resp, ctx_err = req:next_msg_with_context(ctx)
        req:unsubscribe()
        if ctx_err or (resp.payload and resp.payload.err) then
            return nil, ctx_err or resp.payload.err
        end
    end

    return true, nil
end

function BandDriver:set_support_bonus(ctx, band, support, reward)
    band = band:upper()
    if not BAND_MAPPING[band] then
        return nil, "Invalid band"
    end
    if not utils.is_in(support, SUPPORT_OPTIONS) then
        return nil, "Invalid support option"
    end
    if type(reward) ~= "number" then
        return nil, "Invalid reward"
    end

    local req = self.conn:request(new_msg(
        { 'hal', 'capability', 'uci', '1', 'control', 'set' },
        { 'dawn', BAND_MAPPING[band], support .. '_support', reward }
    ))
    local resp, ctx_err = req:next_msg_with_context(ctx)
    req:unsubscribe()
    if ctx_err or (resp.payload and resp.payload.err) then
        return nil, ctx_err or resp.payload.err
    end

    return true, nil
end

function BandDriver:set_update_freq(ctx, updates)
    if type(updates) ~= "table" then
        return nil, "Updates must be a table"
    end

    local reqs = {}
    for key, freq in pairs(updates) do
        if not utils.is_in(key, VALID_UPDATE_KEYS) then
            return nil, "Invalid update key: " .. key
        end
        if type(freq) ~= "number" or freq < 0 then
            return nil, "Invalid frequency for " .. key
        end

        reqs[#reqs + 1] = self.conn:request(new_msg(
            { 'hal', 'capability', 'uci', '1', 'control', 'set' },
            { 'dawn', 'gbltime', 'update_' .. key, freq }
        ))
    end

    for _, req in ipairs(reqs) do
        local resp, ctx_err = req:next_msg_with_context(ctx)
        req:unsubscribe()
        if ctx_err or (resp.payload and resp.payload.err) then
            return nil, ctx_err or resp.payload.err
        end
    end

    return true, nil
end

function BandDriver:set_client_inactive_kickoff(ctx, timeout)
    timeout = tonumber(timeout)
    if type(timeout) ~= "number" or timeout < 0 then
        return nil, "Invalid timeout"
    end

    local req = self.conn:request(new_msg(
        { 'hal', 'capability', 'uci', '1', 'control', 'set' },
        { 'dawn', 'gbltime', 'con_timeout', timeout }
    ))
    local resp, ctx_err = req:next_msg_with_context(ctx)
    req:unsubscribe()
    if ctx_err or (resp.payload and resp.payload.err) then
        return nil, ctx_err or resp.payload.err
    end

    return true, nil
end

function BandDriver:set_cleanup(ctx, timeouts)
    if type(timeouts) ~= "table" then
        return nil, "Timeouts must be a table"
    end

    local reqs = {}
    for key, timeout in pairs(timeouts) do
        if not utils.is_in(key, VALID_TIMEOUTS) then
            return nil, "Invalid timeout key: " .. key
        end
        if type(timeout) ~= "number" or timeout < 0 then
            return nil, "Invalid timeout for " .. key
        end

        reqs[#reqs + 1] = self.conn:request(new_msg(
            { 'hal', 'capability', 'uci', '1', 'control', 'set' },
            { 'dawn', 'gbltime', 'remove_' .. key, timeout }
        ))
    end

    for _, req in ipairs(reqs) do
        local resp, ctx_err = req:next_msg_with_context(ctx)
        req:unsubscribe()
        if ctx_err or (resp.payload and resp.payload.err) then
            return nil, ctx_err or resp.payload.err
        end
    end

    return true, nil
end

function BandDriver:set_networking(ctx, method, options)
    local configs = {
        ip = {type = "string", entry = { 'dawn', 'gblnet', 'tcp_ip' }},
        port = {type = "number", entry = { 'dawn', 'gblnet', 'tcp_port' }},
        broadcast_port = {type = "number", entry = { 'dawn', 'gblnet', 'broadcast_port' }},
        enable_encryption = {type = "boolean", entry = { 'dawn', 'gblnet', 'use_symm_enc' }},
    }

    local method_id = VALID_NETWORKING_METHODS[method]
    if not method_id then
        return nil, "Invalid networking method: " .. tostring(method)
    end

    local reqs = {}
    reqs[#reqs + 1] = self.conn:request(new_msg(
        { 'hal', 'capability', 'uci', '1', 'control', 'set' },
        { 'dawn', 'gblnet', 'method', method_id }
    ))
    for key, value in pairs(options) do
        local config = configs[key]
        if not config then
            return false, "No entry associated with " .. key
        end
        if type(value) ~= config.type then
            return false, "Invalid type for " .. key
        end

        local config_entry = {unpack(config.entry)}
        table.insert(config_entry, value)
        reqs[#reqs + 1] = self.conn:request(new_msg(
            { 'hal', 'capability', 'uci', '1', 'control', 'set' },
            config_entry
        ))
    end

    for _, req in ipairs(reqs) do
        local resp, ctx_err = req:next_msg_with_context(ctx)
        req:unsubscribe()
        if ctx_err or (resp.payload and resp.payload.err) then
            return nil, ctx_err or resp.payload.err
        end
    end
    return true, nil
end

function BandDriver:apply(ctx)
    local req = self.conn:request(new_msg(
        { 'hal', 'capability', 'uci', '1', 'control', 'commit' },
        { 'dawn' }
    ))
    local resp, ctx_err = req:next_msg_with_context(ctx)
    req:unsubscribe()
    if ctx_err or (resp.payload and resp.payload.err) then
        return nil, ctx_err or resp.payload.err
    end

    return true, nil
end

-------------------------------------------------------------------------

--- Apply band capabilities
--- @param capability_info_q Queue
--- @return table
--- @return string?
function BandDriver:apply_capabilities(capability_info_q)
    self.info_q = capability_info_q
    local capabilities = {
        band = {
            control = hal_capabilities.new_band_capability(self.command_q),
            id = "1"
        }
    }
    return capabilities, nil
end

--- Handle a capability request
--- @param ctx Context
--- @param request table
function BandDriver:handle_capability(ctx, request)
    local command = request.command
    local args = request.args or {}
    local ret_ch = request.return_channel

    if type(ret_ch) == 'nil' then return end

    if type(command) == "nil" then
        ret_ch:put({
            result = nil,
            err = 'No command was provided'
        })
        return
    end

    local func = self[command]
    if type(func) ~= "function" then
        ret_ch:put({
            result = nil,
            err = "Command does not exist"
        })
        return
    end

    fiber.spawn(function()
        local result, err = func(self, ctx, unpack(args))

        ret_ch:put({
            result = result,
            err = err
        })
    end)
end

--- Main driver loop
--- @param ctx Context
function BandDriver:_main(ctx)
    log.info(string.format(
        "%s - %s: Starting",
        ctx:value("service_name"),
        ctx:value("fiber_name")
    ))

    -- Main event loop
    while not ctx:err() do
        op.choice(
            self.command_q:get_op():wrap(function(req)
                self:handle_capability(ctx, req)
            end),
            ctx:done_op()
        ):perform()
    end

    log.info(string.format(
        "%s - %s: Exiting",
        ctx:value("service_name"),
        ctx:value("fiber_name")
    ))
end

--- Spawn driver fiber
--- @param conn Connection The bus connection
function BandDriver:spawn(conn)
    self.conn = conn
    service.spawn_fiber(string.format("Band Driver (%s)", self.band), conn, self.ctx, function(fctx)
        self:_main(fctx)
    end)
end

function BandDriver:init(ctx, conn)
    local req = conn:request(new_msg(
        { 'hal', 'capability', 'uci', '1', 'control', 'foreach' },
        { 'dawn', nil, function(cursor, section)
            if section[".type"] ~= "hostapd" then
                cursor:delete('dawn', section[".name"])
            end
        end }
    ))
    local resp, ctx_err = req:next_msg_with_context(ctx)
    req:unsubscribe()
    if ctx_err or (resp.payload and resp.payload.err) then
        return resp.payload.result, resp.payload.err or ctx_err
    end

    for _, section in ipairs(sections) do
        local req = conn:request(new_msg(
            { 'hal', 'capability', 'uci', '1', 'control', 'set' },
            { 'dawn', section.name, section.type }
        ))
        local resp, ctx_err = req:next_msg_with_context(ctx)
        req:unsubscribe()
        if ctx_err or (resp.payload and resp.payload.err) then
            return resp.payload.result, resp.payload.err or ctx_err
        end
    end

    local commit_req = conn:request(new_msg(
        { 'hal', 'capability', 'uci', '1', 'control', 'commit' },
        { 'dawn' }
    ))

    local resp, ctx_err = commit_req:next_msg_with_context(ctx)
    commit_req:unsubscribe()
    if resp.payload then
        return resp.payload.result, resp.payload.err or ctx_err
    end
    return nil, ctx_err or "No response from UCI"
end

function BandDriver.new(ctx)
    local self = {
        ctx = ctx,
        command_q = queue.new(10)
    }
    return setmetatable(self, BandDriver)
end

return { new = BandDriver.new }
