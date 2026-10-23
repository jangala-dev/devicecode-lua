local process = require 'onbox.support.process'
local util = require 'onbox.support.util'
local quote = process.quote

local M = {}

---@param content string
---@param filters string[]? Case-insensitive literal fragments.
---@param limit integer?
---@return string[]
function M.failure_lines(content, filters, limit)
    filters = filters or { 'devicecode', 'error', 'failed' }
    local relevant = {}
    for line in content:gmatch('[^\n]+') do
        local lower = line:lower()
        for _, filter in ipairs(filters) do
            if lower:find(filter:lower(), 1, true) then
                relevant[#relevant + 1] = line
                break
            end
        end
    end
    local tail = {}
    for i = math.max(1, #relevant - (limit or 70) + 1), #relevant do tail[#tail + 1] = relevant[i] end
    return tail
end

---@class OnboxLogs
---@field ssh OnboxSsh
---@field process OnboxProcess
---@field remote string
---@field artifacts string
---@field filters string[]?
---@field pid integer?
---@field pid_path string?
---@field path string?
local Logs = {}
Logs.__index = Logs

---@param ssh OnboxSsh
---@param commands OnboxProcess
---@param remote string
---@param filters string[]?
---@return OnboxLogs
function M.new(ssh, commands, remote, filters)
    return setmetatable({ ssh = ssh, process = commands, artifacts = commands.artifacts,
        remote = remote, filters = filters }, Logs)
end

---@param label string
---@return nil
function Logs:start(label)
    assert(not self.pid and not self.pid_path and not self.stopping, 'Log capture is already running')
    self.ssh:run('umask 077; mkdir -p ' .. quote(self.remote))
    self.pid_path = self.remote .. '/' .. label .. '-logread.pid'
    self.path = self.artifacts .. '/' .. label .. '-service.log'
    self.pid = self.ssh:start('echo $$ > ' .. quote(self.pid_path) .. '; exec logread -f', self.path)
    self.ssh:run('for i in $(seq 1 10); do test -s ' .. quote(self.pid_path)
        .. ' && exit 0; sleep 1; done; exit 1', { timeout = 15 })
    self.ssh:run('logger -t onbox-test ' .. quote('BEGIN ' .. label))
end

---@return nil
function Logs:stop()
    if self.stopping then return end
    if not self.pid and not self.pid_path then return end
    self.stopping = true
    -- Cleanup must still be allowed to SSH after the test has been interrupted.
    local state = self.process.state
    local recovering = state.recovering
    state.recovering = true
    local errors = {}
    local ok, err = pcall(function()
        if self.pid_path then
            self.ssh:run('onbox_log_pid=$(cat ' .. quote(self.pid_path) .. [=[ 2>/dev/null)
                case "$onbox_log_pid" in ''|*[!0-9]*) exit 0;; esac
                if grep -q '^Name:[[:space:]]*logread$' "/proc/$onbox_log_pid/status" 2>/dev/null; then
                    kill "$onbox_log_pid" 2>/dev/null || true
                fi
                rm -f ]=] .. quote(self.pid_path), { timeout = 15 })
            self.pid_path = nil
        end
    end)
    if not ok then errors[#errors + 1] = tostring(err) end
    if self.pid then
        local stopped, stop_err = pcall(function() self.process:stop(self.pid) end)
        if stopped then self.pid = nil else errors[#errors + 1] = tostring(stop_err) end
    end
    state.recovering = recovering
    self.stopping = false
    assert(#errors == 0, table.concat(errors, '\n'))
end

---@param label string
---@param extra_commands table<string, string>?
---@return nil
function Logs:diagnostics(label, extra_commands)
    print('Collecting diagnostics: ' .. self.artifacts)
    if self.path then
        print('Saved service log: ' .. self.path)
        local ok, err = pcall(function()
            for _, line in ipairs(M.failure_lines(util.read(self.path), self.filters)) do print(line) end
        end)
        if not ok then io.stderr:write('Could not read saved service log: ', tostring(err), '\n') end
    end
    local commands = { syslog = 'logread', processes = 'ps w; dmesg | tail -60' }
    for name, command in pairs(extra_commands or {}) do commands[name] = command end
    for _, name in ipairs(util.keys(commands)) do
        local ok, err = pcall(function()
            local result = self.ssh:run(commands[name], { check = false, timeout = 30 })
            util.write(self.artifacts .. '/' .. label .. '-' .. name .. '.log', result.stdout .. result.stderr)
            if name == 'syslog' then
                for _, line in ipairs(M.failure_lines(result.stdout, self.filters)) do print(line) end
            end
        end)
        if not ok then io.stderr:write('Could not collect ', name, ': ', tostring(err), '\n') end
    end
end

return M
