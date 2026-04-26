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
	'unit.devicecode.service_base_spec',
	'unit.config.codec_spec',
	'unit.config.service_spec',
	'unit.config.state_spec',
	'unit.device.availability_spec',
	'unit.device.component_host_spec',
	'unit.device.component_mcu_spec',
	'unit.device.model_spec',
	'unit.device.service_spec',
	'unit.device.topics_spec',
	'unit.fabric.blob_source_spec',
	'unit.fabric.checksum_spec',
	'unit.fabric.protocol_spec',
	'unit.fabric.reader_spec',
	'unit.fabric.rpc_bridge_spec',
	'unit.fabric.service_spec',
	'unit.fabric.session_ctl_spec',
	'unit.fabric.topicmap_exact_spec',
	'unit.fabric.topicmap_spec',
	'unit.fabric.transfer_mgr_spec',
	'unit.fabric.writer_spec',
	'unit.hal.artifact_store_driver_spec',
	'unit.hal.control_store_driver_spec',
	'unit.hal.signature_verify_openssl_spec',
	'unit.main.profile_config_spec',
	'unit.main.profile_contract_spec',
	'unit.main.service_spec',
	'unit.member_adapter.contract_spec',
	'unit.member_mcu_legacy.normalize_spec',
	'unit.shared.crypto.keyring_spec',
	'unit.shared.crypto.provider_spec',
	'unit.shared.crypto.verifier_spec',
	'unit.shared.encoding.b64url_spec',
	'unit.ui.http_transport_spec',
	'unit.ui.cqueues_bridge_spec',
	'unit.ui.model_spec',
	'unit.ui.queries_spec',
	'unit.ui.service_spec',
	'unit.ui.sessions_spec',
	'unit.ui.topics_spec',
	'unit.ui.uploads_spec',
	'unit.update.artifacts_spec',
	'unit.update.await_spec',
	'unit.update.bundled_reconcile_spec',
	'unit.update.job_store_spec',
	'unit.update.mcu_image_v1_spec',
	'unit.update.observe_spec',
	'unit.update.service_spec',
	'integration.devhost.config_recovery_spec',
	'integration.devhost.device_mcu_telemetry_fabric_spec',
	'integration.devhost.fabric_service_spec',
	'integration.devhost.fabric_session_spec',
	'integration.devhost.fabric_transfer_receiver_handoff_spec',
	'integration.devhost.hal_uart_spec',
	'integration.devhost.main_failure_spec',
	'integration.devhost.update_manual_upload_bundled_hold_spec',
	'integration.devhost.ui_service_spec',
	'integration.devhost.ui_update_upload_fabric_spec',
	'integration.devhost.ui_ws_spec',
	'integration.devhost.update_bundled_device_fabric_spec',
	'integration.devhost.update_cm5_local_spec',
	'integration.devhost.update_device_fabric_spec',
	'integration.devhost.update_device_seam_spec',
	'integration.devhost.update_getbox_transient_reconcile_spec',
	'integration.devhost.update_restart_reconcile_spec',
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
