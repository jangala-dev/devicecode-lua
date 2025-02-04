local op = require "fibers.op"
local log = require "log"

local gsm_service = {}
gsm_service.__index = {}
gsm_service.name = 'GSM'

local configs = {}

local Modem = {}
Modem.__index = Modem

-- Qs for when in office:
-- check what state modem with sim opens in
function Modem:enable_autoconnect()
    -- right now just points to endpoints but may instead go to more complex functions
    -- this only take into account current state, how to nicely detect removal of sim
    -- perhaps the modem driver can add a custom state if a state transition idicative of a sim
    -- removal happens, then we can have state = no_sim
    -- no_sim = (connected to registered) or (registered to enabled)
    local state_machine = {
        failed = { endpoint = 'fix_failure' },
        no_sim = { endpoint = 'wait_for_sim' },
        disabled = { endpoint = 'enable' },
        registered = { endpoint = 'simple_connect', args = 'whatever goes here, some sorta connection string' },
        connected = { endpoint = 'net port stuff??', args = 'imagine knowing' }
    }
    local state_sub = self.bus_conn:subscribe(self.root_topic .. 'info/state')
    while not self.ctx:err() do
        local state_msg = op.choice(
            state_sub:next_msg_op(),
            self.ctx:done_op()
        ):perform()
        if state_msg then
            local state_info = state_msg.payload
            local transition = state_machine[state_info.curr_state]
            if transition then
                local ctrl_sub = self.bus_conn:request({
                    topic = string.format('%s/control/%s', self.root_topic, transition.endpoint),
                    payload = transition.args
                })
                local ctrl_response = op.choice(
                    ctrl_sub:next_msg_op(),
                    self.ctx:done_op()
                ):perform()
                if ctrl_response then
                    local ctrl_result = ctrl_response.payload.result
                    local err = ctrl_response.payload.error or ctrl_result.error
                    if err then log.error(err) end
                end
            end
        end
    end
end

local function new_modem(index, configs, bus_conn, ctx)
    local self = setmetatable({}, Modem)
    self.root_topic = string.format('hal/capability/modem/%s/', index)
    self.bus_conn = bus_conn
    self.index = index
    self.ctx = ctx
    if configs.autoconnect then self:enable_autoconnect() end
    return self
end

local function modem_listener(bus_conn, ctx)
    local modem_sub = bus_conn:subscribe('hal/capability/modem/+')

    while not ctx:err() do
        local modem_event = op.choice(
            modem_sub:next_msg_op(),
            ctx:done_op()
        ):perform()

        if modem_event then
            local modem_name = modem_event.payload.name
            local name = (modem_name == 'unknown') and 'default' or modem_name
            new_modem(modem_event.index, configs[modem_name], bus_conn, ctx)
        end
    end
end

function gsm_service:start(bus_connection, service_ctx)
    local device_event_sub = bus_connection:subscribe('hal/device/usb/+')
    local cap_event_sub = bus_connection:subscribe('hal/capability/modem/+')
    modem_listener(bus_connection, service_ctx)
end
