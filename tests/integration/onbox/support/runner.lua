local posix = require 'posix'
local signals = require 'posix.signal'
local stat = require 'posix.sys.stat'
local auth = require 'onbox.support.auth'
local process = require 'onbox.support.process'
local ssh = require 'onbox.support.ssh'
local logs = require 'onbox.support.logs'

local M = {}

---@class OnboxArgs
---@field repo string
---@field here string
---@field host string
---@field password_file string?
---@field ask_pass boolean
---@field runtime string
---@field service string
---@field target string?
---@field timeout number
---@field build_command string
---@field artifacts string
---@field help boolean?

---@class OnboxCliOptions
---@field prefix string?
---@field defaults table<string, any>?
---@field values table<string, string>? Additional option-to-field mappings.
---@field flags table<string, string>? Additional boolean option-to-field mappings.

M.help = [[
  --host HOST               Default root@172.28.100.1
  --password-file PATH      Passed directly to sshpass; default REPO/boxkey
  --ask-pass                Prompt once with terminal echo disabled
  --ssh-key-auth            Use SSH agent/key authentication instead
  --runtime PATH            Default /root/devicecode-lua
  --service PATH            Default /etc/init.d/devicecode
  --target NAME             Default /etc/hwrevision on the box
  --timeout SECONDS         Default 300 per state wait
  --build-command COMMAND   Default make build-all, run in this container
  --artifacts PATH          Private artifact directory; must not already exist]]

---@param argv string[]
---@param repo string
---@param here string
---@param options OnboxCliOptions?
---@return OnboxArgs
function M.parse_args(argv, repo, here, options)
    options = options or {}
    local args = { repo = repo, here = here, host = 'root@172.28.100.1', password_file = repo .. '/boxkey',
        runtime = '/root/devicecode-lua', service = '/etc/init.d/devicecode', timeout = 300,
        build_command = 'make build-all', ask_pass = false,
        artifacts = here .. '/artifacts/' .. (options.prefix or 'onbox') .. '-' .. os.date('%Y%m%d-%H%M%S') }
    for key, value in pairs(options.defaults or {}) do args[key] = value end
    local values = { ['--host'] = 'host', ['--password-file'] = 'password_file', ['--runtime'] = 'runtime',
        ['--service'] = 'service', ['--target'] = 'target', ['--timeout'] = 'timeout',
        ['--build-command'] = 'build_command', ['--artifacts'] = 'artifacts' }
    for option, field in pairs(options.values or {}) do
        assert(not values[option], 'Option already exists: ' .. option)
        values[option] = field
    end
    local index, auth_option = 1, nil
    while index <= #argv do
        local option = argv[index]
        if option == '--ask-pass' or option == '--ssh-key-auth' or option == '--password-file' then
            assert(not auth_option, 'Choose one of --ask-pass, --password-file or --ssh-key-auth')
            auth_option = option
        end
        if option == '--help' or option == '-h' then args.help = true
        elseif option == '--ask-pass' then args.ask_pass = true; args.password_file = nil
        elseif option == '--ssh-key-auth' then args.password_file = nil
        elseif options.flags and options.flags[option] then args[options.flags[option]] = true
        else
            local key = assert(values[option], 'Unknown option: ' .. option)
            index = index + 1
            args[key] = assert(argv[index], 'Missing value for ' .. option)
        end
        index = index + 1
    end
    args.timeout = assert(tonumber(args.timeout), 'Invalid timeout')
    assert(args.timeout > 0, 'Timeout must be positive')
    args.runtime = args.runtime:gsub('/+$', '')
    assert(args.runtime:sub(1, 1) == '/' and args.runtime ~= '' and args.runtime ~= '/root'
        and args.runtime ~= '/tmp', 'Runtime must name the application directory')
    if args.artifacts:sub(1, 1) ~= '/' then args.artifacts = posix.getcwd() .. '/' .. args.artifacts end
    if args.password_file and args.password_file:sub(1, 1) ~= '/' then
        args.password_file = posix.getcwd() .. '/' .. args.password_file
    end
    return args
end

