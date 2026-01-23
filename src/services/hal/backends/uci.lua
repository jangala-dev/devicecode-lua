local queue = require "fibers.queue"
local channel = require "fibers.channel"
local fibers = require "fibers"
local uci_mod = require "uci"

local Q_SIZE = 10

---@class UCI
---@field commit_q Queue
---@field cursor unknown
local UCI = {
    commit_q = queue.new(Q_SIZE),
    cursor = uci_mod.cursor()
}

---@class Session
---@field _changes table[]
local Session = {}
Session.__index = Session

--- Create a new UCI session
--- @return Session
function Session.new()
    local self = setmetatable({}, Session)
    self._changes = {}
    self._commited = false
    return self
end

--- Get a value from the UCI configuration
--- @param config string
--- @param section string
--- @param option string
--- @return any value
--- @return string? error
function Session:get(config, section, option)
    return UCI.get(config, section, option)
end

--- Set a value in the UCI configuration
--- @param config string
--- @param section string
--- @param option string
--- @param value any
--- @return string? error
function Session:set(config, section, option, value)
    if self._commited then
        return "Cannot modify a committed session"
    end
    if config == nil or section == nil or option == nil then
        return "Invalid arguments for UCI set operation"
    end
    local change
    if value == nil then
        change = {command = "set_section", config = config, section_name = section, section_type = option}
    else
        change = {command = "set_value", config = config, section = section, option = option, value = value}
    end
    table.insert(self._changes, change)
end

function Session:delete(config, section, option)
    if self._commited then
        return "Cannot modify a committed session"
    end
    if config == nil or section == nil then
        return "Invalid arguments for UCI delete operation"
    end
    local change
    if option == nil then
        change = {command = "delete_section", config = config, section = section}
    else
        change = {command = "delete_option", config = config, section = section, option = option}
    end
    table.insert(self._changes, change)
end

function Session:add(config, section_type)
    if self._commited then
        return "Cannot modify a committed session"
    end
    if config == nil or section_type == nil then
        return nil, "Invalid arguments for UCI add operation"
    end
    local change = {command = "add_section", config = config, section_type = section_type}
    table.insert(self._changes, change)
end

function Session:foreach(config, section_type, map_func)
    if self._commited then
        return "Cannot modify a committed session"
    end
    if config == nil or section_type == nil or map_func == nil then
        return "Invalid arguments for UCI foreach operation"
    end
    if type(map_func) ~= "function" then
        return "map_func must be a function"
    end
    table.insert(self._changes, {command = "foreach", config = config, section_type = section_type, map_func = map_func})
end

function Session:commit()
    if self._commited then
        return "Session has already been committed"
    end
    local reply_ch = channel.new()
    UCI.commit_q:put({ changes = self._changes, reply_ch = reply_ch })
    self._changes = {}
    local reply = reply_ch:get()
    if not reply then
        return nil, "No reply received for UCI commit"
    end
    self._commited = true
    return reply.success, reply.err
end

-- Create a new UCI session
--- @return Session
function UCI.new_session()
    return Session.new()
end

--- Get a value from the UCI configuration
--- @param config string
--- @param section string
--- @param option string
--- @return any value
--- @return string? error
function UCI.get(config, section, option)
    return UCI.cursor:get(config, section, option)
end

--- A switch-case utility function
--- @param key any
--- @return fun(cases: table<string, fun(): ...>): ...
local function switch(key)
    return function(cases)
        local func = cases[key]
        if func then
            return func()
        else
            if cases["default"] then
                return cases["default"]()
            else
                error("No case matched and no default case provided")
            end
        end
    end
end

function UCI.reactor()
    local this_is_where_a_scope_check_would_go = true
    while this_is_where_a_scope_check_would_go do
        local commit = UCI.commit_q:get()

        local ret, err
        for _, change in ipairs(commit.changes) do
            ret, err = switch(change.command) {
                set_value = function()
                    local success = UCI.cursor:set(change.config, change.section, change.option, change.value)
                    return success, success == false and "Failed to set value" or nil
                end,
                set_section = function()
                    local success = UCI.cursor:set(change.config, change.section_name, change.section_type)
                    return success, success == false and "Failed to set section" or nil
                end,
                delete_option = function()
                    local success = UCI.cursor:delete(change.config, change.section, change.option)
                    return success, success == false and "Failed to delete option" or nil
                end,
                delete_section = function()
                    local success = UCI.cursor:delete(change.config, change.section)
                    return success, success == false and "Failed to delete section" or nil
                end,
                add_section = function()
                    local name = UCI.cursor:add(change.config, change.section_type)
                    return name, name == nil and "Failed to add section" or nil
                end,
                foreach = function()
                    local success = UCI.cursor:foreach(change.config, change.section_type, change.map_func)
                    return success, success == false and "Failed to foreach" or nil
                end,
                default = function()
                    return nil, "Unknown UCI command: " .. tostring(change.command)
                end
            }

            if err then
                commit.reply_ch:put({ success = ret, err = err })
                break
            end
        end
        commit.reply_ch:put({ success = ret, err = nil })
    end
end



fibers.spawn(UCI.reactor)

return UCI

