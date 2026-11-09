local indentation = require 'tools.lua_indentation'

local paths = {}

for i = 1, #arg do
	if arg[i]:sub(1, 1) == '-' then
		io.stderr:write(('unknown option: %s\n'):format(arg[i]))
		os.exit(2)
	else
		paths[#paths + 1] = arg[i]
	end
end

if #paths == 0 then paths = { 'src', 'tests', 'examples', 'tools' } end

local violations, total_or_err = indentation.check_paths(paths)
if violations == nil then
	io.stderr:write(tostring(total_or_err) .. '\n')
	os.exit(2)
end
if violations > 0 then
	io.stderr:write(('Lua indentation failed: %d violation(s) in %d files\n'):format(violations, total_or_err))
	os.exit(1)
end

io.write(('Lua indentation OK (%d files)\n'):format(total_or_err))
