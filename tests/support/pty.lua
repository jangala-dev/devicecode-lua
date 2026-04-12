-- tests/support/pty.lua
--
-- PTY helpers for devhost integration tests.
--
-- Goals:
--   * stay inside fibers where practical
--   * expose PTY masters as real fibers Streams
--   * provide bounded raw-byte reads
--   * provide a simple cross-wire bridge for two PTYs
--   * provide a slave-side round-trip smoke test
--
-- Important behaviour:
--   * the bridge is tolerant of transient PTY conditions while one slave side
--     is not yet opened by HAL
--   * it does not tear the whole bridge down on a temporary read/write error
--   * each PTY keeps an internal slave-anchor fd open so the master side does
--     not observe "no slave attached yet" during bridge startup

local posix  = require 'posix'
local file   = require 'fibers.io.file'
local exec   = require 'fibers.io.exec'
local fibers = require 'fibers'
local sleep  = require 'fibers.sleep'
local op     = require 'fibers.op'

local perform = fibers.perform

local M = {}

local BRIDGE_RETRY_S = 0.01

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
		if n == 0 then
			sleep.sleep(BRIDGE_RETRY_S)
		else
			off = off + n
		end
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

function PTY:expect_no_data(timeout_s, label)
	local data, _err = self:read_some(4096, timeout_s or 0.10)
	if data ~= nil then
		error(('%s unexpectedly received data: %q'):format(label or 'PTY read', tostring(data)), 0)
	end
	return true
end

function PTY:close()
	if self.master then
		pcall(function() perform(self.master:close_op()) end)
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

	local master = file.fdopen(master_fd, 'r+', 'pty-master:' .. tostring(slave_name))
	master:setvbuf('no')

	-- Keep the slave fd open as an internal anchor until PTY:close().
	-- This prevents the master side from seeing a transient "no slave attached"
	-- condition before HAL opens the real slave path.
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

function M.expect_no_data(stream, timeout_s, label)
	local data, _err = wait_read_some(stream, 4096, timeout_s or 0.10)
	if data ~= nil then
		error(('%s unexpectedly received data: %q'):format(label or 'stream read', tostring(data)), 0)
	end
	return true
end

function M.expect_exact(stream, nbytes, timeout_s, label)
	local data, err = read_exact(stream, nbytes, timeout_s)
	if data == nil then
		error(('%s timed out: %s'):format(label or 'stream read exact', tostring(err)), 0)
	end
	return data
end

function M.preflight_bridge_pair(scope, left, right, opts)
	opts = opts or {}

	local timeout_s = opts.timeout_s or 1.0
	local bytes_ab = opts.bytes_ab or '\001preflight-a-to-b\002'
	local bytes_ba = opts.bytes_ba or '\003preflight-b-to-a\004'

	local left_slave, lerr = M.open_slave_stream(left.slave_name, { raw = true })
	if not left_slave then
		error('failed to open left PTY slave: ' .. tostring(lerr), 0)
	end

	local right_slave, rerr = M.open_slave_stream(right.slave_name, { raw = true })
	if not right_slave then
		pcall(function() perform(left_slave:close_op()) end)
		error('failed to open right PTY slave: ' .. tostring(rerr), 0)
	end

	if scope and scope.finally then
		scope:finally(function()
			pcall(function() perform(left_slave:close_op()) end)
			pcall(function() perform(right_slave:close_op()) end)
		end)
	end

	local ok, err = write_all(left_slave, bytes_ab)
	if ok ~= true then
		error('PTY preflight write A->B failed: ' .. tostring(err), 0)
	end

	local got_ab = M.expect_exact(right_slave, #bytes_ab, timeout_s, 'PTY preflight read A->B')
	if got_ab ~= bytes_ab then
		error(
			('PTY preflight mismatch A->B: expected %q got %q')
				:format(bytes_ab, tostring(got_ab)),
			0
		)
	end

	ok, err = write_all(right_slave, bytes_ba)
	if ok ~= true then
		error('PTY preflight write B->A failed: ' .. tostring(err), 0)
	end

	local got_ba = M.expect_exact(left_slave, #bytes_ba, timeout_s, 'PTY preflight read B->A')
	if got_ba ~= bytes_ba then
		error(
			('PTY preflight mismatch B->A: expected %q got %q')
				:format(bytes_ba, tostring(got_ba)),
			0
		)
	end

	pcall(function() perform(left_slave:close_op()) end)
	pcall(function() perform(right_slave:close_op()) end)

	return true
end

local function as_stream(x)
	if type(x) == 'table' and x.master ~= nil then
		return x.master
	end
	return x
end

local function bridge_one_way(src_stream, dst_stream)
	while true do
		local chunk, _err = perform(src_stream:read_some_op(4096))

		if chunk == nil then
			sleep.sleep(BRIDGE_RETRY_S)
		elseif #chunk == 0 then
			sleep.sleep(BRIDGE_RETRY_S)
		else
			local off = 1
			while off <= #chunk do
				local n, _werr = perform(dst_stream:write_op(chunk:sub(off)))
				if n == nil or n == 0 then
					sleep.sleep(BRIDGE_RETRY_S)
				else
					off = off + n
				end
			end
		end
	end
end

function M.bridge_pair(scope, left, right)
	local left_stream  = as_stream(left)
	local right_stream = as_stream(right)

	local ok1, err1 = scope:spawn(function()
		return bridge_one_way(left_stream, right_stream)
	end)
	assert(ok1, tostring(err1))

	local ok2, err2 = scope:spawn(function()
		return bridge_one_way(right_stream, left_stream)
	end)
	assert(ok2, tostring(err2))

	return true
end

return M
