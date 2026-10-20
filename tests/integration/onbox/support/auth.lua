local bit = require 'bit'
local fcntl = require 'posix.fcntl'
local signals = require 'posix.signal'
local termio = require 'posix.termio'
local unistd = require 'posix.unistd'

local M = {}

---@param password string
---@return nil
local function validate(password)
    assert(type(password) == 'string' and #password > 0 and #password <= 4095
        and not password:find('[%z\r\n]'), 'Password must contain 1–4095 bytes without NUL or line breaks')
end

---Read from a terminal only, restoring its settings on success, failure or cancellation.
---@param fd integer
---@param host string
---@return string password
function M.prompt_fd(fd, host)
    assert(unistd.isatty(fd), 'Password entry requires an interactive terminal')
    local original = assert(termio.tcgetattr(fd))
    local previous, interrupted = {}, false
    local ok, password = pcall(function()
        for _, sig in ipairs({ signals.SIGINT, signals.SIGTERM, signals.SIGHUP, signals.SIGQUIT,
            signals.SIGTSTP, signals.SIGTTIN, signals.SIGTTOU }) do
            previous[sig] = assert(signals.signal(sig, function() interrupted = true end, 0))
        end
        local hidden = {}
        for key, value in pairs(original) do hidden[key] = value end
        hidden.lflag = bit.band(bit.bor(hidden.lflag, termio.ICANON, termio.ISIG),
            bit.bnot(bit.bor(termio.ECHO, termio.ECHONL)))
        assert(termio.tcsetattr(fd, termio.TCSAFLUSH, hidden), 'Cannot disable password echo')
        local prompt = 'SSH password for ' .. host .. ': '
        assert(unistd.write(fd, prompt) == #prompt, 'Cannot write password prompt')
        local line = unistd.read(fd, 4096)
        assert(not interrupted, 'Password entry interrupted')
        assert(line and line:sub(-1) == '\n', 'Password entry ended or exceeded 4095 bytes')
        return line:sub(1, -2)
    end)
    local restored = termio.tcsetattr(fd, termio.TCSAFLUSH, original)
    unistd.write(fd, '\n')
    for sig, handler in pairs(previous) do signals.signal(sig, handler, 0) end
    assert(restored, 'Cannot restore terminal settings')
    if not ok then error(password, 0) end
    validate(password)
    return password
end

---@param host string
---@return string password
function M.prompt(host)
    local fd = fcntl.open('/dev/tty', bit.bor(fcntl.O_RDWR, fcntl.O_NOCTTY))
    assert(fd, 'Password entry requires an interactive terminal; use --password-file for unattended runs')
    local ok, password = pcall(M.prompt_fd, fd, host)
    unistd.close(fd)
    if not ok then error(password, 0) end
    return password
end

---Give sshpass a fresh inherited read descriptor, independently of SSH stdin.
---@generic T
---@param password string
---@param callback fun(fd: integer): T
---@return T
function M.with_password_fd(password, callback)
    validate(password)
    local reader, writer = unistd.pipe()
    assert(reader, 'Cannot create password pipe')
    local ok, result = pcall(function()
        local line = password .. '\n'
        assert(unistd.write(writer, line) == #line, 'Cannot fill password pipe')
        unistd.close(writer)
        writer = nil
        return callback(reader)
    end)
    if writer then unistd.close(writer) end
    unistd.close(reader)
    if not ok then error(result, 0) end
    return result
end

return M
