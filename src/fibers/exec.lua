-- fibers/exec.lua
-- Provides facilities for executing external commands asynchronously using fibers.
local file = require 'fibers.stream.file'
local pollio = require 'fibers.pollio'
local fiber = require 'fibers.fiber'
local op = require 'fibers.op'
local waitgroup = require 'fibers.waitgroup'
local string_buffer = require 'fibers.utils.string_buffer'
local sc = require 'fibers.utils.syscall'

local io_names = {"stdin", "stdout", "stderr"}

local function close_all(...)
    local n = select('#', ...)
    for i = 1, n do
        local list = select(i, ...)
        for k, v in pairs(list) do
            if type(v) == "number" then
                sc.close(v)
            elseif v.close then
                v:close()
            end
            list[k] = nil
        end
    end
end

-- Define the command type
local Cmd = {}
Cmd.__index = Cmd -- set metatable

--- Constructor for Cmd.
-- @param name The name or path of the command to execute.
-- @param ... Additional arguments for the command.
-- @return A new Cmd instance.
local function command(name, ...)
    local self = setmetatable({}, Cmd)
    self.path = name
    self.args = {...}
    self.process = {}
    self.pipes = {
        child = {},
        child_cmd = {},
        ext_cmd = {},
        ext = {},
        wg = waitgroup.new(),
    }
    return self
end

--- Constructor for Cmd taking a `context`.
-- @param ctx The context to run the command under.
-- @param name The name or path of the command to execute.
-- @param ... Additional arguments for the command.
-- @return A new Cmd instance.
local function command_context(ctx, name, ...)
    local cmd = command(name, ...)
    cmd.ctx = ctx
    return cmd
end

--- Sets the command to launch with a different pgid.
-- @param status True if diff pgid desired.
function Cmd:setpgid(status)
    self._setpgid = status
end

--- Launches the command.
-- @param path The path to the executable.
-- @param argt Table of arguments.
-- @return pid, cmd_streams, result_channel, error
function Cmd:launch(path, argt)
    -- Check if the executable exists and is executable
    local status, errstr, _ = sc.access(path, "x")
    if not status then return errstr end

    self.pipes.child.stdin, self.pipes.child_cmd.stdin = assert(sc.pipe())
    self.pipes.child_cmd.stdout, self.pipes.child.stdout = assert(sc.pipe())
    self.pipes.child_cmd.stderr, self.pipes.child.stderr = assert(sc.pipe())

    local ready_read, ready_write = assert(sc.pipe())
    ready_read = file.fdopen(ready_read)

    self.process.pid = assert(sc.fork())
    if self.process.pid == 0 then -- child
        if self._setpgid then
            local result, err_msg = sc.setpid('p', 0, 0)
            assert(result==0, err_msg)
        end
        -- close all the parent pipes
        close_all(self.pipes.ext, self.pipes.ext_cmd, self.pipes.child_cmd)
        ready_read:close()

        sc.dup2(self.pipes.child.stdin, sc.STDIN_FILENO)
        sc.dup2(self.pipes.child.stdout, sc.STDOUT_FILENO)
        sc.dup2(self.pipes.child.stderr, sc.STDERR_FILENO)

        close_all(self.pipes.child)

        sc.close(ready_write)

        local _, err, errno = sc.exec(path, argt) -- will not return unless unsuccessful
        if err then
            io.stderr:write(err .. "\n") -- will be sent over the stderr pipe
            sc.exit(errno) -- exit with non-zero status
        end
    end
    -- parent
    close_all(self.pipes.child)

    sc.close(ready_write)
    ready_read:read_some_chars()
    ready_read:close()

    local pidfd, err = sc.pidfd_open(self.process.pid, 0)
    self.process.pidfd = assert(pidfd, err)

    for k, v in pairs(self.pipes.child_cmd) do
        self.pipes.child_cmd[k] = file.fdopen(v)
    end

    self.pipes.child_cmd.stdin:setvbuf('no')

    return nil
end

--- Gets the combined output of stdout and stderr.
-- @return The combined output and any error.
function Cmd:combined_output()
    local buf = string_buffer.new()
    self.pipes.ext_cmd.stdout, self.pipes.ext_cmd.stderr = buf, buf
    local err = self:run()
    if err then return buf:read(), err end
    return buf:read(), nil
end

--- Gets the output of stdout.
-- @return The output and any error.
function Cmd:output()
    local buf = string_buffer.new()
    self.pipes.ext_cmd.stdout = buf
    local err = self:run()
    if err then return buf:read(), err end
    return buf:read(), nil
