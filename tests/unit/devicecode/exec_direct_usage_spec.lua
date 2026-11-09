local T = {}

local function read_file(path)
	local f = assert(io.open(path, 'r'))
	local s = f:read('*a')
	f:close()
	return s
end

local function list_src_lua_files()
	local roots = { '../src', 'src' }
	for _, root in ipairs(roots) do
		local p = io.popen(('find %s -type f -name "*.lua" | sort 2>/dev/null'):format(root))
		if p then
			local files = {}
			for line in p:lines() do files[#files + 1] = line end
			p:close()
			if #files > 0 then return files end
		end
	end
	error('could not enumerate src lua files')
end

local function assert_no_source_match(pattern, label)
	local violations = {}
	for _, path in ipairs(list_src_lua_files()) do
		local src = read_file(path)
		if src:find(pattern) then
			violations[#violations + 1] = path:gsub('^%.%./', '')
		end
	end
	assert(#violations == 0, label .. ': ' .. table.concat(violations, ', '))
end

function T.source_exec_usage_is_explicit_without_policy_wrapper()
	assert_no_source_match('devicecode%.support%.exec', 'top-level exec policy wrapper must not be used')
	assert_no_source_match('os%.execute', 'os.execute must not be used in src')
	assert_no_source_match('io%.popen', 'io.popen must not be used in src')
	assert_no_source_match('exec%.command%([\'\"]', 'exec.command vararg literals must use explicit table specs')
	assert_no_source_match('exec%.command%(unpack', 'exec.command(unpack(argv)) must build an explicit table spec')
end

return T
