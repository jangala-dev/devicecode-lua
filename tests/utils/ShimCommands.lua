local channel = require 'fibers.channel'
local context = require 'fibers.context'
local op = require 'fibers.op'

local COMMAND_STATE = {
    CREATED = 'created',
    STARTED = 'started',
    FLUSHED = 'flushed',
    KILLED = 'killed'
}

local Pipe = {}
Pipe.__index = Pipe

function Pipe:read_line_op()
    if not self.ch then
        error("attempt to read from closed pipe")
    end
    return self.ch:get_op()
end

function Pipe:close()
    -- In the real exec implementation, pipes can be closed
    -- independently of the process lifecycle. For the shim we
    -- therefore allow close() regardless of the parent command
    -- state and simply drop the underlying channel reference.
    self.ch = nil
end

local function new_pipe(parent_cmd)
    local self = {
        parent_cmd = parent_cmd,
        ch = channel.new()
    }
    return setmetatable(self, Pipe)
end

local Command = {}
Command.__index = Command

local function new_command()
    local self = {
        state = COMMAND_STATE.CREATED,
        ctx = context.with_cancel(context.background()),
        stdout = nil,
        stderr = nil,
        -- Optional lifecycle hooks used by test backends to
        -- trigger side-effects when commands are used.
        on_start = nil,
        on_kill = nil,
    }
    return setmetatable(self, Command)
end

function Command:start()
    self.state = COMMAND_STATE.STARTED
    if self.on_start then
        return self.on_start(self)
    end
    return nil
end

function Command:setprdeathsig(sig)
    -- pass
end

function Command:setpgid()
    -- pass
end

function Command:stdout_pipe()
    if not self.stdout then
        self.stdout = new_pipe(self)
    end
    return self.stdout
end

function Command:stderr_pipe()
    if not self.stderr then
        self.stderr = new_pipe(self)
    end
    return self.stderr
end

function Command:combined_output()
    local out_pipe = self:stdout_pipe()
    local err_pipe = self:stderr_pipe()

    -- In the real exec implementation, the process is started
    -- before output is read. Mirror that behaviour here so that
    -- any on_start side-effects are applied exactly once.
    if self.state == COMMAND_STATE.CREATED then
        local err = self:start()
        if err then
            return "", err
        end
    end

    local buf = ""
    local continue = true
    local function push_data(data)
        if data then
            buf = buf .. data
        else
            continue = false
        end
    end

    while continue and not self.ctx:err() do
        local read_op = op.choice(
            out_pipe:read_line_op(),
            err_pipe:read_line_op()
        ):wrap(push_data)
        op.choice(
            read_op,
            self.ctx:done_op()
        ):perform()
    end

    return buf, nil
end

function Command:run()
    -- Simplified exec-style run: ensure the command has started and
    -- propagate any start error. We do not currently accumulate
    -- stdout/stderr here as existing callers only check the error.
    if self.state == COMMAND_STATE.CREATED then
        local err = self:start()
        if err then
            self.state = COMMAND_STATE.FLUSHED
            return err
        end
    end
    self.state = COMMAND_STATE.FLUSHED
    return nil
end

function Command:wait()
    if self.state == COMMAND_STATE.KILLED then
        self.state = COMMAND_STATE.FLUSHED
    end
end

function Command:kill()
    self.ctx:cancel('killed')
    self.state = COMMAND_STATE.KILLED
    if self.on_kill then
        self.on_kill(self)
    end
end

function Command:close()
    self.ctx:cancel('ended')
end

function Command:write_out(data)
    if not self.stdout then
        return 'stdout pipe not set'
    end
    self.stdout.ch:put(data)
end

function Command:write_err(data)
    if not self.stderr then
        return 'stderr pipe not set'
    end
    self.stderr.ch:put(data)
end

local StaticCommand = {}
StaticCommand.__index = StaticCommand

local function new_static_command()
    local self = {
        bse_cmd = new_command(),
        out = "",
        err = "",
    }
    return setmetatable(self, StaticCommand)
end

function StaticCommand:start()
    return self.bse_cmd:start()
end

function StaticCommand:setprdeathsig(sig)
    return self.bse_cmd:setprdeathsig(sig)
end

function StaticCommand:setpgid()
    return self.bse_cmd:setpgid()
end

function StaticCommand:stdout_pipe()
    error("unimplemented")
end

function StaticCommand:stderr_pipe()
    error("unimplemented")
end

function StaticCommand:combined_output()
    return self.out  .. self.err
end

function StaticCommand:wait()
    return self.bse_cmd:wait()
end

function StaticCommand:kill()
    return self.bse_cmd:kill()
end

function StaticCommand:close()
    return self.bse_cmd:close()
end

function StaticCommand:write_out(data)
    self.out = data
end

function StaticCommand:write_err(data)
    self.err = data
end

local BroadcastCommand = {}
BroadcastCommand.__index = BroadcastCommand

function BroadcastCommand:new_child()
    local child = new_command()
    table.insert(self.children, child)
    return child
end

function BroadcastCommand:write_out(data)
    for _, child in ipairs(self.children) do
        local err = child:write_out(data)
        if err then
            return err
        end
    end
end

function BroadcastCommand:write_err(data)
    for _, child in ipairs(self.children) do
        local err = child:write_err(data)
        if err then
            return err
        end
    end
end

local function new_broadcast_command()
    local self = {
        children = {}
    }

    return setmetatable(self, BroadcastCommand)
end

return {
    new_broadcast_command = new_broadcast_command,
    new_static_command = new_static_command,
    new_command = new_command
}