---@param args OnboxArgs
---@return nil
function M.check_tools(args)
    for _, name in ipairs({ 'ssh', 'timeout', 'tar', 'setsid',
        (args.ask_pass or args.password_file) and 'sshpass' or nil }) do
        assert(process.execute('command -v ' .. name .. ' >/dev/null') == 0, 'Missing local command: ' .. name)
    end
end

---@class OnboxSession: OnboxRunState
---@field args OnboxArgs
---@field artifacts string
---@field remote string
---@field process OnboxProcess
---@field ssh OnboxSsh
---@field logs OnboxLogs
---@field private cleanups (fun(): nil)[]
local Session = {}
Session.__index = Session

---@param args OnboxArgs
---@param password string?
---@param filters string[]?
---@return OnboxSession
function M.new(args, password, filters)
    stat.umask(63)
    local parent = assert(args.artifacts:match('^(.*)/[^/]+$'))
    assert(process.execute('mkdir -p ' .. process.quote(parent)) == 0, 'Cannot create artifact parent')
    assert(process.execute('mkdir -m 700 ' .. process.quote(args.artifacts)) == 0,
        'Artifact directory already exists or is unwritable')
    local self = setmetatable({ args = args, artifacts = args.artifacts, cleanups = {},
        remote = '/tmp/devicecode-' .. assert(args.artifacts:match('([^/]+)$')) }, Session)
    self.process = process.new(args.artifacts, self)
    self.ssh = ssh.new(args, self.process, password)
    self.logs = logs.new(self.ssh, self.process, self.remote, filters)
    self:defer(function() self.ssh:close() end)
    return self
end

---@param args OnboxArgs
---@param filters string[]?
---@return OnboxSession
function M.open(args, filters)
    M.check_tools(args)
    return M.new(args, args.ask_pass and auth.prompt(args.host) or nil, filters)
end

---@param cleanup fun(): nil
---@return nil
function Session:defer(cleanup)
    self.cleanups[#self.cleanups + 1] = cleanup
end

---@param label string
---@param body fun(): nil
---@return nil
function Session:phase(label, body)
    local ok, err = pcall(function()
        self.logs:start(label)
        body()
    end)
    local stopped, stop_err = pcall(function() self.logs:stop() end)
    if not stopped then
        if ok then error(stop_err, 0) end
        io.stderr:write('Could not stop log capture: ', tostring(stop_err), '\n')
    end
    if not ok then error(err, 0) end
end

---@class OnboxRunHooks
---@field diagnostics (fun(): nil)?
---@field rollback (fun(): nil)? Test-specific policy; called only after failure.
---@field success_message string?

---@param body fun(): nil
---@param hooks OnboxRunHooks?
---@return integer exit_code
function Session:run(body, hooks)
    hooks = hooks or {}
    local previous = {}
    for _, sig in ipairs({ signals.SIGINT, signals.SIGTERM }) do
        previous[sig] = signals.signal(sig, function() self.interrupted = true end)
    end
    local ok, err = pcall(body)
    self.recovering = true
    local stopped, stop_err = pcall(function() self.logs:stop() end)
    if not stopped then
        if ok then ok, err = false, stop_err
        else io.stderr:write('Could not stop log capture: ', tostring(stop_err), '\n') end
    end
    if not ok then
        io.stderr:write('FAIL: ', tostring(err), '\n')
        local diagnosed, diag_err = pcall(hooks.diagnostics or function() self.logs:diagnostics('failure') end)
        if not diagnosed then io.stderr:write('Diagnostics failed: ', tostring(diag_err), '\n') end
        if hooks.rollback then
            local restored, restore_err = pcall(hooks.rollback)
            if not restored then
                io.stderr:write('ROLLBACK FAILED: ', tostring(restore_err), '. Backup: ', self.remote, '\n')
            end
        end
    end
    for i = #self.cleanups, 1, -1 do
        local cleaned, cleanup_err = pcall(self.cleanups[i])
        if not cleaned then ok = false; io.stderr:write('Cleanup failed: ', tostring(cleanup_err), '\n') end
    end
    self.cleanups = {}
    for sig, handler in pairs(previous) do signals.signal(sig, handler) end
    if ok then print((hooks.success_message or 'PASS') .. '. Logs and results: ' .. self.artifacts) end
    return ok and 0 or 1
end

return M
