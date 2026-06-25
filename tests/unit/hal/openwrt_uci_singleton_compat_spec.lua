-- tests/unit/hal/openwrt_uci_singleton_compat_spec.lua

local tests = {}

local function fail(msg) error(msg or 'assertion failed', 2) end

local function read_file(path)
	local f = assert(io.open(path, 'r'))
	local s = f:read('*a')
	f:close()
	return s
end

function tests.test_uci_compat_does_not_spawn_into_root_scope()
	local s = read_file('../src/services/hal/backends/openwrt/uci_singleton_compat.lua')
	if s:find('Scope.root', 1, true) then
		fail('UCI compatibility layer must not spawn into Scope.root')
	end
end

function tests.test_uci_manager_exposes_op_first_submit_path()
	local s = read_file('../src/services/hal/backends/openwrt/uci_manager.lua')
	if not s:find('function Manager:submit_op', 1, true) then
		fail('UCI manager should expose submit_op')
	end
	if not s:find('function Session:commit_op', 1, true) then
		fail('UCI sessions should expose commit_op')
	end
end

-- extra compatibility ownership checks
function tests.test_uci_compat_requires_bound_manager_by_default()
	local compat = require 'services.hal.backends.openwrt.uci_singleton_compat'
	compat.clear_bound_manager()
	local ok, err = compat.ensure_started()
	if ok ~= false then fail('ensure_started should fail without a bound manager by default') end
	if type(err) ~= 'string' or not err:find('not bound', 1, true) then
		fail('expected not-bound error, got ' .. tostring(err))
	end
end

return tests
