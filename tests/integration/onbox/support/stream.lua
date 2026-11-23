local fiber_runtime = require 'onbox.support.fiber_runtime'
local process = require 'onbox.support.process'

local M = {}
local Stream = {}
Stream.__index = Stream

-- Preserve partial lines across SSH reads. The raw capture includes original line endings.
function M.lines(on_line)
	local pending = ''
	return function(chunk)
		if not chunk then
			assert(pending == '', 'Stream ended in the middle of a line')
			return
		end
		local content, from = pending .. chunk, 1
		while true do
			local newline = content:find('\n', from, true)
			if not newline then break end
			assert(newline - from <= 1024 * 1024, 'Stream line exceeds 1 MiB')
			on_line((content:sub(from, newline - 1):gsub('\r$', '')))
			from = newline + 1
		end
		pending = content:sub(from)
		assert(#pending <= 1024 * 1024, 'Stream line exceeds 1 MiB')
	end
end

function M.open(ssh, commands, command, path, on_line)
	local f = fiber_runtime.get()
	local stream = setmetatable({ pulse = require('fibers.pulse').new(), commands = commands,
		path = path }, Stream)
	stream.pid = ssh:start(command, path, true)
	local reader, sink = commands:stream_handles(stream.pid)
	local feed = M.lines(function(line)
		local changed = on_line(line)
		if changed ~= false then stream.pulse:signal() end
	end)
	assert(f.fibers.spawn(function()
		local ok, err = pcall(function()
			while true do
				local chunk, read_err = f.fibers.perform(reader:read_some_op(8192))
				assert(not read_err, read_err)
				if not chunk then feed(); return end
				local written, write_err = f.fibers.perform(sink:write_op(chunk))
				assert(written == #chunk, write_err or 'Short write to stream artifact')
				local flushed, flush_err = f.fibers.perform(sink:flush_op())
				assert(flushed, flush_err)
				feed(chunk)
			end
		end)
		stream.pulse:close(ok and 'unexpected EOF' or tostring(err))
	end))
	return stream
end

function Stream:version()
	return self.pulse:version()
end

function Stream:assert_open()
	if self.pulse:is_closed() then
		error(self.path .. ': ' .. tostring(self.pulse:why()) .. ' (see .stderr)', 0)
	end
end

function Stream:wait_change(version, deadline)
	local f = fiber_runtime.get()
	local which, next_version, err = f.fibers.perform(f.op.named_choice({
		change = self.pulse:changed_op(version),
		timeout = f.sleep.sleep_op(math.max(0, deadline - process.now())),
	}))
	if which == 'timeout' then return false end
	if not next_version then return nil, self.path .. ': ' .. tostring(err) .. ' (see .stderr)' end
	return true
end

function Stream:wait_for(label, deadline, check)
	local failure
	local timeout = 'Timed out waiting for ' .. label .. ' (see ' .. self.path .. ')'
	while true do
		local seen = self:version()
		local value = check()
		if value then return value end
		if failure then error(failure, 0) end
		if process.now() >= deadline then error(timeout, 0) end
		local _, err = self:wait_change(seen, deadline)
		-- A final line can satisfy the check just before the reader posts EOF.
		-- Check the clock again if the scheduler wakes before the deadline.
		if err then failure = err end
	end
end

function Stream:close()
	self.commands:stop(self.pid)
end

return M
