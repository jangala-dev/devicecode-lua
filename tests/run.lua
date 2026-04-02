-- tests/run.lua

local function add_path(prefix)
	package.path = prefix .. '?.lua;' .. prefix .. '?/init.lua;' .. package.path
end

local function script_dir()
	local script = arg and arg[0] or ''
	local dir = script:match('^(.*[/\\])')
	if dir then
		return dir
	end
	return './'
end

local root = script_dir() .. '../'

-- look one level up
package.path = root .. 'src/?.lua;' .. package.path
package.path = root .. '?.lua;' .. root .. '?/init.lua;' .. script_dir() .. '?.lua;' .. script_dir() .. '?/init.lua;' .. package.path

local env = os.getenv('DEVICECODE_ENV') or 'dev'
if env == 'prod' then
	add_path(root .. 'lib/')
else
	add_path(root .. 'vendor/lua-fibers/src/')
	add_path(root .. 'vendor/lua-bus/src/')
	add_path(root .. 'vendor/lua-trie/src/')
	add_path(script_dir())
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
	'unit.monitor.service_spec',
	'unit.ui.service_spec',
	'unit.ui.http_transport_spec',
	'unit.ui.cqueues_bridge_spec',
	'unit.fabric.config_spec',
	'unit.fabric.topicmap_spec',
	'unit.fabric.service_spec',
	'integration.devhost.stack_spec',
	'integration.devhost.main_stack_spec',
	'integration.devhost.main_failure_spec',
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
