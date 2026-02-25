-- tools/test_net_compile.lua
--
-- Usage:
--   lua tools/test_net_compile.lua ./halservices.json
--
-- Expects JSON in the "config service" persisted shape:
--   { "net": { "rev": <int>, "data": <table> }, ... }
--
-- Prints a Lua-ish representation of the compiled desired state.
-- Note: nil-valued fields are omitted by Lua table semantics.

package.path = '../src/?.lua;' .. package.path

local cjson = require 'cjson.safe'
local compiler = require 'src.services.net.compiler'

local function read_all(path)
	local f, err = io.open(path, 'rb')
	if not f then return nil, err end
	local s = f:read('*a')
	f:close()
	return s, nil
end

local function is_plain_table(x) return type(x) == 'table' and getmetatable(x) == nil end

local function sorted_keys(t)
	local ks = {}
	for k in pairs(t) do ks[#ks + 1] = k end
	table.sort(ks, function(a, b)
		local ta, tb = type(a), type(b)
		if ta == tb then return tostring(a) < tostring(b) end
		return ta < tb
	end)
	return ks
end

local function is_dense_array(t)
	-- Accept dense 1..n arrays.
	local n = 0
	for k in pairs(t) do
		if type(k) ~= 'number' or k < 1 or k % 1 ~= 0 then
			return false, 0
		end
		if k > n then n = k end
	end
	for i = 1, n do
		if rawget(t, i) == nil then return false, 0 end
	end
	return true, n
end

local function escape_str(s)
	-- Minimal escaping for readable output.
	s = s:gsub('\\', '\\\\'):gsub('\n', '\\n'):gsub('\r', '\\r'):gsub('\t', '\\t'):gsub('"', '\\"')
	return '"' .. s .. '"'
end

local function dump(v, indent, stack)
  indent = indent or 0
  stack = stack or {}

  local tv = type(v)
  if tv == 'nil' then
    return 'nil'
  elseif tv == 'boolean' or tv == 'number' then
    return tostring(v)
  elseif tv == 'string' then
    return escape_str(v)
  elseif tv ~= 'table' then
    return escape_str(tostring(v))
  end

  -- Only a cycle if we're re-entering the same table on the active path.
  if stack[v] then
    return '"<cycle>"'
  end
  stack[v] = true

  local pad  = string.rep('  ', indent)
  local pad2 = string.rep('  ', indent + 1)

  local is_arr, n = is_dense_array(v)
  if is_arr then
    if n == 0 then
      stack[v] = nil
      return '{ }'
    end
    local out = { '{' }
    for i = 1, n do
      out[#out + 1] = pad2 .. dump(v[i], indent + 1, stack) .. (i < n and ',' or '')
    end
    out[#out + 1] = pad .. '}'
    stack[v] = nil
    return table.concat(out, '\n')
  end

  local ks = sorted_keys(v)
  if #ks == 0 then
    stack[v] = nil
    return '{ }'
  end

  local out = { '{' }
  for i = 1, #ks do
    local k = ks[i]
    local key
    if type(k) == 'string' and k:match('^[%a_][%w_]*$') then
      key = k
    else
      key = '[' .. dump(k, 0, stack) .. ']'
    end
    out[#out + 1] = string.format('%s%s = %s%s',
      pad2, key, dump(v[k], indent + 1, stack), (i < #ks and ',' or '')
    )
  end
  out[#out + 1] = pad .. '}'
  stack[v] = nil
  return table.concat(out, '\n')
end

local function main()
	local path = arg[1]
	if not path or path == '' then
		io.stderr:write('usage: lua tools/test_net_compile.lua <config.json>\n')
		os.exit(2)
	end

	local blob, rerr = read_all(path)
	if not blob then
		io.stderr:write('failed to read ' .. tostring(path) .. ': ' .. tostring(rerr) .. '\n')
		os.exit(2)
	end

	local doc, jerr = cjson.decode(blob)
	if not doc then
		io.stderr:write('json decode failed: ' .. tostring(jerr) .. '\n')
		os.exit(2)
	end
	if not is_plain_table(doc) then
		io.stderr:write('config root must be a JSON object\n')
		os.exit(2)
	end

	local net = doc.net
	if not is_plain_table(net) then
		io.stderr:write('missing or invalid "net" record (expected {rev,data})\n')
		os.exit(2)
	end

	local rev = net.rev
	local data = net.data
	if type(rev) ~= 'number' then
		io.stderr:write('"net.rev" must be a number\n')
		os.exit(2)
	end
	if not is_plain_table(data) then
		io.stderr:write('"net.data" must be an object\n')
		os.exit(2)
	end

	local desired, derr = compiler.compile(data, { rev = math.floor(rev), gen = 1, state_schema = 'devicecode.state/2.5' })
	if not desired then
		io.stderr:write('compile failed:\n')
		io.stderr:write(dump(derr) .. '\n')
		os.exit(1)
	end

	print('-- compiled desired state')
	print('return ' .. dump(desired))
end

main()
