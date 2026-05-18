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


function tests.test_net_service_uses_named_runtime_components()
	local svc = read_file('../src/services/net/service.lua')
	for _, mod in ipairs({
		"services.net.capability_resolver",
		"services.net.observer_manager",
		"services.net.wan_manager",
		"services.net.drift",
	}) do
		if not svc:find(mod, 1, true) then fail('net service should use ' .. mod) end
	end
end

function tests.test_net_publisher_has_dirty_publication_path()
	local pub = read_file('../src/services/net/publisher.lua')
	if not pub:find('publish_dirty_now', 1, true) then fail('net publisher should expose publish_dirty_now') end
	if not pub:find('new_dirty_state', 1, true) then fail('net publisher should expose dirty state') end
end


function tests.test_net_wan_runtime_uses_explicit_timeout_races_not_bus_timeouts()
	local rt = read_file('../src/services/net/wan_runtime.lua')
	if not rt:find('sleep.sleep_op', 1, true) or not rt:find('op.named_choice', 1, true) then
		fail('net WAN runtime should express timeouts as explicit Op races')
	end
	if rt:find('timeout = request.max_duration_s', 1, true) or rt:find('timeout = spec.timeout_s', 1, true) then
		fail('net WAN runtime should not pass positive hidden bus timeouts to HAL calls')
	end
	if not rt:find('timeout = false', 1, true) then
		fail('net WAN runtime should disable hidden HAL bus timeout on inner calls')
	end
end

function tests.test_hal_network_manager_uses_canonical_control_loop()
	local mgr = read_file('../src/services/hal/managers/network.lua')
	if not mgr:find("services.hal.support.control_loop", 1, true) then
		fail('network manager should use the canonical HAL control loop')
	end
	if mgr:find('req.reply_ch:put_op', 1, true) then
		fail('network manager should not reply directly; use control_loop reply/cancellation path')
	end
	if mgr:find('fibers.perform(driver_op)', 1, true) then
		fail('network manager should return driver Ops rather than performing them inline')
	end
end

return tests
