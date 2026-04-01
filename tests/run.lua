-- tests/run.lua

package.path = "../src/?.lua;" .. package.path
package.path = '../?.lua;../?/init.lua;./?.lua;./?/init.lua;' .. package.path

local function add_path(prefix)
	package.path = prefix .. '?.lua;' .. prefix .. '?/init.lua;' .. package.path
end

local env = os.getenv('DEVICECODE_ENV') or 'dev'
if env == 'prod' then
	add_path('./lib/')
else
	add_path('../vendor/lua-fibers/src/')
	add_path('../vendor/lua-bus/src/')
	add_path('../vendor/lua-trie/src/')
	add_path('./')
end

local safe = require 'coxpcall'
local stdlib = require 'posix.stdlib'

assert(stdlib.setenv('CONFIG_TARGET', 'services'))

local files = {
	'unit.config.codec_spec',
	'unit.config.state_spec',
	'unit.main.service_spec',
	'unit.config.service_spec',
	'integration.devhost.main_failure_spec',
	'integration.devhost.config_recovery_spec',
	'unit.metrics.processing_spec',
	'unit.metrics.config_spec',
	'unit.metrics.senml_spec',
	'unit.metrics.http_spec',
	'integration.metrics.service_spec',
}

local function monotonic_now()
	if type(os.clock) == 'function' then return os.clock() end
	return 0
end

local function sorted_keys(t)
	local keys = {}
	for k in pairs(t) do keys[#keys + 1] = k end
	table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
	return keys
end

local function should_run(modname, testname, filter_text)
	if not filter_text or filter_text == '' then return true end
	local needle = string.lower(filter_text)
	local hay = string.lower(('%s :: %s'):format(tostring(modname), tostring(testname)))
	return string.find(hay, needle, 1, true) ~= nil
end

local function format_duration_s(dt)
	return ('%.3fs'):format(tonumber(dt) or 0)
end

local TEST_FILTER = os.getenv('TEST_FILTER') or ''

local total, failed, skipped = 0, 0, 0
local failure_rows = {}

for i = 1, #files do
	local modname = files[i]
	local mod = require(modname)
	local keys = sorted_keys(mod)

	for j = 1, #keys do
		local name = keys[j]
		local fn = mod[name]
		if type(fn) == 'function' then
			if should_run(modname, name, TEST_FILTER) then
				total = total + 1
				io.write(('[TEST] %s :: %s ... '):format(modname, name))
				local t0 = monotonic_now()
				local ok, err = safe.xpcall(fn, function(e)
					return debug.traceback(tostring(e), 2)
				end)
				local dt = monotonic_now() - t0
				if ok then
					io.write('ok ' .. format_duration_s(dt) .. '\n')
				else
					failed = failed + 1
					failure_rows[#failure_rows + 1] = {
						name = ('%s :: %s'):format(modname, name),
						err = tostring(err),
						dt = dt,
					}
					io.write('FAIL ' .. format_duration_s(dt) .. '\n')
					io.write(tostring(err) .. '\n')
				end
			else
				skipped = skipped + 1
			end
		end
	end
end

io.write(('\n%d tests, %d failed, %d skipped\n'):format(total, failed, skipped))
if #failure_rows > 0 then
	io.write('\nFailure summary:\n')
	for i = 1, #failure_rows do
		local row = failure_rows[i]
		local first = tostring(row.err):match('([^\n]+)') or tostring(row.err)
		io.write(('  - %s [%s]\n    %s\n'):format(row.name, format_duration_s(row.dt), first))
	end
end
os.exit(failed == 0 and 0 or 1)
