local queue = require "fibers.queue"
local op = require "fibers.op"
local fiber = require "fibers.fiber"
local sc = require "fibers.utils.syscall"
local sleep = require "fibers.sleep"
local exec = require "fibers.exec"
local hal_capabilities = require "services.hal.hal_capabilities"
local log = require "services.log"
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
function UCI:get(_, config, section, option)
    local val, err = cursor:get(config, section, option)
    if err then
        return nil, err
    end
    return val, nil
end

function UCI:set(_, config, section, option, value)
    local success, err = cursor:set(config, section, option, value)
    if not success then
        return nil, string.format("Failed to set %s.%s.%s to %s: %s", config, section, option, value, err)
    end
    return true, nil
end

function UCI:delete(_, config, section, option)
    local success, err = cursor:delete(config, section, option)
    if not success then
        return nil, string.format("Failed to delete %s.%s.%s: %s", config, section, option, err)
    end
    return true, nil
end

function UCI:commit(ctx, config)
    local success, err = cursor:commit(config)
    if not success then
        return nil, string.format("Failed to commit changes for %s: %s", config, err)
    end
    op.choice(
        self.config_update_q:put_op(config),
        ctx:done_op()
    ):perform()
    return true, nil
end

function UCI:show(_, config, section)
    local values, err = cursor:show(config, section)
    if err then
        return nil, string.format("Failed to show %s.%s: %s", config, section, err)
    end
    return values, nil
end

function UCI:add(_, config, section_type)
    local success, err = cursor:add(config, section_type)
    if not success then
        return nil, string.format("Failed to add %s.%s: %s", config, section_type, err)
    end
    return true, nil
end

function UCI:revert(_, config, section, option)
    local success, err = cursor:revert(config, section, option)
    if not success then
        return nil, string.format("Failed to revert %s.%s.%s: %s", config, section, option, err)
    end
    return true, nil
end

function UCI:changes(_, config)
    local changes, err = cursor:changes(config)
    if err then
        return nil, string.format("Failed to get changes for %s: %s", config, err)
    end
    return changes, nil
end

function UCI:ifup(ctx, interface)
    local err = exec.command_context(ctx, 'ifup', interface):run()
    return nil, err
end

function UCI:foreach(_, config, type, callback)
    local success = cursor:foreach(config, type, function (section)
        callback(cursor, section)
    end)
    if not success then
        return nil, string.format("Failed to iterate over %s.%s", config, type)
    end
    return true, nil
end

function UCI:set_restart_policy(ctx, config, policy, actions)
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
            return nil  -- Manual restart means no automatic next restart
        end
    else
        return nil, "Invalid restart policy method"
    end

    op.choice(
        self.policy_q:put_op({
            config = config,
            policy = new_policy,
            actions = actions
        }),
        ctx:done_op()
    ):perform()
end

function UCI:handle_capability(ctx, request)
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

function UCI:handle_restart_policy(config, policy, actions)
    if not restart_policies[config] then
        restart_policies[config] = {}
    end

    restart_policies[config].get_next_restart = policy.next_restart
    restart_policies[config].current_restart = nil
    restart_policies[config].actions = actions
end

function UCI:handle_config_update(config)
    if not restart_policies[config] then
        log.debug(string.format(
            "%s - %s: config %s has no set restart policy",
            self.ctx:value("service_name"),
            self.ctx:value("fiber_name"),
            config
        ))
        return {}
    end

    local restart_policy = restart_policies[config]
    restart_policy.current_restart = restart_policy.get_next_restart(restart_policy.current_restart)

    local next_restart = {}
    for config, restart_policy in pairs(restart_policies) do
        if restart_policy.current_restart and restart_policy.current_restart < next_restart.time then
            next_restart = {config = config, time = restart_policy.current_restart, actions = restart_policy.actions}
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
                self:handle_restart_policy(msg.config, msg.policy, msg.actions)
            end),
            self.config_update_q:get_op():wrap(function(config)
                local next_restart = self:handle_config_update(config)
                if next_restart.config and next_restart.time then
                    restart_op = sleep.sleep_until_op(next_restart.time):wrap(function ()
                        restart_op = nil
                        restart_policies[config].current_restart = nil
                        for _, action in ipairs(next_restart.actions or {}) do
                            exec.command_context(ctx, unpack(action)):run()
                        end
                    end)
                else
                    restart_op = nil
                end
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
