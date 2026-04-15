local cap_args = require 'services.hal.types.capability_args'

local fibers = require 'fibers'
local scope = require 'fibers.scope'
local sleep = require 'fibers.sleep'
local op = require 'fibers.op'

local perform = fibers.perform

local function t_cap_listen(class, id)
    return { 'cap', class, id, 'state' }
end

local function t_cap_state(class, id, state)
    return { 'cap', class, id, 'state', state }
end

local function t_cap_event(class, id, event)
    return { 'cap', class, id, 'event', event }
end

local function t_cap_control(class, id, method)
    return { 'cap', class, id, 'rpc', method }
end

---@class CapabilityReference
---@field conn Connection
---@field class CapabilityClass
---@field id CapabilityId
local CapabilityReference = {}
CapabilityReference.__index = CapabilityReference

function CapabilityReference:call_control_op(method, args, opts)
    return self.conn:call_op(t_cap_control(self.class, self.id, method), args, opts)
end

---@param method string
---@param args any
---@return Reply?
---@return string error
function CapabilityReference:call_control(method, args)
    return perform(self:call_control_op(method, args))
end

---@param field string
---@param opts table?
---@return Subscription
function CapabilityReference:get_state_sub(field, opts)
    return self.conn:subscribe(t_cap_state(self.class, self.id, field), opts)
end

---@param field string
---@param opts table?
---@return Subscription
function CapabilityReference:get_event_sub(field, opts)
    return self.conn:subscribe(t_cap_event(self.class, self.id, field), opts)
end

---@class CapListener
---@field conn Connection
---@field sub Subscription
---@field topic Topic
local CapListener = {}
CapListener.__index = CapListener

--- Wait for a capability to be added matching the listener's topic, and return a reference to it.
function CapListener:wait_for_cap_op()
    -- scope.run_op yields (st, report, ...body_returns) so we wrap to extract
    -- just the (cap_ref, err) pair that callers expect.
    return scope.run_op(function()
        while true do
            local msg, err = self.sub:recv()
            if err then return nil, err end
            if not msg then return nil, 'subscription closed' end

            local state = msg.payload
            if state == 'added' then
                local class, id = msg.topic[2], msg.topic[3]
                return setmetatable({ conn = self.conn, class = class, id = id }, CapabilityReference), ''
            end
        end
    end):wrap(function(st, report, cap, err)
        if st == 'ok' then
            return cap, err or ''
        else
            return nil, tostring(report)
        end
    end)
end

---@param opts { timeout?: number }
---@return CapabilityReference?
---@return string error
function CapListener:wait_for_cap(opts)
    opts = opts or {}
    local ops = { cap = self:wait_for_cap_op() }
    if opts.timeout then
        ops.timeout = sleep.sleep_op(opts.timeout)
    end
    local which, a, b = perform(op.named_choice(ops))
    if which == 'cap' then
        return a, b
    elseif which == 'timeout' then
        return nil, 'timeout'
    end
    return nil, 'unknown error'
end

function CapListener:close()
    self.sub:unsubscribe()
end

---@class CapSDK
local CapSDK = {
    args = cap_args,
}
CapSDK.__index = CapSDK

---@param conn Connection
---@param class CapabilityClass
---@param id CapabilityId
function CapSDK.new_cap_listener(conn, class, id)
    local topic = t_cap_listen(class, id)
    local sub = conn:subscribe(topic)
    return setmetatable({ conn = conn, sub = sub, topic = topic }, CapListener)
end

---@param conn Connection
---@param class CapabilityClass
---@param id CapabilityId
---@return CapabilityReference
function CapSDK.new_cap_ref(conn, class, id)
    return setmetatable({ conn = conn, class = class, id = id }, CapabilityReference)
end

return CapSDK
