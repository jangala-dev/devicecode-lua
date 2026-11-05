-- tests/unit/hal/platform_driver_spec.lua
--
-- Raspberry Pi firmware power flags read by the platform driver.

local fibers = require 'fibers'
local cache_mod = require 'shared.cache'
local cap_args = require 'services.hal.types.capability_args'
local platform = require 'services.hal.drivers.platform'

local T = {}

local function eq(a, b, msg)
	if a ~= b then error((msg or 'assertion failed') .. ': expected ' .. tostring(b) .. ', got ' .. tostring(a), 2) end
end

local function write(path, text)
	local f = assert(io.open(path, 'w'))
	f:write(text)
	f:close()
end

local function driver(paths)
	return setmetatable({ cache = cache_mod.new(), identity = {}, throttled_paths = paths }, platform.Driver)
end

local function get(drv, field, max_age)
	return drv:get(cap_args.new.PlatformGetOpts(field, max_age or 0))
end

function T.power_flags_decode_get_throttled_bits()
	fibers.run(function()
		local path = os.tmpname()
		write(path, 'throttled=0x50005\n')
		local drv = driver({ path })
		local expected = {
			under_voltage_detected = true,
			arm_frequency_capped = false,
			currently_throttled = true,
			under_voltage_occurred = true,
		}
		for field, want in pairs(expected) do
			local ok, value = get(drv, field)
			eq(ok, true, field)
			eq(value, want, field)
		end

		write(path, '0\n')
		for field in pairs(expected) do
			local _, value = get(drv, field)
			eq(value, false, field .. ' clear')
		end
		os.remove(path)
	end)
end

function T.power_flags_use_the_first_readable_path_and_share_one_read()
	fibers.run(function()
		local path = os.tmpname()
		write(path, '10000\n') -- bare hex, as sysfs prints it: under-voltage has occurred
		local drv = driver({ path .. '.missing', path })
		local _, value = get(drv, 'under_voltage_occurred', 60)
		eq(value, true, 'second path used')

		-- Within max_age the cached read is reused, even after the file changes.
		write(path, '0\n')
		_, value = get(drv, 'under_voltage_occurred', 60)
		eq(value, true, 'cached within max_age')
		os.remove(path)
	end)
end

function T.power_flags_are_nil_when_the_platform_has_none()
	fibers.run(function()
		local drv = driver({ os.tmpname() .. '.missing' })
		local ok, value = get(drv, 'currently_throttled')
		eq(ok, true)
		eq(value, nil)
	end)
end

function T.power_flags_report_errors_for_unreadable_or_malformed_files()
	fibers.run(function()
		-- Malformed content is an error, not a guessed value.
		local path = os.tmpname()
		write(path, 'throttled=oops\n')
		local ok, err = get(driver({ path }), 'currently_throttled')
		eq(ok, false, 'malformed value')
		assert(tostring(err):find('failed to parse', 1, true), tostring(err))

		-- A path that exists but can't be read is an error (unless running as root,
		-- which can still read it), even when the other candidate is missing.
		write(path, '0\n')
		os.execute('chmod 000 ' .. path)
		local readable = io.open(path, 'r')
		if readable then
			readable:close()
		else
			ok, err = get(driver({ path .. '.missing', path }), 'currently_throttled')
			eq(ok, false, 'unreadable file')
			assert(tostring(err):find('failed to read', 1, true), tostring(err))
		end
		os.execute('chmod 600 ' .. path)
		os.remove(path)
	end)
end

-- A read that fails part-way (partial content plus an error) is an error,
-- not a value to cache.
function T.power_flags_reject_a_partial_read()
	fibers.run(function()
		local real_file = package.loaded['fibers.io.file']
		package.loaded['fibers.io.file'] = {
			open = function ()
				return {
					read_all = function () return '100', 'Input/output error' end,
					close = function () end,
				}
			end,
		}
		package.loaded['services.hal.drivers.platform'] = nil
		local stubbed = require 'services.hal.drivers.platform'
		package.loaded['fibers.io.file'] = real_file
		package.loaded['services.hal.drivers.platform'] = platform

		local drv = setmetatable({ cache = cache_mod.new(), identity = {}, throttled_paths = { '/any' } }, stubbed.Driver)
		local ok, err = drv:get(cap_args.new.PlatformGetOpts('under_voltage_detected', 60))
		eq(ok, false, 'partial read')
		assert(tostring(err):find('Input/output error', 1, true), tostring(err))
		eq(drv.cache:get('throttled', 60), nil, 'nothing cached')
	end)
end

return T
