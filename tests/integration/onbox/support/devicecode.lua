local process = require 'onbox.support.process'
local util = require 'onbox.support.util'
local quote = process.quote

local M = {}

---@class OnboxDependencies
---@field commands table<string, string>? Executable name to opkg package name.
---@field modules table<string, string>? Lua module name to opkg package name.

---@class OnboxDevicecode
---@field box OnboxSession
---@field args OnboxArgs
---@field runtime string
---@field original table
---@field config_path string?
---@field persistent_existed boolean
---@field changed boolean
local Devicecode = {}
Devicecode.__index = Devicecode

---@param box OnboxSession
---@return OnboxDevicecode
function M.new(box)
    return setmetatable({ box = box, args = box.args, runtime = box.args.runtime, original = {},
        persistent_existed = false, changed = false }, Devicecode)
end

---Check the installed tools even if opkg reports errors while updating/installing.
---@param dependencies OnboxDependencies
---@param label string?
---@return nil
function Devicecode:ensure_dependencies(dependencies, label)
    local checks = {}
    for command, package in pairs(dependencies.commands or {}) do
        checks[#checks + 1] = { check = 'command -v ' .. quote(command) .. ' >/dev/null', package = package }
    end
    for name, package in pairs(dependencies.modules or {}) do
        checks[#checks + 1] = {
            check = "luajit -e " .. quote('assert(require(' .. string.format('%q', name) .. '))') .. ' >/dev/null 2>&1',
            package = package,
        }
    end
    local script = { "missing=''" }
    for _, check in ipairs(checks) do
        script[#script + 1] = check.check .. ' || missing="$missing "' .. quote(check.package)
    end
    script[#script + 1] = [[
        if [ -n "$missing" ]; then
            opkg update || echo 'opkg update returned nonzero; checking installation anyway'
            opkg install $missing || true
        fi
    ]]
    for _, check in ipairs(checks) do script[#script + 1] = check.check .. ' || exit 1' end
    local result = self.box.ssh:run(table.concat(script, '\n'), { timeout = 180, check = false })
    label = label or 'dependencies'
    util.write(self.box.artifacts .. '/' .. label .. '.log', result.stdout .. result.stderr)
    assert(result.code == 0, 'Missing box dependencies; see ' .. label .. '.log')
end

---Read and save configuration without changing the running service.
---@return nil
function Devicecode:prepare()
    self.box.ssh:run('umask 077; mkdir -p ' .. quote(self.box.remote) .. ' && test -x ' .. quote(self.args.service)
        .. ' && test -f ' .. quote(self.runtime .. '/main.lua'))
    self:ensure_dependencies({ commands = { luajit = 'luajit', tar = 'tar' },
        modules = { ['cjson.safe'] = 'lua-cjson' } })
    self.args.target = self.args.target or util.trim(
        self.box.ssh:run("awk '{print $1; exit}' /etc/hwrevision").stdout)
    assert(self.args.target:match('^[%w_-]+$'), 'Invalid configuration target')
    local original_text = self.box.ssh:run('cat ' .. quote(self.runtime .. '/configs/'
        .. self.args.target .. '.json')).stdout
    self.original = util.decode(original_text)
    util.write(self.box.artifacts .. '/original-bootstrap.json', original_text)
    local config_root
    for _, namespace in ipairs(self.original.hal.data.filesystem) do
        if namespace.name == 'config' then config_root = namespace.root; break end
    end
    assert(config_root, 'No config filesystem root')
    if config_root:sub(1, 1) ~= '/' then config_root = self.runtime .. '/' .. config_root end
    self.config_path = config_root:gsub('/+$', '') .. '/' .. self.args.target .. '.json'
    local existing = self.box.ssh:run('test -f ' .. quote(self.config_path) .. ' && cat ' .. quote(self.config_path),
        { check = false })
    self.persistent_existed = existing.code == 0
    if self.persistent_existed then util.write(self.box.artifacts .. '/original-persistent.json', existing.stdout) end
end

---@return nil
function Devicecode:backup()
    self.box.ssh:run('tar -czf ' .. quote(self.box.remote .. '/original-runtime.tar.gz')
        .. ' -C ' .. quote(self.runtime) .. ' .', { timeout = 120 })
end

---@param label string
---@param config table? Optional replacement staged config; source configs are untouched.
---@return string archive_path
function Devicecode:build(label, config)
    print('[' .. label .. '] Building code and vendor libraries')
    local log = self.box.artifacts .. '/' .. label .. '-build.log'
    local result = self.box.process:run('cd ' .. quote(self.args.repo) .. ' && ' .. self.args.build_command,
        { timeout = 900, log_path = log })
    if result.code ~= 0 then
        io.stderr:write(result.stdout:sub(-4000), '\n')
        error('Build failed; see ' .. log, 0)
    end
    if config then
        util.write(self.args.repo .. '/build/configs/' .. self.args.target .. '.json', util.encode(config))
    end
    local archive = self.box.artifacts .. '/' .. label .. '-build.tar.gz'
    result = self.box.process:run('tar -czf ' .. quote(archive) .. ' -C ' .. quote(self.args.repo .. '/build') .. ' .',
        { timeout = 120 })
    assert(result.code == 0, result.stderr)
    return archive
end

---@param action 'start'|'stop'|'restart'
---@return nil
function Devicecode:service(action)
    assert(action == 'start' or action == 'stop' or action == 'restart', 'Invalid service action')
    self.box.ssh:run(quote(self.args.service) .. ' ' .. action, { timeout = 45 })
end

---@param archive string? Omit to stop the service without replacing code.
---@return nil
function Devicecode:deploy(archive)
    if archive then self.box.ssh:upload(archive, self.box.remote .. '/build.tar.gz') end
    self.changed = true
    self:service('stop')
    if archive then
        self.box.ssh:run('tar -xzf ' .. quote(self.box.remote .. '/build.tar.gz') .. ' -C ' .. quote(self.runtime),
            { timeout = 120 })
    end
end

---@param config table
---@return nil
function Devicecode:write_config(config)
    self.changed = true
    for _, destination in ipairs({ self.runtime .. '/configs/' .. self.args.target .. '.json', self.config_path }) do
        self.box.ssh:run('umask 077; mkdir -p ' .. quote(assert(destination:match('^(.*)/[^/]+$')))
            .. '; cat > ' .. quote(destination), { data = util.encode(config) })
    end
end

---@return nil
function Devicecode:restore_persistent()
    if self.persistent_existed then
        self.box.ssh:upload(self.box.artifacts .. '/original-persistent.json', self.config_path)
    elseif self.config_path ~= self.runtime .. '/configs/' .. self.args.target .. '.json' then
        self.box.ssh:run('rm -f ' .. quote(self.config_path))
    end
end

---Leave the restored service stopped so the caller can perform device-specific recovery.
---@return nil
function Devicecode:restore_runtime()
    self:service('stop')
    self.box.ssh:run('tar -xzf ' .. quote(self.box.remote .. '/original-runtime.tar.gz')
        .. ' -C ' .. quote(self.runtime), { timeout = 120 })
    self:restore_persistent()
end

---@return table<string, string>
function Devicecode:diagnostic_commands()
    return { devicecode = 'ubus call service list ' .. quote(util.encode({
        name = self.args.service:match('([^/]+)$'),
    })) }
end

return M
