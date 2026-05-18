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

return tests
