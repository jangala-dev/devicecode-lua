local tests = {}

local function read(path)
	local f = assert(io.open(path, 'rb'))
	local s = f:read('*a')
	f:close()
	return s
end

local function assert_false(v, msg) if v ~= false then error(msg or 'expected false', 2) end end

function tests.test_wired_service_has_no_os_backend_detail()
	local src = read('../src/services/wired/service.lua')
	assert_false(src:find('perform_raw', 1, true) ~= nil, 'wired service must not use perform_raw')
	assert_false(src:find('join_op', 1, true) ~= nil, 'wired service must not join child scopes')
	assert_false(src:find('services.hal.backends', 1, true) ~= nil, 'wired service must not require HAL backends')
	assert_false(src:find('/sys/class', 1, true) ~= nil, 'wired service must not read sysfs')
end


function tests.test_wired_public_seam_has_no_provider_capability_projection()
	for _, path in ipairs({
		'../src/services/wired/topics.lua',
		'../src/services/wired/projection.lua',
		'../src/services/wired/publisher.lua',
		'../src/services/device/projection.lua',
		'../src/services/device/publisher.lua',
	}) do
		local src = read(path)
		assert_false(src:find('cap/wired-provider', 1, true) ~= nil, path .. ' must not publish cap/wired-provider')
		assert_false(src:find("'state', 'wired', 'provider'", 1, true) ~= nil, path .. ' must not publish state/wired/provider')
	end
end


function tests.test_switch_observation_path_uses_runtime_and_power_not_telemetry()
	for _, path in ipairs({
		'../src/services/hal/backends/wired/providers/rtl8380m_http.lua',
		'../src/services/hal/managers/wired.lua',
		'../src/services/wired/service.lua',
	}) do
		local src = read(path)
		assert_false(src:find("state', 'telemetry", 1, true) ~= nil, path .. ' must not publish state/telemetry for switch observations')
		assert_false(src:find('telemetry.cpu', 1, true) ~= nil, path .. ' must not use telemetry.cpu')
		assert_false(src:find('telemetry.mem', 1, true) ~= nil, path .. ' must not use telemetry.mem')
	end
end

function tests.test_switch_and_wired_path_has_no_soft_config_aliases()
	local rtl = read('../src/services/hal/backends/wired/providers/rtl8380m_http.lua')
	assert_false(rtl:find('config.id', 1, true) ~= nil, 'rtl8380m_http must not accept config.id')
	assert_false(rtl:find("or 'main'", 1, true) ~= nil, 'rtl8380m_http must require http.capability')
	assert_false(rtl:find("or 'legacy-http1-close'", 1, true) ~= nil, 'rtl8380m_http must require explicit legacy parser')
	assert_false(rtl:find('default_surfaces', 1, true) ~= nil, 'rtl8380m_http must not have stub/default surfaces')

	local cfg = read('../src/services/wired/config.lua')
	assert_false(cfg:find('rec.label', 1, true) ~= nil, 'cfg/wired must not accept label alias')
	assert_false(cfg:find("and 'access' or 'trunk'", 1, true) ~= nil, 'cfg/wired must not infer attachment mode from segment')
	assert_false(cfg:find("or { mode = 'none' }", 1, true) ~= nil, 'cfg/wired surfaces must declare attachment.mode')
end

return tests
