-- fibers/utils/time/linux.lua
--
-- Pure Lua fallback time backend for Linux.
-- Monotonic time from /proc/uptime; blocking sleep via shell "sleep".
--
---@module 'fibers.utils.time.linux'

local core = require 'fibers.utils.time.core'

----------------------------------------------------------------------
-- Monotonic time: /proc/uptime
----------------------------------------------------------------------

local function read_uptime_raw()
	local f = io.open('/proc/uptime', 'r')
	if not f then
		return nil
	end
	local line = f:read('*l')
	f:close()
	if not line then
		return nil
	end
	local first = line:match('^(%S+)')
	return first
end

local function read_uptime()
	local token = read_uptime_raw()
	if not token then
		return nil
	end
	local v = tonumber(token)
	return v
end

-- Estimate resolution from the number of fractional digits in /proc/uptime.
local monotonic_resolution = 1.0
do
	local token = read_uptime_raw()
	if token then
		local frac = token:match('%.([0-9]+)')
		if frac and #frac > 0 then
			monotonic_resolution = 10 ^ (- #frac)
		end
	end
end

local function monotonic()
	local v = read_uptime()
	if not v then
		error('fallback monotonic: /proc/uptime not available')
	end
	return v
end

----------------------------------------------------------------------
-- Realtime: prefer luasocket.gettime, fall back to os.time
----------------------------------------------------------------------

local realtime_fn
local realtime_name
local realtime_resolution

do
	local ok, socket = pcall(require, 'socket')
	if ok and type(socket) == 'table' and type(socket.gettime) == 'function' then
		realtime_fn         = socket.gettime
		realtime_name       = 'socket.gettime'
		realtime_resolution = 1e-6 -- approximate; depends on platform
	else
		realtime_fn         = function () return os.time() end
		realtime_name       = 'os.time'
		realtime_resolution = 1.0
	end
end

local function realtime()
	return realtime_fn()
end

----------------------------------------------------------------------
-- Blocking sleep: shell "sleep", fractional if available
----------------------------------------------------------------------

local function command_succeeded(a, b, c)
	-- Lua 5.1: boolean, "exit"/"signal", code
	if a == true then
		return true
	end
	-- Lua 5.2+: numeric exit code
	if type(a) == 'number' then
		return a == 0
	end
	-- Some implementations: nil, "exit", code
	if a == nil and b == 'exit' then
		return c == 0
	end
	return false
end

local function run_sleep(arg)
	local cmd = 'sleep ' .. arg
	local a, b, c = os.execute(cmd)
	return command_succeeded(a, b, c)
end

local has_fractional_sleep
do
	local ok = run_sleep('0.01')
	has_fractional_sleep = ok
end

local function _block(dt)
	if dt <= 0 then
		return true, nil
	end

	if has_fractional_sleep then
		-- Round to centiseconds.
		local centis = math.max(1, math.floor(dt * 100 + 0.5))
		local arg    = string.format('%.2f', centis / 100.0)
		local ok     = run_sleep(arg)
		if not ok then
			-- As a last resort, busy-wait using monotonic time.
			local start = monotonic()
			while monotonic() - start < dt do end
			return true, 'sleep command failed; used busy-wait'
		end
		return true, nil
	else
		-- Integral seconds only; round up so we do not undersleep.
		local secs = math.ceil(dt)
		local ok   = run_sleep(tostring(secs))
		if not ok then
			local start = monotonic()
			while monotonic() - start < dt do end
			return true, 'sleep command failed; used busy-wait'
		end
		return true, nil
	end
end

----------------------------------------------------------------------
-- Capability and metadata
----------------------------------------------------------------------

local function is_supported()
	-- This backend is only considered usable if /proc/uptime exists.
	local f = io.open('/proc/uptime', 'r')
	if f then
		f:close()
		return true
	end
	return false
end

local ops = {
	realtime  = realtime,
	monotonic = monotonic,

	realtime_info = {
		name       = realtime_name,
		resolution = realtime_resolution,
		monotonic  = false,
		epoch      = 'unix',
	},

	monotonic_info = {
		name       = '/proc/uptime',
		resolution = monotonic_resolution,
		monotonic  = true,
		epoch      = 'unspecified',
	},

	_block = _block,

	block_info = {
		name       = has_fractional_sleep
			and 'sleep (shell, fractional)'
			or 'sleep (shell, integral)',
		resolution = has_fractional_sleep and 0.01 or 1.0,
		clock      = 'realtime',
	},

	is_supported = is_supported,
}

return core.build_backend(ops)
