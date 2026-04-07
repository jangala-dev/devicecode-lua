-- tests/run.lua

-- look one level up
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

local files = {
	'unit.config.codec_spec',
	'unit.config.state_spec',
	'unit.net.model_spec',
	'unit.net.control_spec',
	'unit.main.service_spec',
	'unit.config.service_spec',
	'unit.net.service_spec',
	'unit.ui.service_spec',
	'unit.ui.http_transport_spec',
	'unit.ui.cqueues_bridge_spec',
	'unit.fabric.b64url_spec',
	'unit.fabric.blob_source_spec',
	'unit.fabric.checksum_spec',
	'unit.fabric.config_spec',
	'unit.fabric.topicmap_spec',
	'unit.fabric.protocol_spec',
	'unit.fabric.service_spec',
	'unit.fabric.session_spec',
	'unit.fabric.transfer_spec',
	'integration.devhost.stack_spec',
	'integration.devhost.main_stack_spec',
	'integration.devhost.main_failure_spec',
	'integration.devhost.ui_firmware_uart_spec',
	'integration.devhost.ui_http_firmware_spec',
	'integration.devhost.ui_stack_spec',
	'integration.devhost.config_recovery_spec'
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
