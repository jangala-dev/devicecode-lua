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
	'unit.main.profile_config_spec',
	'unit.device.service_spec',
	'unit.hal.control_store_driver_spec',
	'unit.hal.artifact_store_driver_spec',
	'unit.update.job_store_spec',
	'unit.update.service_spec',
	'unit.config.service_spec',
	'unit.fabric.b64url_spec',
	'unit.fabric.checksum_spec',
	'unit.fabric.topicmap_spec',
	'unit.fabric.topicmap_exact_spec',
	'unit.fabric.protocol_spec',
	'unit.fabric.blob_source_spec',
	'unit.fabric.service_spec',
	'unit.fabric.session_ctl_spec',
	'unit.fabric.reader_spec',
	'unit.fabric.writer_spec',
	'unit.fabric.rpc_bridge_spec',
	'unit.fabric.transfer_mgr_spec',
	'unit.ui.topics_spec',
	'unit.ui.sessions_spec',
	'unit.ui.queries_spec',
	'unit.ui.model_spec',
	'unit.ui.http_transport_spec',
	'unit.ui.service_spec',
	'integration.devhost.main_failure_spec',
	'integration.devhost.config_recovery_spec',
	'integration.devhost.fabric_session_spec',
	'integration.devhost.fabric_service_spec',
	'integration.devhost.fabric_transfer_receiver_handoff_spec',
	'integration.devhost.update_cm5_local_spec',
	'integration.devhost.update_restart_reconcile_spec',
	'integration.devhost.update_getbox_transient_reconcile_spec',
	'integration.devhost.update_device_fabric_spec',
	'integration.devhost.hal_uart_spec',
	'integration.devhost.ui_service_spec',
	'integration.devhost.ui_ws_spec',
}

local total, failed = 0, 0

for i = 1, #files do
	local modname = files[i]
	local mod = require(modname)

	for name, fn in pairs(mod) do
		total = total + 1
		io.write(('[TEST] %s :: %s ... '):format(modname, name))
		local ok, err = safe.pcall(fn)
		if ok then
			io.write('ok\n')
		else
			failed = failed + 1
			io.write('FAIL\n')
			io.write(tostring(err) .. '\n')
		end
	end
end

io.write(('\n%d tests, %d failed\n'):format(total, failed))
os.exit(failed == 0 and 0 or 1)
