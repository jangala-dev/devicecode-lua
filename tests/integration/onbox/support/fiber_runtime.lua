local M = {}

local configured_repo
local modules

local function prepend(path)
    if not package.path:find(path, 1, true) then package.path = path .. package.path end
end

---@param repo string
---@return nil
function M.configure(repo)
    assert(type(repo) == 'string' and repo ~= '', 'Repository path is required for fibers')
    if configured_repo then
        assert(configured_repo == repo, 'Fibers runtime was configured for a different repository')
        return
    end
    local root = repo:gsub('/+$', '') .. '/vendor/lua-fibers/src/'
    prepend(root .. '?/init.lua;')
    prepend(root .. '?.lua;')
    configured_repo = repo
end

---@return table
function M.get()
    assert(configured_repo, 'Fibers runtime is not configured')
    if not modules then
        modules = {
            fibers = require 'fibers',
            runtime = require 'fibers.runtime',
            scope = require 'fibers.scope',
            op = require 'fibers.op',
            oneshot = require 'fibers.oneshot',
            sleep = require 'fibers.sleep',
            exec = require 'fibers.io.exec',
            file = require 'fibers.io.file',
        }
    end
    return modules
end

---@return boolean
function M.in_fiber()
    return configured_repo ~= nil and M.get().runtime.current_fiber() ~= nil
end

---@param notification table
---@return table op
function M.oneshot_op(notification)
    local f = M.get()
    return f.op.new_primitive(nil, function() return notification:is_triggered() end,
        function(suspension, wrap)
            local cancel = notification:add_waiter(function()
                if suspension:waiting() then suspension:complete(wrap) end
            end)
            suspension:add_cleanup(cancel)
        end)
end

---@return nil
function M.check_backend()
    assert(M.get().exec.supports('process_group'),
        'Selected fibers subprocess backend does not support process groups')
end

return M
