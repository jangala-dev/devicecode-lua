-- fibers/utils/time/ffi.lua
--
-- Time backend using clock_gettime(2) and nanosleep(2) via ffi_compat.
-- Linux-oriented; requires fibers.utils.ffi_compat.
--
---@module 'fibers.utils.time.ffi'

local core  = require 'fibers.utils.time.core'
local ffi_c = require 'fibers.utils.ffi_compat'

if not (ffi_c.is_supported and ffi_c.is_supported()) then
	return { is_supported = function () return false end }
end

local ffi       = ffi_c.ffi
local C         = ffi_c.C
local toint     = ffi_c.tonumber
local get_errno = ffi_c.errno

ffi.cdef [[
  typedef long time_t;
  typedef long suseconds_t;

  struct timespec {
    time_t tv_sec;
    long   tv_nsec;
  };

  int clock_gettime(int clk_id, struct timespec *tp);
  int clock_getres(int clk_id, struct timespec *tp);
  int nanosleep(const struct timespec *req, struct timespec *rem);
  char *strerror(int errnum);
]]

-- Linux/glibc constants.
local CLOCK_REALTIME  = 0
local CLOCK_MONOTONIC = 1

local EINTR = 4

----------------------------------------------------------------------
-- Helpers
----------------------------------------------------------------------

local function strerror(e)
	local s = C.strerror(e)
	if s == nil then
		return 'errno ' .. tostring(e)
	end
	return ffi.string(s)
end

local function ts_to_seconds(ts)
	return tonumber(ts.tv_sec) + tonumber(ts.tv_nsec) * 1e-9
end

local function read_clock(clk_id)
	local ts = ffi.new('struct timespec[1]')
	local rc = toint(C.clock_gettime(clk_id, ts))
	if rc ~= 0 then
		local e = get_errno()
		error('clock_gettime failed: ' .. strerror(e))
	end
	return ts_to_seconds(ts[0])
end

local function clock_resolution(clk_id)
	local ts = ffi.new('struct timespec[1]')
	local rc = toint(C.clock_getres(clk_id, ts))
	if rc ~= 0 then
		-- Fall back to a conservative default (1 ms) if the query fails.
		return 1e-3
	end
	return ts_to_seconds(ts[0])
end

----------------------------------------------------------------------
-- Blocking sleep
----------------------------------------------------------------------

local function _block(dt)
	if dt <= 0 then
		return true, nil
	end

	local req = ffi.new('struct timespec[1]')
	local rem = ffi.new('struct timespec[1]')

	local sec  = math.floor(dt)
	local frac = dt - sec
	local nsec = math.floor(frac * 1e9 + 0.5)
	if nsec >= 1000000000 then
		sec  = sec + 1
		nsec = nsec - 1000000000
	end

	req[0].tv_sec  = sec
	req[0].tv_nsec = nsec

	while true do
		local rc = toint(C.nanosleep(req, rem))
		if rc == 0 then
			return true, nil
		end
		local e = get_errno()
		if e == EINTR then
			-- Interrupted; continue with remaining time.
			req[0].tv_sec  = rem[0].tv_sec
			req[0].tv_nsec = rem[0].tv_nsec
		else
			return false, 'nanosleep failed: ' .. strerror(e)
		end
	end
end

----------------------------------------------------------------------
-- Metadata and support
----------------------------------------------------------------------

local realtime_res  = clock_resolution(CLOCK_REALTIME)
local monotonic_res = clock_resolution(CLOCK_MONOTONIC)

local function is_supported()
	-- Probe both clocks once; treat errors as lack of support.
	local ok = pcall(function ()
		read_clock(CLOCK_REALTIME)
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
		name       = 'clock_gettime(CLOCK_REALTIME)',
		resolution = realtime_res,
		monotonic  = false,
		epoch      = 'unix',
	},

	monotonic_info = {
		name       = 'clock_gettime(CLOCK_MONOTONIC)',
		resolution = monotonic_res,
		monotonic  = true,
		epoch      = 'unspecified',
	},

	_block = _block,

	block_info = {
		name       = 'nanosleep',
		resolution = monotonic_res,
		clock      = 'monotonic',
	},

	is_supported = is_supported,
}


return core.build_backend(ops)
