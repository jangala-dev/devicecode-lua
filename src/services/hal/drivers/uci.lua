local queue = require "fibers.queue"
local channel = require "fibers.channel"
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
        cap_control_q = queue.new(10), -- source of capability commands
        info_q = nil, -- to be assigned at initalisation
        policy_q = queue.new(10), -- source of restart policies
        config_update_q = queue.new(10), -- signals when a config has been updated for restart policies
        restart_q = queue.new(10), -- scheduled config restarts
        restart_state_ch = channel.new(), -- outputs state of restart worker
        restart_halt_ch = channel.new() -- signals restart worker to halt any restarts
    }
    return setmetatable(uci, UCI)
end

--- UCI command functions

--- Get the value of a UCI entry
--- @param _ Context
--- @param config string
--- @param section string
--- @param option string
--- @return any
--- @return string?
function UCI:get(_, config, section, option)
    local val, err = cursor:get(config, section, option)
    if err then
        return nil, err
    end
    return val, nil
end

--- Set the value of a UCI entry
--- @param _ Context
--- @param config string
--- @param section string
--- @param option string
--- @param value any
--- @return boolean
--- @return string?
function UCI:set(_, config, section, option, value)
    local success, err
    if value == nil then
        success, err = cursor:set(config, section, option)
    else
        success, err = cursor:set(config, section, option, value)
    end
    if not success then
        return false, string.format("Failed to set %s.%s.%s to %s: %s", config, section, option, value, err)
    end
    return true, nil
end

--- Delete a UCI entry
--- @param _ Context
--- @param config string
--- @param section string
--- @param option string
--- @return boolean
--- @return string?
function UCI:delete(_, config, section, option)
    local success, err
    if option then
        success, err = cursor:delete(config, section, option)
    else
        success, err = cursor:delete(config, section)
    end
    if not success then
        return false, string.format("Failed to delete %s.%s.%s: %s", config, section, option, err)
    end
    return true, nil
end

--- Commit changes to a UCI configuration
--- @param ctx Context
--- @param config string
--- @return boolean
--- @return string?
function UCI:commit(ctx, config)
    local success, err = cursor:commit(config)
    if not success then
        return false, string.format("Failed to commit changes for %s: %s", config, err)
    end
    op.choice(
        self.config_update_q:put_op(config),
        ctx:done_op()
    ):perform()
    return true, nil
end

--- Add a new section to a UCI configuration
--- @param _ Context
--- @param config string
--- @param section_type string
--- @return string
--- @return string?
function UCI:add(_, config, section_type)
    local name = cursor:add(config, section_type)
    return name, nil
end

--- Revert saved but uncommitted changes
--- @param _ Context
--- @param config string
--- @return boolean
--- @return string?
function UCI:revert(_, config)
    local success, err = cursor:revert(config)
    if not success then
        return false, string.format("Failed to revert %s: %s", config, err)
    end
    return true, nil
end

--- Get a table of saved but uncommitted changes
--- @param _ Context
--- @param config string
--- @return table
--- @return string?
function UCI:changes(_, config)
    local changes, err = cursor:changes(config)
    if err then
        return nil, string.format("Failed to get changes for %s: %s", config, err)
    end
    return changes, nil
end

--- Bring up a network interface
--- @param ctx Context
--- @param interface string
--- @return boolean
--- @return string?
function UCI:ifup(ctx, interface)
    local ret, err = self:halt_restarts(ctx)
    if err then return ret, err end
    err = exec.command_context(ctx, 'ifup', interface):run()
    local ret2, err2 = self:continue_restarts(ctx) -- signal restart fiber to continue whether command succeeds or not
    return ret2, err or err2
end

--- Call a function for every section of a certain type
--- @param _ Context
--- @param config string
--- @param type string
--- @param callback fun(cursor: Cursor, section: table)
function UCI:foreach(_, config, type, callback)
    local success = cursor:foreach(config, type, function(section)
        callback(cursor, section)
    end)
    if not success then
        return false, string.format("Failed to iterate over %s.%s", config, type)
    end
    return true, nil
