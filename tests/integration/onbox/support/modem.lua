local posix = require 'posix'
local process = require 'onbox.support.process'
local util = require 'onbox.support.util'
local quote = process.quote

local M = {}

---@class OnboxModemInfo
---@field id string
---@field imei string
---@field device string
---@field state string
---@field failed_reason string?
---@field plugin string
---@field model string
---@field at_port string?
---@field name string?

---@class OnboxModems
---@field box OnboxSession
---@field probe_uploaded boolean?
local Modems = {}
Modems.__index = Modems

---@param box OnboxSession
---@return OnboxModems
function M.new(box)
    return setmetatable({ box = box }, Modems)
end

---@return table<string, OnboxModemInfo>
function Modems:inventory()
    local listing = self.box.ssh:run('mmcli -L', { timeout = 20 }).stdout
    local result = {}
    for id in listing:gmatch('/Modem/(%d+)') do
        local reply = self.box.ssh:run('mmcli -m ' .. id .. ' -J', { check = false, timeout = 20 })
        if reply.code == 0 then
            local generic = util.decode(reply.stdout).modem.generic
            local imei, ports = tostring(generic['equipment-identifier'] or ''), {}
            for _, port in ipairs(generic.ports or {}) do
                local name = port:match('^(.*) %(at%)$')
                if name then ports[#ports + 1] = name end
            end
            if imei ~= '' then
                local at_port = ports[2] or ports[1]
                result[imei] = { id = id, imei = imei, device = generic.device or '', state = generic.state,
                    failed_reason = generic['state-failed-reason'], plugin = generic.plugin or '',
                    model = generic.model or '', at_port = at_port and '/dev/' .. at_port or nil }
            end
        end -- Objects can disappear between list and query during reset.
    end
    return result
end

---@param targets table<string, OnboxModemInfo> Stable IMEI keys, not mmcli IDs.
---@param state string
---@param old_ids table<string, string>?
---@param require_at boolean? Also wait for ModemManager to report an AT port.
---@return table<string, OnboxModemInfo>
function Modems:wait(targets, state, old_ids, require_at)
    local deadline, last_status = process.now() + self.box.args.timeout, ''
    while process.now() < deadline do
        local ok, current = pcall(function() return self:inventory() end)
        if ok then
            local statuses, matched, result = {}, true, {}
            for _, imei in ipairs(util.keys(targets)) do
                local modem = current[imei]
                statuses[#statuses + 1] = (targets[imei].name or imei:sub(-4))
                    .. '=' .. (modem and modem.state or 'absent')
                    .. (modem and not modem.at_port and ' (no AT port)' or '')
                if modem then
                    assert(modem.state == state or (modem.state ~= 'failed' and modem.state ~= 'locked'),
                        ('Modem …%s became %s: %s'):format(imei:sub(-4), modem.state, modem.failed_reason or ''))
                    result[imei] = modem
                end
                if not modem or modem.state ~= state or (old_ids and modem.id == old_ids[imei]) then matched = false end
                if require_at and modem and not modem.at_port then matched = false end
            end
            local status = table.concat(statuses, ', ')
            if status ~= last_status then print('  Waiting for ' .. state .. ': ' .. status); last_status = status end
            if matched then return result end
        elseif self.box.interrupted then error('Interrupted', 0) end
        process.pause(2)
    end
    error(('Timed out after %ss waiting for %s: %s'):format(self.box.args.timeout, state, last_status), 0)
end

---@param targets table<string, OnboxModemInfo>
---@param require_at boolean? Reset/recovery itself does not require an AT port.
---@return nil
function Modems:clean_boot(targets, require_at)
    local current, old_ids = self:inventory(), {}
    for _, imei in ipairs(util.keys(targets)) do
        old_ids[imei] = assert(current[imei], 'Target modem missing before reset: ' .. imei).id
    end
    for _, imei in ipairs(util.keys(old_ids)) do
        self.box.ssh:run('mmcli -m ' .. old_ids[imei] .. ' --reset', { timeout = 45 })
    end
    self:wait(targets, 'disabled', old_ids, require_at)
end

---Run AT commands with ModemManager paused; a remote watchdog always resumes it.
---@param modem OnboxModemInfo
---@param commands string[]
---@return OnboxCommandResult
function Modems:probe(modem, commands)
    assert(#commands > 0, 'AT probe requires at least one command')
    assert(modem.at_port and modem.at_port ~= '',
        'No AT port reported by ModemManager for modem …' .. (modem.imei or ''):sub(-4))
    if not self.probe_uploaded then
        local module_path = assert(package.searchpath('onbox.support.modem', package.path))
        local directory = assert(posix.realpath(module_path)):match('^(.*)/[^/]+$')
        self.box.ssh:upload(directory .. '/at_probe.lua', self.box.remote .. '/at_probe.lua')
        self.probe_uploaded = true
    end
    local watchdog = #commands * 4 + 12
    local remote = [[
        onbox_mm_pid=$(pidof ModemManager)
        [ -n "$onbox_mm_pid" ] || exit 1
        trap 'kill -CONT "$onbox_mm_pid" 2>/dev/null; kill "$onbox_guard" 2>/dev/null || true' EXIT HUP INT TERM
        (sleep ]] .. watchdog .. [[; kill -CONT "$onbox_mm_pid" 2>/dev/null) >/dev/null 2>&1 & onbox_guard=$!
        kill -STOP "$onbox_mm_pid" || exit 1
        luajit ]] .. quote(self.box.remote .. '/at_probe.lua') .. ' ' .. quote(self.box.args.runtime)
        .. ' ' .. quote(modem.at_port)
    for _, command in ipairs(commands) do remote = remote .. ' ' .. quote(command) end
    return self.box.ssh:run(remote, { timeout = watchdog + 5, check = false })
end

---@return nil
function Modems:resume_manager()
    self.box.ssh:run('kill -CONT $(pidof ModemManager) 2>/dev/null || true')
end

---@return table<string, string>
function Modems:diagnostic_commands()
    return { modems = [[mmcli -L; for id in $(mmcli -L | sed -n 's@.*Modem/\([0-9]*\).*@\1@p'); do
        mmcli -m "$id" -J; done]] }
end

return M
