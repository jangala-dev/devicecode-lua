local dirent = require 'posix.dirent'
local stat = require 'posix.sys.stat'
local stdlib = require 'posix.stdlib'
local unistd = require 'posix.unistd'

local discovery = require 'tests.support.discovery'

local T = {}

local function mkdir(path)
	assert(stat.mkdir(path))
end

local function write_file(path)
	local file = assert(io.open(path, 'w'))
	file:write('return {}\n')
	file:close()
end

local function remove_tree(path)
	local entries = dirent.dir(path)
	if not entries then return end
	for _, name in ipairs(entries) do
		if name ~= '.' and name ~= '..' then
			local child = path .. '/' .. name
			local info = stat.lstat(child)
			if info and stat.S_ISDIR(info.st_mode) ~= 0 then
				remove_tree(child)
			else
				os.remove(child)
			end
		end
	end
	unistd.rmdir(path)
end

local function with_temp_tree(fn)
	local root = assert(stdlib.mkdtemp('/tmp/devicecode-test-discovery-XXXXXX'))
	local ok, err = xpcall(function() fn(root) end, debug.traceback)
	remove_tree(root)
	if not ok then error(err, 0) end
end

local function assert_array_eq(actual, expected)
	assert(#actual == #expected,
		('expected %d modules, got %d: %s'):format(#expected, #actual, table.concat(actual, ', ')))
	for i = 1, #expected do
		assert(actual[i] == expected[i],
			('module %d: expected %q, got %q'):format(i, expected[i], tostring(actual[i])))
	end
end

function T.discovers_supported_names_recursively_in_stable_order()
	with_temp_tree(function(root)
		mkdir(root .. '/unit')
		mkdir(root .. '/unit/nested')
		mkdir(root .. '/integration')
		mkdir(root .. '/integration/devhost')

		write_file(root .. '/unit/test_zeta.lua')
		write_file(root .. '/unit/nested/alpha_spec.lua')
		write_file(root .. '/integration/devhost/test_middle.lua')
		write_file(root .. '/unit/nested/helper.lua')
		write_file(root .. '/unit/nested/test_not_lua.txt')

		local modules = discovery.discover({
			{ path = root .. '/unit', module_prefix = 'unit' },
			{ path = root .. '/integration/devhost', module_prefix = 'integration.devhost' },
		})

		assert_array_eq(modules, {
			'integration.devhost.test_middle',
			'unit.nested.alpha_spec',
			'unit.test_zeta',
		})
	end)
end

function T.reports_an_unreadable_discovery_root()
	with_temp_tree(function(root)
		local ok, err = pcall(discovery.discover, {
			{ path = root .. '/missing', module_prefix = 'unit' },
		})
		assert(ok == false)
		assert(tostring(err):match('could not scan test directory'))
	end)
end

return T