end

--- Starts the command and waits for it to complete.
-- @return Any error.
function Cmd:run()
    local err = self:start()
    if err then
        close_all(self.pipes.ext_cmd, self.pipes.child_cmd)
        return err
    end
    return self:wait()
end

--- Starts the command.
-- @return Any error.
function Cmd:start()
    if self.process.pid then return "process already started" end

    if self.ctx and self.ctx:err() then
        close_all(self.pipes.ext_cmd)
        return "context already complete"
    end

    local executable_path
    -- Check if a path is provided
    if self.path:find("/") then
        executable_path = self.path
    else
        -- Search for the executable in the PATH
        for dir in os.getenv("PATH"):gmatch("[^:]+") do
            local full_path = dir .. "/" .. self.path
            if sc.access(full_path, "x") then
                executable_path = full_path
                break
            end
        end
        if not executable_path then
            close_all(self.pipes.ext_cmd)
            return '"'..self.path..'": executable file not found in $PATH'
        end
    end

    local err = self:launch(executable_path, self.args)
    if err then
        close_all(self.pipes.ext_cmd, self.pipes.child_cmd, self.pipes.child)
        return err
    end

    for _, v in ipairs(io_names) do
        self.pipes.wg:add(1)
        if not self.pipes.ext_cmd[v] then
            self.pipes.ext_cmd[v] = assert(file.open("/dev/null", v == "stdin" and "r" or "w"))
        end
        local input = v=="stdin" and self.pipes.ext_cmd[v] or self.pipes.child_cmd[v]
        local output = v=="stdin" and self.pipes.child_cmd[v] or self.pipes.ext_cmd[v]
        fiber.spawn(function()
            while true do
                local received = input:read_some_chars()
                output:write(received)
                if not received then break end
            end
            if input.close then input:close() end
            if output.close then output:close() end
            self.pipes.ext_cmd[v], self.pipes.child_cmd[v] = nil, nil
            self.pipes.wg:done()
        end)
    end

    -- Setup a new fiber to listen for context cancellation or command completion
    if self.ctx then
        fiber.spawn(function()
            op.choice(
                self.ctx:done_op():wrap(function () -- Context was cancelled, kill the command
                    self:kill()
                end),
                pollio.fd_readable_op(self.process.pidfd) -- Command has completed, we just may not have waited yet
            ):perform()
        end)
    end
end

--- Kills the command.
-- @return Any error.
function Cmd:kill()
    if not self.process.pid then return "process not started" end
    if self.process.state then return "process has already completed" end

    local res, err, errno = sc.kill(self._setpgid and -self.process.pid or self.process.pid, sc.SIGKILL)
    assert(res==0 or errno==sc.ESRCH, err)
end

--- Sets up a pipe for the given IO type.
-- @param io_type The type of IO ("stdin", "stdout", or "stderr").
-- @return The pipe or an error.
local function setup_pipe(self, io_type)
    if self.pipes.ext_cmd[io_type] then return nil, io_type .. " pipe already created" end
    if self.process.pid then return nil, io_type .. "_pipe after process started" end

    local rd, wr = file.pipe()
    wr = wr:setvbuf('no')

    local cmd_end, ext_end = wr, rd

    if io_type == "stdin" then
        cmd_end, ext_end = rd, wr
    end

    self.pipes.ext_cmd[io_type] = cmd_end
    self.pipes.ext[io_type] = ext_end

    return ext_end, nil
end

--- Creates a pipe for stdout. Call `:close()` when finished.
-- @return The stdout pipe or an error.
function Cmd:stdout_pipe() return setup_pipe(self, "stdout") end

--- Creates a pipe for stderr. Call `:close()` when finished.
-- @return The stderr pipe or an error.
function Cmd:stderr_pipe() return setup_pipe(self, "stderr") end

--- Creates a pipe for stdin. Call `:close()` when finished.
-- @return The stdin pipe or an error.
function Cmd:stdin_pipe() return setup_pipe(self, "stdin") end


--- Waits for the command to complete.
-- @return The completion status or an error.
function Cmd:wait()
    pollio.fd_readable_op(self.process.pidfd):perform()
    self.pipes.wg:wait()
    local _, _, status = sc.waitpid(self.process.pid)
    self.process.state = status
    sc.close(self.process.pidfd)
    close_all(self.pipes.child, self.pipes.child_cmd, self.pipes.ext_cmd)
    if status ~= 0 then return status end
end

return {
    command = command,
    command_context = command_context
}
