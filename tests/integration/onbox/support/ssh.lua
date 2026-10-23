local posix = require 'posix'
local auth = require 'onbox.support.auth'
local process = require 'onbox.support.process'
local util = require 'onbox.support.util'
local quote = process.quote

local M = {}

---@class OnboxSshOpts
---@field host string
---@field artifacts string
---@field password_file string?
---@field ask_pass boolean?

---@class OnboxRemoteOpts: OnboxCommandOpts
---@field check boolean?
---@field data string?

---@class OnboxSsh
---@field process OnboxProcess
---@field command string
---@field private password string?
local Ssh = {}
Ssh.__index = Ssh

---@param opts OnboxSshOpts
---@param commands OnboxProcess
---@param password string?
---@return OnboxSsh
function M.new(opts, commands, password)
    assert(not opts.ask_pass or (type(password) == 'string' and password ~= ''), 'Manual password was not supplied')
    local argv = { 'ssh', '-F', '/dev/null', '-o', 'ConnectTimeout=10', '-o', 'ServerAliveInterval=5',
        '-o', 'ServerAliveCountMax=3', '-o', 'StrictHostKeyChecking=accept-new', '-o', 'LogLevel=ERROR',
        '-o', 'UserKnownHostsFile=' .. opts.artifacts .. '/known_hosts' }
    if opts.ask_pass or opts.password_file then
        if opts.password_file then
            assert(posix.stat(opts.password_file), 'Password file does not exist: ' .. opts.password_file)
            -- sshpass reads the password file; the harness never opens it.
            table.insert(argv, 1, opts.password_file)
            table.insert(argv, 1, '-f')
            table.insert(argv, 1, 'sshpass')
        end
        for _, value in ipairs({ '-o', 'PubkeyAuthentication=no', '-o',
            'PreferredAuthentications=password,keyboard-interactive' }) do argv[#argv + 1] = value end
    else
        argv[#argv + 1], argv[#argv + 2] = '-o', 'BatchMode=yes'
    end
    argv[#argv + 1] = opts.host
    for i, value in ipairs(argv) do argv[i] = quote(value) end
    return setmetatable({ process = commands, command = table.concat(argv, ' '),
        password = opts.ask_pass and password or nil }, Ssh)
end

---@generic T
---@param callback fun(command: string): T
---@return T
function Ssh:with_command(callback)
    if not self.password then return callback(self.command, nil) end
    return auth.with_password_fd(self.password, function(fd, lease)
        return callback('sshpass -d ' .. fd .. ' ' .. self.command, lease)
    end)
end

---@param command string
---@param opts OnboxRemoteOpts?
---@return OnboxCommandResult
function Ssh:run(command, opts)
    opts = opts or {}
    local input_path = opts.input_path
    local request_workspace
    local function cleanup_request()
        local errors = {}
        if not request_workspace then return errors end
        if input_path then
            local removed, remove_err = os.remove(input_path)
            if not removed and posix.stat(input_path) then errors[#errors + 1] = tostring(remove_err) end
        end
        local removed_dir, dir_err = posix.rmdir(request_workspace)
        if not removed_dir then errors[#errors + 1] = tostring(dir_err) end
        request_workspace = nil
        return errors
    end
    if opts.data then
        assert(not input_path, 'Choose either data or input_path')
        request_workspace = assert(posix.mkdtemp(self.process.artifacts .. '/.request-XXXXXX'))
        local prepared, prepare_err = pcall(function()
            assert(posix.chmod(request_workspace, 'rwx------'))
            input_path = request_workspace .. '/stdin'
            util.write(input_path, opts.data)
        end)
        if not prepared then
            local errors = cleanup_request()
            if #errors > 0 then
                error(tostring(prepare_err) .. '\nRequest cleanup failed: ' .. table.concat(errors, '\n'), 0)
            end
            error(prepare_err, 0)
        end
    end
    local ok, result = pcall(self.with_command, self, function(ssh_command, lease)
        return self.process:run(ssh_command .. ' ' .. quote(command),
            { timeout = opts.timeout, input_path = input_path, log_path = opts.log_path,
                inherit_fds = lease and { lease } or nil })
    end)
    local cleanup_errors = cleanup_request()
    if not ok then
        if #cleanup_errors > 0 then
            error(tostring(result) .. '\nRequest cleanup failed: ' .. table.concat(cleanup_errors, '\n'), 0)
        end
        error(result, 0)
    end
    assert(#cleanup_errors == 0, 'Request cleanup failed: ' .. table.concat(cleanup_errors, '\n'))
    if opts.check ~= false and result.code ~= 0 then
        local detail = result.stderr ~= '' and result.stderr or result.stdout
        error(('Remote command failed (%d): %s'):format(result.code, detail:sub(-2000)), 0)
    end
    return result
end

---@param path string
---@param remote_path string
---@return nil
function Ssh:upload(path, remote_path)
    local parent = remote_path:match('^(.*)/[^/]+$') or '.'
    if parent == '' then parent = '/' end
    self:run('umask 077; mkdir -p ' .. quote(parent) .. ' && cat > ' .. quote(remote_path),
        { input_path = path, timeout = 120 })
end

---@param command string
---@param log_path string
---@return integer pid
function Ssh:start(command, log_path)
    return self:with_command(function(ssh_command, lease)
        return self.process:start(ssh_command .. ' ' .. quote(command), log_path, nil,
            { inherit_fds = lease and { lease } or nil })
    end)
end

---@return nil
function Ssh:close()
    self.password = nil
end

return M
