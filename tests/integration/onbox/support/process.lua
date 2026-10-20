local posix = require 'posix'
local clock = require 'posix.time'
local util = require 'onbox.support.util'

local M = {}

---@param value string|number
---@return string
function M.quote(value)
    return "'" .. tostring(value):gsub("'", "'\\''") .. "'"
end

---@param command string
---@return integer code
function M.execute(command)
    local ok, _, code = os.execute(command)
    if type(ok) == 'number' then
        return ok == 0 and 0 or (ok < 256 and 128 + ok or math.floor(ok / 256))
    end
    return ok and 0 or (code or 1)
end

---@param seconds number
---@return nil
function M.pause(seconds)
    assert(M.execute('sleep ' .. tostring(seconds)) == 0, 'Interrupted')
end

---@return number
function M.now()
    local value = assert(clock.clock_gettime(clock.CLOCK_MONOTONIC))
    return value.tv_sec + value.tv_nsec / 1e9
end

---@class OnboxRunState
---@field interrupted boolean?
---@field recovering boolean?

---@class OnboxCommandResult
---@field stdout string
---@field stderr string
---@field code integer

---@class OnboxCommandOpts
---@field timeout number?
---@field input_path string?
---@field log_path string?

---@class OnboxProcess
---@field artifacts string
---@field state OnboxRunState
local Process = {}
Process.__index = Process

---@param artifacts string
---@param state OnboxRunState?
---@return OnboxProcess
function M.new(artifacts, state)
    return setmetatable({ artifacts = artifacts, state = state or {} }, Process)
end

---@return nil
function Process:check_interrupted()
    assert(not self.state.interrupted or self.state.recovering, 'Interrupted')
end

---@param command string
---@param opts OnboxCommandOpts?
---@return OnboxCommandResult
function Process:run(command, opts)
    self:check_interrupted()
    opts = opts or {}
    local stdout = opts.log_path or (self.artifacts .. '/command.stdout')
    local stderr = self.artifacts .. '/command.stderr'
    local shell = ('timeout -k 5 %s sh -c %s < %s > %s '):format(
        tostring(opts.timeout or 40), M.quote(command), M.quote(opts.input_path or '/dev/null'), M.quote(stdout))
    shell = shell .. (opts.log_path and '2>&1' or ('2> ' .. M.quote(stderr)))
    local code = M.execute(shell)
    if (code == 130 or code == 143) and not self.state.recovering then
        self.state.interrupted = true
        error('Interrupted', 0)
    end
    return { stdout = util.read(stdout), stderr = opts.log_path and '' or util.read(stderr), code = code }
end

---Start a process group with output captured, returning its leader's PID.
---@param command string
---@param log_path string
---@param input_path string?
---@return integer pid
function Process:start(command, log_path, input_path)
    self:check_interrupted()
    local shell = 'setsid ' .. command .. ' > ' .. M.quote(log_path)
        .. ' 2>&1 < ' .. M.quote(input_path or '/dev/null') .. ' & echo $!'
    local pipe = assert(io.popen(shell, 'r'))
    local pid = tonumber(pipe:read('*l'))
    pipe:close()
    return assert(pid, 'Cannot start background process')
end

---@param pid integer
---@param grace number?
---@return nil
function Process:stop(pid, grace)
    posix.kill(-pid, 15)
    local deadline = M.now() + (grace or 2)
    while posix.kill(-pid, 0) and M.now() < deadline do
        clock.nanosleep({ tv_sec = 0, tv_nsec = 100000000 })
    end
    posix.kill(-pid, 9)
end

return M
