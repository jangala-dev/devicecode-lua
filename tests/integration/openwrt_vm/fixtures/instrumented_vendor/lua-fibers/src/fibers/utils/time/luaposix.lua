-- fibers/utils/time/luaposix.lua
--
-- Time backend using posix.time (clock_gettime/nanosleep) and posix.unistd.
--
---@module 'fibers.utils.time.luaposix'

local core = require 'fibers.utils.time.core'

local ok_time, ptime = pcall(require, 'posix.time')
if not ok_time or type(ptime) ~= 'table' then
	return { is_supported = function () return false end }
end

local ok_unistd, unistd = pcall(require, 'posix.unistd')
if not ok_unistd or type(unistd) ~= 'table' then
	return { is_supported = function () return false end }
end

local errno = require 'posix.errno'

local CLOCK_REALTIME  = ptime.CLOCK_REALTIME
local CLOCK_MONOTONIC = ptime.CLOCK_MONOTONIC

if not CLOCK_REALTIME or not CLOCK_MONOTONIC then
	return { is_supported = function () return false end }
end

----------------------------------------------------------------------
-- Helpers
----------------------------------------------------------------------

local function ts_to_seconds(ts)
	return ts.tv_sec + ts.tv_nsec * 1e-9
end

local function read_clock(clk_id)
	local ts, err = ptime.clock_gettime(clk_id)
	if not ts then
		error('clock_gettime failed: ' .. tostring(err))
	end
	return ts_to_seconds(ts)
end

local function clock_resolution(clk_id)
	if type(ptime.clock_getres) == 'function' then
		local ts = select(1, ptime.clock_getres(clk_id))
		if ts then
			return ts_to_seconds(ts)
		end
	end
	-- Fallback if clock_getres is missing or fails.
	return 1e-3
end

----------------------------------------------------------------------
-- Blocking sleep
----------------------------------------------------------------------

local function _block(dt)
	if dt <= 0 then
		return true, nil
	end

	local sec  = math.floor(dt)
	local frac = dt - sec
	local nsec = math.floor(frac * 1e9 + 0.5)
	if nsec >= 1000000000 then
		sec  = sec + 1
		nsec = nsec - 1000000000
	end

	local req = { tv_sec = sec, tv_nsec = nsec }

	while true do
		local ok, err, eno, rem = ptime.nanosleep(req)
		if ok then
			return true, nil
		end
		if eno == errno.EINTR and rem then
			-- Interrupted; continue with remaining time.
			req = rem
		else
			return false, err or ('nanosleep failed (errno ' .. tostring(eno) .. ')')
		end
	end
end

----------------------------------------------------------------------
-- Metadata and support
----------------------------------------------------------------------

local realtime_res  = clock_resolution(CLOCK_REALTIME)
local monotonic_res = clock_resolution(CLOCK_MONOTONIC)

local function is_supported()
	local ok = pcall(function ()
		read_clock(CLOCK_MONOTONIC)
	end)
	return ok
end

local ops = {
	realtime = function ()
		return read_clock(CLOCK_REALTIME)
	end,

	monotonic = function ()
		return read_clock(CLOCK_MONOTONIC)
	end,

	realtime_info = {
		name       = 'posix.time.clock_gettime(CLOCK_REALTIME)',
		resolution = realtime_res,
		monotonic  = false,
		epoch      = 'unix',
	},

	monotonic_info = {
		name       = 'posix.time.clock_gettime(CLOCK_MONOTONIC)',
		resolution = monotonic_res,
		monotonic  = true,
		epoch      = 'unspecified',
	},

	_block = _block,

	block_info = {
		name       = 'posix.time.nanosleep',
		resolution = monotonic_res,
		clock      = 'monotonic',
	},

	is_supported = is_supported,
}


return core.build_backend(ops)
