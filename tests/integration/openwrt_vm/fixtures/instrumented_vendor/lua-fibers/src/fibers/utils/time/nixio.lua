-- fibers/utils/time/nixio.lua
--
-- Time backend using nixio.gettime, nixio.nanosleep and /proc/uptime.
--
---@module 'fibers.utils.time.nixio'

local core = require 'fibers.utils.time.core'

local ok, nixio = pcall(require, 'nixio')
if not ok or type(nixio) ~= 'table' then
	return { is_supported = function () return false end }
end

----------------------------------------------------------------------
-- Monotonic time via /proc/uptime
----------------------------------------------------------------------

local UPTIME_PATH = '/proc/uptime'

--- Read the first field from /proc/uptime as a number.
---@return number|nil value, string|nil err
local function read_uptime()
	local f, err = io.open(UPTIME_PATH, 'r')
	if not f then
		return nil, ('failed to open %s: %s'):format(UPTIME_PATH, tostring(err))
	end

	local line = f:read('*l')
	f:close()

	if not line then
		return nil, ('failed to read %s: empty file'):format(UPTIME_PATH)
	end

	local first = line:match('^%s*(%S+)')
	if not first then
		return nil, ('failed to parse %s: no fields'):format(UPTIME_PATH)
	end

	local val = tonumber(first)
	if not val then
		return nil, ("failed to parse %s: non-numeric uptime '%s'"):format(
			UPTIME_PATH,
			tostring(first)
		)
	end

	return val, nil
end

-- Probe once at load time so metadata and is_supported() can report accurately.
local monotonic_ok
do
	local v = read_uptime()
	monotonic_ok = (v ~= nil)
end

----------------------------------------------------------------------
-- Core time functions
----------------------------------------------------------------------

--- Wall-clock time: seconds since Unix epoch as a Lua number.
local function realtime()
	-- nixio.gettime() already returns epoch seconds with fractional part.
	return nixio.gettime()
end

--- Monotonic time in seconds.
---
--- Primary source: /proc/uptime (seconds since boot, fractional).
--- If this fails at call time for any reason, fall back to
--- nixio.gettime() rather than raising; monotonic_info.name still
--- reflects /proc/uptime as the intended primary source.
local function monotonic()
	local v = read_uptime()
	if v ~= nil then
		return v
	end
	-- Degraded path: not truly monotonic, but avoids hard failure.
	return nixio.gettime()
end

----------------------------------------------------------------------
-- Blocking sleep
----------------------------------------------------------------------

---@param dt number
---@return boolean ok, string|nil err
local function _block(dt)
	if type(dt) ~= 'number' then
		return false, 'sleep: dt must be a number'
	end
	if dt <= 0 then
		return true, nil
	end

	local deadline = monotonic() + dt

	while true do
		local now       = monotonic()
		local remaining = deadline - now
		if remaining <= 0 then
			return true, nil
		end

		local secs = math.floor(remaining)
		if secs < 0 then secs = 0 end

		local frac = remaining - secs
		if frac < 0 then frac = 0 end
		local nsec = math.floor(frac * 1e9 + 0.5)

		-- nixio.nanosleep(seconds, nanoseconds)
		local ok_ns, err, eno = nixio.nanosleep(secs, nsec)
		if not ok_ns then
			local msg = tostring(err or eno or '')
			if msg ~= '' and msg ~= 'EINTR' then
				return false, ('nixio.nanosleep failed: %s'):format(msg)
			end
			-- EINTR or unknown soft error: loop again and recompute remaining.
		end
	end
end

----------------------------------------------------------------------
-- Metadata and support
----------------------------------------------------------------------

local function is_supported()
	-- Require: nixio present, gettime/nanosleep available, and /proc/uptime
	-- readable at initialisation.
	if type(nixio.gettime) ~= 'function' then
		return false
	end
	if type(nixio.nanosleep) ~= 'function' then
		return false
	end
	if not monotonic_ok then
		return false
	end
	return true
end

local ops = {
	realtime = realtime,

	monotonic = monotonic,

	realtime_info = {
		name       = 'nixio.gettime',
		resolution = 0.001, -- approximate; depends on platform
		monotonic  = false,
		epoch      = 'unix',
	},

	monotonic_info = {
		name       = '/proc/uptime',
		-- /proc/uptime is typically centisecond resolution.
		resolution = 0.01,
		monotonic  = true,
		epoch      = 'unspecified',
	},

	_block = _block,

	block_info = {
		name       = 'nixio.nanosleep',
		resolution = 0.001,
		clock      = 'monotonic',
	},

	is_supported = is_supported,
}


return core.build_backend(ops)