end

--- Assign a restart policy to a UCI config
--- @param ctx Context
--- @param config string
--- @param policy table
--- @param actions table
--- @return boolean
--- @return string?
function UCI:set_restart_policy(ctx, config, policy, actions)
    if not policy or not policy.method then
        return false, "Policy must be specified with a method"
    end
    local new_policy = {}
    if policy.method == 'immediate' then
        new_policy.next_restart = function()
            return sc.monotime()
        end
    elseif policy.method == 'defer' then
        if not policy.delay then return false, "Delay must be specified for delay_from_first method" end
        new_policy.next_restart = function(prev_delay)
            return prev_delay or sc.monotime() + policy.delay
        end
    elseif policy.method == 'debounce' then
        if not policy.delay then return false, "Delay must be specified for debounce method" end
        new_policy.next_restart = function()
            return sc.monotime() + policy.delay
        end
    elseif policy.method == 'manual' then
        new_policy.next_restart = function()
            return nil -- Manual restart means no automatic next restart
        end
    else
        return false, "Invalid restart policy method"
    end

    op.choice(
        self.policy_q:put_op({
            config = config,
            policy = new_policy,
            actions = actions
        }),
        ctx:done_op()
    ):perform()

    return true, nil
end

--- Signal restart fiber to halt
--- @param ctx Context
--- @return boolean
--- @return string?
function UCI:halt_restarts(ctx)
    op.choice(
        self.restart_halt_ch:put_op(true),
        ctx:done_op()
    ):perform()
    local state = "active"
    -- wait for restart fiber to halt
    while state ~= "halt" and not ctx:err() do
        op.choice(
            self.restart_state_ch:get_op():wrap(function(msg)
                state = msg
            end),
            ctx:done_op()
        ):perform()
    end
    return ctx:err() == nil, ctx:err()
end

--- Signal restart fiber to continue
--- @param ctx Context
--- @return boolean
--- @return string?
function UCI:continue_restarts(ctx)
    op.choice(
        self.restart_halt_ch:put_op(false),
        ctx:done_op()
    ):perform()
    return ctx:err() == nil, ctx:err()
end

--- Run requested method if exists
--- @param ctx Context
--- @param request table
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

--- Assign a restart policy to a specific config
--- @param config string
--- @param policy table
--- @param actions table
function UCI:handle_restart_policy(config, policy, actions)
    if not restart_policies[config] then
        restart_policies[config] = {}
    end

    restart_policies[config].get_next_restart = policy.next_restart
    restart_policies[config].current_restart = nil
    restart_policies[config].actions = actions
end

--- Get the nearest config restart time
--- @return table
function UCI:get_next_restart()
    local next_restart = {}
    for config, restart_policy in pairs(restart_policies) do
        if restart_policy.current_restart and
            (not next_restart.time or restart_policy.current_restart < next_restart.time) then
            next_restart = { config = config, time = restart_policy.current_restart, actions = restart_policy.actions }
        end
    end

    return next_restart
end

--- Update a config restart policy to new deadline
--- @param config string
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
end

--- Apply UCI capabilities
--- @param capability_info_q Queue
--- @return table
--- @return string?
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

