-- tests/unit/hal/common_uci_compat_spec.lua

local tests = {}

local function fail(msg) error(msg or 'assertion failed', 2) end

local function read_file(path)
	local f = assert(io.open(path, 'r'))
	local s = f:read('*a')
	f:close()
	return s
end

function tests.test_common_uci_preserves_wifi_facing_surface()
	local uci = require 'services.hal.backends.common.uci'
	if type(uci.ensure_started) ~= 'function' then fail('ensure_started missing') end
	if type(uci.new_session) ~= 'function' then fail('new_session missing') end
	if type(uci.get_value) ~= 'function' then fail('get_value missing') end
	if type(uci.section_exists) ~= 'function' then fail('section_exists missing') end
	if type(uci.get_sections) ~= 'function' then fail('get_sections missing') end
end

function tests.test_common_uci_wrapper_does_not_spawn_into_root_scope()
	local s = read_file('../src/services/hal/backends/common/uci.lua')
	if s:find('Scope.root', 1, true) then
		fail('common UCI compatibility wrapper must not spawn into Scope.root')
	end
end

return tests
