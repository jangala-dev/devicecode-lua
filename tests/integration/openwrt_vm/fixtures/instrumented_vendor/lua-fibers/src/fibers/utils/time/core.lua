-- fibers/utils/time/core.lua
--
-- Core glue for time backends.
--
---@class TimeSourceInfo
---@field name string
---@field resolution number
---@field monotonic boolean
---@field epoch string|nil

---@class TimeSleepInfo
---@field name string
---@field resolution number
---@field clock "realtime"|"monotonic"|string

---@class TimeOps
---@field realtime       fun(): number
---@field monotonic      fun(): number
---@field realtime_info  TimeSourceInfo
---@field monotonic_info TimeSourceInfo
---@field _block         fun(dt: number): boolean, string|nil
---@field block_info     TimeSleepInfo
---@field is_supported   fun(): boolean|nil  -- optional

local function build_backend(ops)
	assert(type(ops) == 'table', 'time backend ops must be a table')
	assert(type(ops.realtime) == 'function', 'time ops.realtime must be a function')
	assert(type(ops.monotonic) == 'function', 'time ops.monotonic must be a function')
	assert(type(ops._block) == 'function', 'time ops._block must be a function')
	assert(type(ops.realtime_info) == 'table', 'time ops.realtime_info must be a table')
	assert(type(ops.monotonic_info) == 'table', 'time ops.monotonic_info must be a table')
	assert(type(ops.block_info) == 'table', 'time ops.block_info must be a table')

	local function realtime()
		return ops.realtime()
	end

	local function monotonic()
		return ops.monotonic()
	end

	local function block(dt)
		assert(type(dt) == 'number' and dt >= 0, 'block: dt must be a non-negative number')
		return ops._block(dt)
	end

	local function info()
		return {
			realtime  = ops.realtime_info,
			monotonic = ops.monotonic_info,
			sleep     = ops.block_info,
		}
	end

	local function realtime_source()
		return ops.realtime_info
	end

	local function monotonic_source()
		return ops.monotonic_info
	end

	local function block_source()
		return ops.block_info
	end

	local function is_supported()
		if type(ops.is_supported) == 'function' then
			return not not ops.is_supported()
		end
		return true
	end

	return {
		realtime         = realtime,
		monotonic        = monotonic,
		_block           = block,
		info             = info,
		realtime_source  = realtime_source,
		monotonic_source = monotonic_source,
		block_source     = block_source,
		is_supported     = is_supported,
	}
end

return {
	build_backend = build_backend,
}
