local dirent = require 'posix.dirent'
local stat = require 'posix.sys.stat'

local M = {}

local function is_test_file(name)
	return name:match('^test_.*%.lua$') ~= nil
		or name:match('_spec%.lua$') ~= nil
end

local function join_path(parent, child)
	return parent .. '/' .. child
end

local function join_module(prefix, name)
	if prefix == '' then return name end
	return prefix .. '.' .. name
end

local function scan(path, module_prefix, modules)
	local ok, entries, err = pcall(dirent.dir, path)
	if not ok then
		error(('could not scan test directory %q: %s'):format(path, tostring(entries)), 0)
	end
	assert(entries, ('could not scan test directory %q: %s'):format(path, tostring(err)))

	for _, name in ipairs(entries) do
		if name ~= '.' and name ~= '..' then
			local child_path = join_path(path, name)
			local info, stat_err = stat.lstat(child_path)
			assert(info, ('could not inspect test path %q: %s'):format(child_path, tostring(stat_err)))

			if stat.S_ISDIR(info.st_mode) ~= 0 then
				scan(child_path, join_module(module_prefix, name), modules)
			elseif stat.S_ISREG(info.st_mode) ~= 0 and is_test_file(name) then
				local basename = assert(name:match('^(.*)%.lua$'))
				modules[#modules + 1] = join_module(module_prefix, basename)
			end
		end
	end
end

function M.discover(roots)
	local modules = {}
	for _, root in ipairs(roots) do
		assert(type(root.path) == 'string', 'test discovery root requires a path')
		assert(type(root.module_prefix) == 'string', 'test discovery root requires a module_prefix')
		scan(root.path, root.module_prefix, modules)
	end
	table.sort(modules)
	return modules
end

return M
