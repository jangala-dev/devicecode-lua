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
	'unit.devicecode.service_base_spec',
	'unit.hal.cap_sdk_spec',
	'unit.hal.hal_compat_spec',
	'unit.hal.service_raw_host_spec',
	'unit.hal.control_store_provider_spec',
	'unit.hal.control_store_manager_spec',
	"unit.hal.signature_verify_manager_spec",
	"unit.hal.signature_verify_provider_spec",
	"unit.hal.signature_verify_openssl_spec",
	"unit.hal.artifact_store_driver_spec",
	"unit.hal.artifact_store_provider_spec",
	"unit.hal.artifact_store_manager_spec",
	"unit.hal.uart_driver_spec",
	"unit.hal.uart_manager_spec",
	'unit.fabric.test_model',
	'unit.fabric.test_config',
	'unit.fabric.test_session',
	'unit.fabric.test_link',
	'unit.fabric.test_io',
	'unit.fabric.test_protocol',
	'unit.fabric.test_topics',
	'unit.fabric.test_service',
	'unit.fabric.test_transfer',
	'unit.fabric.test_transfer_sender',
	'unit.fabric.test_bridge',
	'unit.fabric.test_fabric',
	'unit.devicecode.blob_source_spec',
	'unit.devicecode.support_contracts_spec',
	'unit.shared.table_spec',
	'unit.shared.topic_spec',
	'unit.shared.validate_spec',
	'unit.shared.hash_xxhash32_spec',
	'integration.devhost.main_failure_spec',
	'integration.devhost.config_recovery_spec',
	"integration.devhost.hal_uart_spec",
	"integration.devhost.fabric_hal_uart_smoke_spec",
	"integration.devhost.fabric_public_service_path_spec",
	'unit.support.test_scoped_work',
	'unit.support.test_queue',
	'unit.support.test_priority_event',
	'unit.support.test_request_owner',
	'unit.support.test_resource',
	'unit.support.test_bus_cleanup',
	'unit.support.test_config_watch',
	'unit.support.test_service_events',
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
