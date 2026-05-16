-- tests/unit/net/test_architecture.lua

local tests = {}

local function fail(msg) error(msg or 'assertion failed', 2) end

local function read_file(path)
	local f = assert(io.open(path, 'r'))
	local s = f:read('*a')
	f:close()
	return s
end

local function list_net_files()
	local p = io.popen("find ../src/services/net -type f -name '*.lua' | sort")
	local out = {}
	for line in p:lines() do out[#out + 1] = line end
	p:close()
	out[#out + 1] = '../src/services/net.lua'
	return out
end

function tests.test_net_service_code_does_not_use_perform_raw()
	for _, path in ipairs(list_net_files()) do
		local s = read_file(path)
		if s:find('perform_raw', 1, true) then fail('perform_raw found in ' .. path) end
	end
end

function tests.test_net_service_code_does_not_call_join_op()
	for _, path in ipairs(list_net_files()) do
		local s = read_file(path)
		if s:find('join_op', 1, true) then fail('join_op found in ' .. path) end
	end
end

function tests.test_net_does_not_require_platform_backend_modules()
	for _, path in ipairs(list_net_files()) do
		local s = read_file(path)
		if s:find("services.hal.backends", 1, true) then
			fail('net code must not require HAL backend modules: ' .. path)
		end
	end
end

function tests.test_net_uses_priority_event_and_scoped_apply_work()
	local events = read_file('../src/services/net/events.lua')
	if not events:find("devicecode.support.priority_event", 1, true) then
		fail('net events should use priority_event')
	end
	local apply = read_file('../src/services/net/apply_runtime.lua')
	if not apply:find('scoped_work.start', 1, true) then
		fail('net apply runtime should use scoped_work')
	end
end

function tests.test_net_config_rejects_legacy_shape_in_code_and_tests()
	local cfg = read_file('../src/services/net/config.lua')
	if cfg:find('legacy', 1, true) then fail('legacy compatibility found in net config boundary') end
	if cfg:find('raw.network', 1, true) then fail('old network shape found in net config boundary') end
	if cfg:find('raw.networks', 1, true) then fail('old networks fallback found in net config boundary') end
end

return tests
