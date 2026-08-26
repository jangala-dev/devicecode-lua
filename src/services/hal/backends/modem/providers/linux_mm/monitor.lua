local exec = require "fibers.io.exec"
local op = require "fibers.op"
local modem_types = require "services.hal.types.modem"
local process_flags = require "services.hal.backends.modem.process_flags"

local function terminate_command(cmd, sig)
	if not cmd or type(cmd.kill) ~= 'function' then return true, nil end
	local ok, a, b = pcall(function() return cmd:kill(sig or 15) end)
	if not ok then return nil, tostring(a) end
	if a == false or a == nil then return nil, tostring(b or 'command kill failed') end
	return true, nil
end

---@class ModemMonitor
---@field cmd Command
---@field stream any
local ModemMonitor = {}
ModemMonitor.__index = ModemMonitor

--- Parse one line from `mmcli -M` output into a ModemMonitorEvent.
--- Returns (nil, "Command closed") when the stream yields nil (end of stream).
--- Returns (nil, error) for lines that cannot be parsed.
---@param line string?
---@return ModemMonitorEvent?
---@return string error
local function parse_monitor_line(line)
	if not line then
		return nil, "Command closed"
	end

	local status, address = line:match("^(.-)(/org%S+)")
	if not address then
		return nil, "line could not be parsed: " .. tostring(line)
	end

	local is_added = not status:match("-")
	local event, err = modem_types.new.ModemMonitorEvent(is_added, address)
	if not event then
		return nil, "failed to create monitor event: " .. tostring(err)
	end

	return event, ""
end

--- Returns an Op that when performed yields the next ModemMonitorEvent.
--- (nil, "Command closed") signals end of stream.
--- (nil, error) signals an unparseable line — the caller should continue looping.
---@return Op
function ModemMonitor:next_event_op()
	return op.guard(function()
		return self.stream:read_line_op():wrap(parse_monitor_line)
	end)
end

---Best-effort non-blocking teardown for scope finalisers.
---@param reason string?
function ModemMonitor:terminate(reason)
	reason = reason or "modem_monitor_terminated"

	if self.stream then
		pcall(function() self.stream:terminate(reason) end)
	end

	if self.cmd then
		terminate_command(self.cmd, 15)
	end

	self.stream = nil
	self.cmd = nil
end

---@param timeout number?
---@return Op
function ModemMonitor:shutdown_op(timeout)
	return op.guard(function()
		if self.stream then
			pcall(function() self.stream:terminate("modem_monitor_stop") end)
		end

		local cmd = self.cmd
		self.cmd = nil
		self.stream = nil

		if not cmd then
			return op.always(true, "")
		end

		return cmd:shutdown_op(timeout or 1.0):wrap(function(status, _code, _sig, err)
			if status == "exited" or status == "signalled" then
				return true, ""
			end
			return false, err or ("modem monitor shutdown failed: " .. tostring(status))
		end)
	end)
end

--- Create and start a new ModemMonitor backed by `mmcli -M`.
---@return ModemMonitor? monitor
---@return string error
local function new()
	local cmd = exec.command {
		"mmcli", "-M",
		stdin = "null",
		stdout = "pipe",
		stderr = "stdout",
		flags = process_flags.owned_monitor_flags(),
	}
	local stream, err = cmd:stdout_stream()
	if not stream then
		return nil, "failed to start modem monitor: " .. tostring(err)
	end
	return setmetatable({ cmd = cmd, stream = stream }, ModemMonitor), ""
end

return {
	new = new,
}
