-- tests/support/pty.lua

local posix  = require 'posix'
local file   = require 'fibers.io.file'
local exec   = require 'fibers.io.exec'
local fibers = require 'fibers'
local sleep  = require 'fibers.sleep'
local op     = require 'fibers.op'
local safe   = require 'coxpcall'

local perform = fibers.perform
local M = {}

local function close_fd(fd)
	local fn = posix.close
	if type(fn) ~= 'function' then
		local ok, unistd = pcall(require, 'posix.unistd')
		if ok and type(unistd.close) == 'function' then
			fn = unistd.close
		end
	end
	if type(fn) == 'function' and fd ~= nil then
		pcall(function() fn(fd) end)
	end
end

local function close_stream_best_effort(stream)
	if not (stream and stream.close_op) then
		return true, nil
	end

	local ok, a, b = safe.pcall(function()
		return perform(stream:close_op())
	end)
	if not ok then
		return nil, tostring(a)
	end
	return a, b
end

local function wait_read_some(stream, max_n, timeout_s)
	local which, a, b = perform(op.named_choice({
		data = stream:read_some_op(max_n),
		timeout = sleep.sleep_op(timeout_s or 1.0):wrap(function()
			return true
		end),
	}))

	if which == 'timeout' then
		return nil, 'timeout'
	end

	return a, b
end

local function write_all(stream, data)
	local off = 1
	while off <= #data do
		local n, err = perform(stream:write_op(data:sub(off)))
		if n == nil then
			return nil, err
		end
		off = off + n
	end
	return true, nil
end

local function read_exact(stream, nbytes, timeout_s)
	local deadline = fibers.now() + (timeout_s or 1.0)
	local parts = {}
	local got = 0

	while got < nbytes do
		local remain = deadline - fibers.now()
		if remain <= 0 then
			return nil, 'timeout'
		end

		local chunk, err = wait_read_some(stream, nbytes - got, remain)
		if chunk == nil then
			return nil, err
		end

		parts[#parts + 1] = chunk
		got = got + #chunk
	end

	return table.concat(parts), nil
end

local function stty_raw_noecho(path)
	local cmd = exec.command('stty', '-F', tostring(path), 'raw', '-echo')
	local out, st, code, sig, err = perform(cmd:combined_output_op())

	if st == 'exited' and code == 0 then
		return true, nil
	end

	local detail = err or out or ('status=' .. tostring(st))
	if st == 'exited' then
		detail = tostring(detail) .. ' (exit ' .. tostring(code) .. ')'
	elseif st == 'signalled' then
		detail = tostring(detail) .. ' (signal ' .. tostring(sig) .. ')'
	end
	return nil, detail
end

---@class TestPTY
---@field master Stream
---@field slave_name string
---@field _anchor_fd integer|nil
local PTY = {}
PTY.__index = PTY

function PTY:write(data)
	local ok, err = write_all(self.master, data)
	if ok ~= true then
		return nil, err
	end
	return true, nil
end

function PTY:read_some(max_n, timeout_s)
	return wait_read_some(self.master, max_n, timeout_s)
end

function PTY:expect_some(max_n, timeout_s, label)
	local data, err = self:read_some(max_n, timeout_s)
	if data == nil then
		error(('%s timed out: %s'):format(label or 'PTY read', tostring(err)), 0)
	end
	return data
end

function PTY:expect_exact(nbytes, timeout_s, label)
	local data, err = read_exact(self.master, nbytes, timeout_s)
	if data == nil then
		error(('%s timed out: %s'):format(label or 'PTY read exact', tostring(err)), 0)
	end
	return data
end

function PTY:expect_no_data(timeout_s, label)
	local data, _err = self:read_some(4096, timeout_s or 0.10)
	if data ~= nil then
		error(('%s unexpectedly received data: %q'):format(label or 'PTY read', tostring(data)), 0)
	end
	return true
end

function PTY:close()
	if self.master then
		close_stream_best_effort(self.master)
		self.master = nil
	end

	if self._anchor_fd ~= nil then
		close_fd(self._anchor_fd)
		self._anchor_fd = nil
	end

	return true
end

---@param scope Scope|nil
---@return TestPTY
function M.open(scope)
	local master_fd, slave_fd, slave_name, err = posix.openpty()
	if not master_fd then
		error('openpty failed: ' .. tostring(slave_fd or err), 0)
	end

	-- Put the slave side into raw/noecho mode up front so code under test
	-- that opens slave_name directly sees predictable byte-stream behaviour.
	local ok_raw, err_raw = stty_raw_noecho(slave_name)
	if ok_raw ~= true then
		close_fd(master_fd)
		close_fd(slave_fd)
		error('failed to configure PTY slave raw mode: ' .. tostring(err_raw), 0)
	end

	local master = file.fdopen(master_fd, 'r+', 'pty-master:' .. tostring(slave_name))
	master:setvbuf('no')

	local rec = setmetatable({
		master     = master,
		slave_name = slave_name,
		_anchor_fd = slave_fd,
	}, PTY)

	if scope and scope.finally then
		scope:finally(function()
			rec:close()
		end)
	end

	return rec
end

function M.open_slave_stream(path, opts)
	opts = opts or {}

	if opts.raw ~= false then
		local ok, err = stty_raw_noecho(path)
		if ok ~= true then
			return nil, 'stty failed: ' .. tostring(err)
		end
	end

	local s, err = file.open(path, 'r+')
	if not s then
		return nil, err
	end

	pcall(function()
		if s.setvbuf then s:setvbuf('no') end
	end)

	return s, nil
end

function M.read_some(stream, max_n, timeout_s)
	return wait_read_some(stream, max_n, timeout_s)
end

function M.expect_some(stream, max_n, timeout_s, label)
	local data, err = wait_read_some(stream, max_n, timeout_s)
	if data == nil then
		error(('%s timed out: %s'):format(label or 'stream read', tostring(err)), 0)
	end
	return data
end

function M.expect_exact(stream, nbytes, timeout_s, label)
	local data, err = read_exact(stream, nbytes, timeout_s)
	if data == nil then
		error(('%s timed out: %s'):format(label or 'stream read exact', tostring(err)), 0)
	end
	return data
end

function M.expect_no_data(stream, timeout_s, label)
	local data, _err = wait_read_some(stream, 4096, timeout_s or 0.10)
	if data ~= nil then
		error(('%s unexpectedly received data: %q'):format(label or 'stream read', tostring(data)), 0)
	end
	return true
end

return M