--- Main loop for UCI driver
--- @param ctx Context
function UCI:_main(ctx)
    log.info(string.format(
        "%s - %s: UCI Main Starting",
        ctx:value("service_name"),
        ctx:value("fiber_name")
    ))
    local restart_op = nil
    while not ctx:err() do
        local ops = {
            self.cap_control_q:get_op():wrap(function(req)
                self:handle_capability(ctx, req)
            end),
            self.policy_q:get_op():wrap(function(msg)
                self:handle_restart_policy(msg.config, msg.policy, msg.actions)
            end),
            self.config_update_q:get_op():wrap(function(config)
                self:handle_config_update(config) -- update config restart deadline
                local next_restart = self:get_next_restart() -- get next occurring config restart
                if next_restart.config and next_restart.time then
                    restart_op = sleep.sleep_until_op(next_restart.time):wrap(function()
                        return next_restart
                    end)
                else
                    restart_op = nil
                end
            end),
            ctx:done_op()
        }
        -- Insert restart operation is there is a restart for a config scheduled
        if restart_op then
            table.insert(ops, restart_op:wrap(function(restarter)
                fiber.spawn(function()
                    self.restart_q:put(restarter) -- send restart to restart worker
                end)
                restart_policies[restarter.config].current_restart = nil -- reset config policy deadline
                local next_restart = self:get_next_restart() -- check if there are any other scheduled restarts
                if next_restart.config and next_restart.time then
                    restart_op = sleep.sleep_until_op(next_restart.time):wrap(function()
                        return next_restart
                    end)
                else
                    restart_op = nil
                end
            end))
        end
        op.choice(unpack(ops)):perform()
    end
    log.info(string.format(
        "%s - %s: UCI Main Exiting",
        ctx:value("service_name"),
        ctx:value("fiber_name")
    ))
end

--- Restart Worker
--- @param ctx Context
function UCI:_restart_worker(ctx)
    local to_restart = {}
    local next_deadline = sc.monotime() + 1
    local state = "active"
    local halt_num = 0
    while not ctx:err() do
        op.choice(
            self.restart_state_ch:put_op(state),
            self.restart_halt_ch:get_op():wrap(function(msg)
                local halt = msg
                halt_num = halt and (halt_num + 1) or (halt_num - 1) -- count the number of halts
                if halt_num <= 0 then
                    halt_num = 0 -- halts should never go below 0 but just in case
                    return
                end
                state = "halt"
                log.trace(string.format(
                    "%s - %s: Halted",
                    ctx:value("service_name"),
                    ctx:value("fiber_name")
                ))
                while halt_num > 0 and not ctx:err() do -- listen for halt messages until all halts are resolved
                    op.choice(
                        self.restart_halt_ch:get_op():wrap(function(msg)
                            halt = msg
                            halt_num = halt and (halt_num + 1) or (halt_num - 1)
                        end),
                        self.restart_state_ch:put_op(state), -- update restart state
                        ctx:done_op()
                    ):perform()
                end
                state = "active"
                log.trace(string.format(
                    "%s - %s: Active",
                    ctx:value("service_name"),
                    ctx:value("fiber_name")
                ))
            end),
            self.restart_q:get_op():wrap(function(msg)
                to_restart[msg.config] = msg -- schedule restart of config to take place
            end),
            sleep.sleep_until_op(next_deadline):wrap(function() -- iterate over all scheduled restarts every 1 second
                next_deadline = sc.monotime() + 1
                if next(to_restart) == nil then return end
                for config, restarter in pairs(to_restart) do
                    for i, action in ipairs(restarter.actions) do
                        log.trace(string.format(
                            "%s - %s: Restarting %s action %d",
                            ctx:value("service_name"),
                            ctx:value("fiber_name"),
                            config,
                            i
                        ))
                        exec.command_context(ctx, unpack(action)):run()
                        log.trace(string.format(
                            "%s - %s: Restarting %s action %d completed",
                            ctx:value("service_name"),
                            ctx:value("fiber_name"),
                            config,
                            i
                        ))
                    end
                end
                to_restart = {}
            end)
        ):perform()
    end
    log.info(string.format(
        "%s - %s: UCI Main Exiting",
        ctx:value("service_name"),
        ctx:value("fiber_name")
    ))
end

--- Spin up all fibers for UCI driver
--- @param conn Connection
function UCI:spawn(conn)
    service.spawn_fiber("UCI Driver", conn, self.ctx, function(fctx)
        self:_main(fctx)
    end)
    service.spawn_fiber("UCI Restarter", conn, self.ctx, function(fctx)
        self:_restart_worker(fctx)
    end)
end

return { new = UCI.new }
