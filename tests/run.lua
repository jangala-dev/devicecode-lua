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
local stdlib = require 'posix.stdlib'

assert(stdlib.setenv('CONFIG_TARGET', 'services'))

local files = {
	'unit.config.codec_spec',
	'unit.config.state_spec',
	'unit.main.service_spec',
	'unit.config.service_spec',
	'integration.devhost.main_failure_spec',
	'integration.devhost.config_recovery_spec',
	'unit.fabric.b64url_spec',
	'unit.fabric.checksum_spec',
	'unit.fabric.config_spec',
	'unit.fabric.topicmap_spec',
	'unit.fabric.protocol_spec',
	'unit.fabric.blob_source_spec',
	'unit.fabric.transfer_spec',
	'unit.fabric.service_spec',
	'integration.devhost.fabric_session_spec',
	'integration.devhost.hal_uart_spec',
	'integration.devhost.fabric_real_hal_uart_spec',
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
