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
        cap_control_q = queue.new(10),    -- source of capability commands
        info_q = nil,                     -- to be assigned at initalisation
        actions_q = queue.new(10),        -- source of restart actions
        config_update_q = queue.new(10),  -- signals when a config has been updated for restart actions
        restart_q = queue.new(10),        -- scheduled config restarts
        restart_state_ch = channel.new(), -- outputs state of restart worker
        restart_halt_ch = channel.new()   -- signals restart worker to halt any restarts
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
function UCI:set(ctx, config, section, option, value)
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
function UCI:delete(ctx, config, section, option)
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
    local config_restart_ch = channel.new()
    op.choice(
        self.config_update_q:put_op({ config = config, notify_ch = config_restart_ch }),
        ctx:done_op()
    ):perform()
    local restart_result = op.choice(
        config_restart_ch:get_op(),
        ctx:done_op()
    ):perform()
    return restart_result and restart_result.ret or false, restart_result and restart_result.err or ctx:err()
end

--- Add a new section to a UCI configuration
--- @param _ Context
--- @param config string
--- @param section_type string
--- @return string
--- @return string?
function UCI:add(ctx, config, section_type)
    local name = cursor:add(config, section_type)
    return name, nil
end

--- Revert saved but uncommitted changes
--- @param _ Context
--- @param config string
--- @return boolean
--- @return string?
function UCI:revert(ctx, config)
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
function UCI:foreach(ctx, config, type, callback)
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
function UCI:set_restart_actions(ctx, config, actions)
    if not actions then
        return false, "Actions must be specified"
    end

    op.choice(
        self.actions_q:put_op({
            config = config,
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

    local str_args = {}
    for _, v in ipairs(args) do
        table.insert(str_args, tostring(v))
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
--- @param actions table
function UCI:handle_restart_actions(config, actions)
    if not restart_policies[config] then
        restart_policies[config] = { actions = actions }
    end
end

--- Get the nearest config restart time
--- @return table
-- function UCI:get_next_restart()
--     local next_restart = {}
--     for config, restart_policy in pairs(restart_policies) do
--         if restart_policy.current_restart and
--             (not next_restart.time or restart_policy.current_restart < next_restart.time) then
--             next_restart = { config = config, time = restart_policy.current_restart, actions = restart_policy.actions }
--         end
--     end
--     return next_restart
-- end

--- Update a config restart policy to new deadline
--- @param config string
-- function UCI:handle_config_update(config)
--     if not restart_policies[config] then
--         log.debug(string.format(
--             "%s - %s: config %s has no set restart policy",
--             self.ctx:value("service_name"),
--             self.ctx:value("fiber_name"),
--             config
--         ))
--         return {}
--     end

--     local restart_policy = restart_policies[config]
--     local old_time = restart_policy.current_restart
--     restart_policy.current_restart = restart_policy.get_next_restart(restart_policy.current_restart)
--     local new_time = restart_policy.current_restart
--     print("config update", config, old_time, new_time)
-- end

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
    local restarts = {}
    local next_group_restart = sc.monotime() + 1
    while not ctx:err() do
        local ops = {
            self.cap_control_q:get_op():wrap(function(req)
                self:handle_capability(ctx, req)
            end),
            self.actions_q:get_op():wrap(function(msg)
                self:handle_restart_actions(msg.config, msg.actions)
            end),
            self.config_update_q:get_op():wrap(function(commit_request)
                local restarter = restart_policies[commit_request.config]
                if not restarter then
                    commit_request.notify_ch:put({
                        err = "No restart actions set for config " .. commit_request.config
                    })
                    return
                end
                fiber.spawn(function()
                    self.restart_q:put({
                        config = commit_request.config,
                        actions = restarter.actions,
                        notify_ch = commit_request.notify_ch
                    })
                end)
            end),
            sleep.sleep_until_op(next_group_restart):wrap(function ()
                print("restarting")
                for config, restarter in pairs(restarts) do
                    print("\t", config)
                    for _, action in ipairs(restarter.actions) do
                        exec.command_context(ctx, unpack(action)):run()
                    end
                    restarts[config] = nil
                end
                next_group_restart = sc.monotime() + 1
            end),
            ctx:done_op()
        }
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
                    halt_num = 0                                     -- halts should never go below 0 but just in case
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
                local restarter = to_restart[msg.config]
                if not restarter then
                    restarter = { config = msg.config, actions = msg.actions, notify_channels = {} }
                    to_restart[msg.config] = restarter
                end
                table.insert(restarter.notify_channels, msg.notify_ch)
            end),
            sleep.sleep_until_op(next_deadline):wrap(function() -- iterate over all scheduled restarts every 1 second
                next_deadline = sc.monotime() + 1
                if next(to_restart) == nil then return end
                for config, restarter in pairs(to_restart) do
                    local _, err = cursor:commit(config)
                    if err then
                        for _, ch in ipairs(restarter.notify_channels) do
                            ch:put({ ret = false, err = err })
                        end
                        return
                    end
                    for i, action in ipairs(restarter.actions) do
                        log.trace(string.format(
                            "%s - %s: Restarting %s action %d",
                            ctx:value("service_name"),
                            ctx:value("fiber_name"),
                            config,
                            i
                        ))
                        local err = exec.command_context(ctx, unpack(action)):run()
                        if err then
                            log.error(string.format(
                                "%s - %s: Restarting %s action %d failed: %s",
                                ctx:value("service_name"),
                                ctx:value("fiber_name"),
                                config,
                                i,
                                err
                            ))
                            for _, ch in ipairs(restarter.notify_channels) do
                                ch:put({ ret = false, err = err })
                            end
                            break
                        end
                        log.trace(string.format(
                            "%s - %s: Restarting %s action %d completed",
                            ctx:value("service_name"),
                            ctx:value("fiber_name"),
                            config,
                            i
                        ))
                    end
                    for _, ch in ipairs(restarter.notify_channels) do
                        ch:put({ ret = err == nil, err = err })
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
