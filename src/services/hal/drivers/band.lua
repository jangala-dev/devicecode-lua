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
    'client', 'chan_util', 'hostapd'
}

local sections = {
    { name = 'global',  type = 'metric' },
    { name = '802_11g', type = 'metric' },
    { name = '802_11a', type = 'metric' },
    { name = 'gbltime', type = 'times' }
}


-------------------------------------------------------------------------
--- BandCapabilities ----------------------------------------------------

function BandDriver:set_kick_mode(ctx, mode)
    if not KICK_MODES[mode] then
        return nil, "Invalid kick mode"
    end

    local req = self.conn:request(new_msg(
        { 'hal', 'capability', 'uci', '1', 'control', 'set' },
        { 'dawn', 'global', 'kicking', KICK_MODES[mode] }
    ))
    local resp = req:next_msg_with_context(ctx)
    if resp.payload then
        return resp.payload.result, resp.payload.err
    end
    return nil, ctx:err() or "No response from UCI"
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
    local resp = req:next_msg_with_context(ctx)
    if resp.payload then
        return resp.payload.result, resp.payload.err
    end
    return nil, ctx:err() or "No response from UCI"
end

function BandDriver:set_client_kicking(ctx,
                                       band,
                                       rssi_center,
                                       reward_threshold,
                                       reward,
                                       penalty_threshold,
                                       penalty,
                                       weight)
    band = band:upper()
    if type(rssi_center) ~= "number" then
        return nil, "Invalid RSSI center"
    end
    if type(reward_threshold) ~= "number" then
        return nil, "Invalid reward threshold"
    end
    if type(reward) ~= "number" then
        return nil, "Invalid reward"
    end
    if type(penalty_threshold) ~= "number" then
        return nil, "Invalid penalty threshold"
    end
    if type(penalty) ~= "number" then
        return nil, "Invalid penalty"
    end
    if type(weight) ~= "number" then
        return nil, "Invalid weight"
    end
    if not BAND_MAPPING[band] then
        return nil, "Invalid band"
    end

    local configs = {
        { 'dawn', BAND_MAPPING[band], 'rssi_center',  rssi_center },
        { 'dawn', BAND_MAPPING[band], 'rssi_val',     reward_threshold },
        { 'dawn', BAND_MAPPING[band], 'rssi',         reward },
        { 'dawn', BAND_MAPPING[band], 'low_rssi_val', penalty_threshold },
        { 'dawn', BAND_MAPPING[band], 'low_rssi',     penalty },
        { 'dawn', BAND_MAPPING[band], 'rssi_weight',  weight }
    }

    for _, config in ipairs(configs) do
        print("set_client_kicking", table.concat(config, '.'))
        local req = self.conn:request(new_msg(
            { 'hal', 'capability', 'uci', '1', 'control', 'set' },
            config
        ))
        local resp = req:next_msg_with_context(ctx)
        print("set_client_kicking", resp.payload.result, resp.payload.err)
        if resp.payload then
            if resp.payload.err then
                return nil, resp.payload.err
            end
        else
            return nil, ctx:err() or "No response from UCI"
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
    local resp = req:next_msg_with_context(ctx)
    if resp.payload then
        return resp.payload.result, resp.payload.err
    end
    return nil, ctx:err() or "No response from UCI"
end

function BandDriver:set_update_freq(ctx, updates)
    if type(updates) ~= "table" then
        return nil, "Updates must be a table"
    end

    for key, freq in pairs(updates) do
        if not utils.is_in(key, VALID_UPDATE_KEYS) then
            return nil, "Invalid update key: " .. key
        end
        if type(freq) ~= "number" or freq < 0 then
            return nil, "Invalid frequency for " .. key
        end

        local req = self.conn:request(new_msg(
            { 'hal', 'capability', 'uci', '1', 'control', 'set' },
            { 'dawn', '', 'update_' .. key, freq }
        ))
        local resp = req:next_msg_with_context(ctx)
        if resp.payload then
            if resp.payload.err then
                return nil, resp.payload.err
            end
        else
            return nil, ctx:err() or "No response from UCI"
        end
    end

    return true, nil
end

function BandDriver:set_client_inactive_kickoff(ctx, timeout)
    if type(timeout) ~= "number" or timeout < 0 then
        return nil, "Invalid timeout"
    end

    local req = self.conn:request(new_msg(
        { 'hal', 'capability', 'uci', '1', 'control', 'set' },
        { 'dawn', 'gbltime', 'con_timeout', timeout }
    ))
    local resp = req:next_msg_with_context(ctx)
    if resp.payload then
        return resp.payload.result, resp.payload.err
    end
    return nil, ctx:err() or "No response from UCI"
end

function BandDriver:set_client_cleanup(ctx, timeout)
    if type(timeout) ~= "number" or timeout < 0 then
        return nil, "Invalid timeout"
    end

    local req = self.conn:request(new_msg(
        { 'hal', 'capability', 'uci', '1', 'control', 'set' },
        { 'dawn', 'gbltime', 'remove_client', timeout }
    ))
    local resp = req:next_msg_with_context(ctx)
    if resp.payload then
        return resp.payload.result, resp.payload.err
    end
    return nil, ctx:err() or "No response from UCI"
end

function BandDriver:apply(ctx)
    local req = self.conn:request(new_msg(
        { 'hal', 'capability', 'uci', '1', 'control', 'commit' },
        { 'dawn' }
    ))
    local resp = req:next_msg_with_context(ctx)
    if resp.payload then
        return resp.payload.result, resp.payload.err
    end
    return nil, ctx:err() or "No response from UCI"
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
        print("BAND DRIVER:", command, result, err)

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
            cursor:delete('dawn', section[".name"])
        end }
    ))
    local resp = req:next_msg_with_context(ctx)
    if resp.payload and resp.payload.err then
        return resp.payload.result, resp.payload.err
    end

    for _, section in ipairs(sections) do
        local req = conn:request(new_msg(
            { 'hal', 'capability', 'uci', '1', 'control', 'set' },
            { 'dawn', section.name, section.type }
        ))
        local resp = req:next_msg_with_context(ctx)
        if resp.payload and resp.payload.err then
            return resp.payload.result, resp.payload.err
        end
    end
    return ctx:err() == nil, ctx:err()
end

function BandDriver.new(ctx)
    local self = {
        ctx = ctx,
        command_q = queue.new(10)
    }
    return setmetatable(self, BandDriver)
end

return { new = BandDriver.new }
