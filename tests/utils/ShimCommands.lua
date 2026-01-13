local channel = require 'fibers.channel'
local context = require 'fibers.context'
local op = require 'fibers.op'
local unpack = table.unpack or unpack
local dispatcher = require 'tests.utils.dispatcher'

local COMMAND_STATE = {
    CREATED = 'created',
    STARTED = 'started',
    FLUSHED = 'flushed',
    KILLED = 'killed'
}

local Pipe = {}
Pipe.__index = Pipe

function Pipe:read_line_op()
    return self.ch:get_op()
end

function Pipe:close()
    self.parent_cmd.calls.close = self.parent_cmd.calls.close + 1
end

local function new_pipe(parent_cmd, ch)
    local self = {
        parent_cmd = parent_cmd,
        ch = ch
    }
    return setmetatable(self, Pipe)
end

local Command = {}
Command.__index = Command

local function new_command(ctx, static_returns)
    local self = {
        ctx = context.with_cancel(ctx),
        stdout_ch = channel.new(),
        calls = {
            setprdeathsig = 0,
            setpgid = 0,
            start = 0,
            run = 0,
            wait = 0,
            kill = 0,
            close = 0,
        },
        static_returns = static_returns or {},
    }
    return setmetatable(self, Command)
end

function Command:start()
    self.calls.start = self.calls.start + 1
    if self.static_returns.start then
        return unpack(self.static_returns.start)
    end
end

function Command:setprdeathsig(sig)
    self.calls.setprdeathsig = self.calls.setprdeathsig + 1
    if self.static_returns.setprdeathsig then
        return unpack(self.static_returns.setprdeathsig)
    end
end

function Command:setpgid()
    self.calls.setpgid = self.calls.setpgid + 1
    if self.static_returns.setpgid then
        return unpack(self.static_returns.setpgid)
    end
end

function Command:stdout_pipe()
    return new_pipe(self, self.stdout_ch)
end

function Command:combined_output()
    local out_pipe = self:stdout_pipe()

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
            out_pipe:read_line_op()
        ):wrap(push_data)
        op.choice(
            read_op,
            self.ctx:done_op()
        ):perform()
    end

    return buf, nil
end

function Command:run()
    self.calls.run = self.calls.run + 1
    if self.static_returns.run then
        return unpack(self.static_returns.run)
    end
end

function Command:wait()
    self.calls.wait = self.calls.wait + 1
    if self.static_returns.wait then
        return unpack(self.static_returns.wait)
    end
end

function Command:kill()
    self.ctx:cancel('killed')
    self.calls.kill = self.calls.kill + 1
    if self.static_returns.kill then
        return unpack(self.static_returns.kill)
    end
end

-- function Command:close()
--     self.ctx:cancel('ended')
--     self.calls.close = self.calls.close + 1
--     if self.static_returns.close then
--         return unpack(self.static_returns.close)
--     end
-- end

return {
    new_command = new_command
}
