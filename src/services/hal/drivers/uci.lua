local queue = require "fibers.queue"
local op = require "fibers.op"
local fiber = require "fibers.fiber"
local sc = require "fibers.utils.syscall"
local sleep = require "fibers.sleep"
local hal_capabilities = require "services.hal.hal_capabilities"
local service = require "service"
local uci = require "uci"
local unpack = table.unpack or unpack

local cursor = uci.cursor()

local restart_policies = {}

local UCI = {}
UCI.__index = UCI

function UCI.new(ctx)
    local uci = {
        ctx = ctx,
        cap_control_q = queue.new(10),
        info_q = nil,
        policy_q = queue.new(10),
        config_update_q = queue.new(10),
    }
    return setmetatable(uci, UCI)
end

--- UCI command functions (empty stubs)
function UCI:get(ctx, config, section, option)
    local ret = cursor:get(config, section, option)
    return ret, nil
end

function UCI:set(ctx, config, section, option, value)
end

function UCI:delete(ctx, config, section, option)
    -- TODO: Implement UCI delete
end

function UCI:commit(ctx, config)
    -- TODO: Implement UCI commit
end

function UCI:show(ctx, config, section)
    -- TODO: Implement UCI show
end

function UCI:add(ctx, config, section_type)
    -- TODO: Implement UCI add
end

function UCI:revert(ctx, config, section, option)
    -- TODO: Implement UCI revert
end

function UCI:changes(ctx, config)
    -- TODO: Implement UCI changes
end

function UCI:set_restart_policy(ctx, config, policy)
    if not policy or not policy.method then
        return nil, "Policy must be specified with a method"
    end
    local new_policy = {}
    if policy.method == 'immediate' then
        new_policy.next_restart = function ()
            return sc.realtime()
        end
    elseif policy.method == 'defer' then
        if not policy.delay then return nil, "Delay must be specified for delay_from_first method" end
        new_policy.next_restart = function (prev_delay)
            return prev_delay or sc.realtime() + policy.delay
        end
    elseif policy.method == 'debounce' then
        if not policy.delay then return nil, "Delay must be specified for debounce method" end
        new_policy.next_restart = function ()
            return sc.realtime() + policy.delay
        end
    elseif policy.method == 'manual' then
        new_policy.next_restart = function ()
            return math.huge()  -- Manual restart means no automatic next restart
        end
    else
        return nil, "Invalid restart policy method"
    end

    op.choice(
        self.policy_q:put_op({
            config = config,
            policy = new_policy
        }),
        ctx:done_op()
    ):perform()
end

function UCI:handle_capability(ctx, request)
    local command = request.command
    local args = request.args
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

function UCI:handle_restart_policy(config, policy)
    if not restart_policies[config] then
        restart_policies[config] = {}
    end

    restart_policies[config].get_next_restart = policy.next_restart
    restart_policies[config].current_restart = nil
end

function UCI:handle_config_update(config)
    if not restart_policies[config] then
        restart_policies[config] = {
            get_next_restart = function() return sc.realtime() end,
            current_restart = nil,
        }
    end

    local restart_policy = restart_policies[config]
    restart_policy.current_restart = restart_policy.get_next_restart(restart_policy.current_restart)

    local next_restart = {config = nil, time = math.huge()}
    for config, restart_policy in pairs(restart_policies) do
        if restart_policy.current_restart and restart_policy.current_restart < next_restart.time then
            next_restart = {config = config, time = restart_policy.current_restart}
        end
    end

    return next_restart
end


function UCI:apply_capabilities(capability_info_q)
    self.info_q = capability_info_q
    local capabilities = {
        uci = {
            control = hal_capabilities.new_uci_capability(self.cap_control_q),
            id = "1"
        }
    }
    return capabilities, nil
end

function UCI:_main(ctx)
    local restart_op = nil
    while not ctx:err() do
        op.choice(
            self.cap_control_q:get_op():wrap(function(req)
                self:handle_capability(ctx, req)
            end),
            self.policy_q:get_op():wrap(function(msg)
                self:handle_restart_policy(msg.config, msg.policy)
            end),
            self.config_update_q:get_op():wrap(function(config)
                local next_restart = self:handle_config_update(config)
                restart_op = sleep.sleep_until_op(next_restart.time):wrap(function ()
                    restart_op = nil
                    restart_policies[config].current_restart = nil
                    -- restart the required services, change implementation to allow multiple services to be restarted
                end)
            end),
            ctx:done_op(),
            restart_op
        ):perform()
    end
end

function UCI:spawn(conn)
    service.spawn_fiber("UCI Driver", conn, self.ctx, function(fctx)
        self:_main(fctx)
    end)
end

return { new = UCI.new }
