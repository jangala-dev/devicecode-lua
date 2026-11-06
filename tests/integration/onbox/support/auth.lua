local bit = require 'bit'
local fcntl = require 'posix.fcntl'
local signals = require 'posix.signal'
local termio = require 'posix.termio'
local unistd = require 'posix.unistd'

local M = {}
local leases = setmetatable({}, { __mode = 'k' })
local active_leases = 0

local function set_cloexec(fd, enabled)
    local flags = assert(fcntl.fcntl(fd, fcntl.F_GETFD), 'Cannot inspect password descriptor flags')
    local cloexec = fcntl.FD_CLOEXEC or 1
    local updated = enabled and bit.bor(flags, cloexec) or bit.band(flags, bit.bnot(cloexec))
    assert(fcntl.fcntl(fd, fcntl.F_SETFD, updated), 'Cannot update password descriptor flags')
end

local function record(lease)
    return assert(leases[lease], 'Invalid or expired credential lease')
end

---Internal support API: validate a live lease and return its descriptor.
function M.lease_fd(lease)
    local value = record(lease)
    assert(value.active, 'Credential lease is closed')
    assert(fcntl.fcntl(value.fd, fcntl.F_GETFD) ~= nil, 'Credential descriptor is closed')
    return value.fd
end

function M.lease_is_inheritable(lease)
    local fd = M.lease_fd(lease)
    local flags = assert(fcntl.fcntl(fd, fcntl.F_GETFD))
    return bit.band(flags, fcntl.FD_CLOEXEC or 1) == 0
end

---Internal support API: change inheritance only while the launch gate is held.
function M.set_lease_inheritable(lease, inheritable)
    local fd = M.lease_fd(lease)
    set_cloexec(fd, not inheritable)
    return fd
end

---Internal support API: close a lease without exposing raw close ownership.
function M.close_lease(lease)
    local value = record(lease)
    if not value.active then return end
    pcall(set_cloexec, value.fd, true)
    local closed, close_err = unistd.close(value.fd)
    value.active = false
    active_leases = active_leases - 1
    assert(closed, close_err or 'Cannot close credential descriptor')
end

function M.has_active_leases() return active_leases > 0 end

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
    local configured, configure_err = pcall(set_cloexec, reader, true)
    if not configured then
        unistd.close(reader)
        unistd.close(writer)
        error(configure_err, 0)
    end
    local lease = {}
    leases[lease] = { fd = reader, active = true }
    active_leases = active_leases + 1
    local ok, result = pcall(function()
        local line = password .. '\n'
        assert(unistd.write(writer, line) == #line, 'Cannot fill password pipe')
        assert(unistd.close(writer), 'Cannot close password writer')
        writer = nil
        return callback(reader, lease)
    end)
    if writer then unistd.close(writer) end
    M.close_lease(lease)
    if not ok then error(result, 0) end
    return result
end

return M
