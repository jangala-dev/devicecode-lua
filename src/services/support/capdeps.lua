-- services/support/capdeps.lua
-- Small helper for declared, narrowed cross-service capability dependencies.
--
-- Service roots may hold the bus connection.  Managers, drivers and backends
-- should receive dependency ports built here, not conn itself.

local M = {}
local Resolver = {}
Resolver.__index = Resolver

local function non_empty_string(v)
	return type(v) == 'string' and v ~= ''
end

local function shallow_copy(t)
	local out = {}
	for k, v in pairs(t or {}) do out[k] = v end
	return out
end

local function validate_methods(methods)
	if type(methods) ~= 'table' or #methods == 0 then return nil, 'dependency methods must be a non-empty list' end
	local out, seen = {}, {}
	for i = 1, #methods do
		local name = methods[i]
		if not non_empty_string(name) then return nil, 'dependency method names must be non-empty strings' end
		if seen[name] then return nil, 'duplicate dependency method: ' .. name end
		seen[name] = true
		out[#out + 1] = name
	end
	return out, nil
end

function M.capability(spec)
	if type(spec) ~= 'table' then return nil, 'capability dependency spec must be a table' end
	if type(spec.sdk) ~= 'table' or type(spec.sdk.new_ref) ~= 'function' then return nil, 'capability dependency requires sdk.new_ref' end
	local methods, merr = validate_methods(spec.methods)
	if not methods then return nil, merr end
	return {
		kind = 'capability',
		sdk = spec.sdk,
		default_cap_id = spec.default_cap_id or 'main',
		methods = methods,
	}, nil
end

local function narrow(ref, methods, meta)
	local out = {
		_capability_dependency = true,
		dependency = meta,
	}
	for i = 1, #methods do
		local name = methods[i]
		if type(ref[name]) ~= 'function' then return nil, 'capability ref missing method ' .. name end
		out[name] = function (_, ...)
			return ref[name](ref, ...)
		end
	end
	return out, nil
end

function M.new(conn, declarations)
	if conn == nil then return nil, 'dependency resolver requires conn' end
	if type(declarations) ~= 'table' then return nil, 'dependency declarations must be a table' end
	local declared = {}
	for name, decl in pairs(declarations) do
		if not non_empty_string(name) then return nil, 'dependency names must be non-empty strings' end
		if type(decl) ~= 'table' or decl.kind ~= 'capability' then return nil, 'unsupported dependency declaration: ' .. tostring(name) end
		declared[name] = shallow_copy(decl)
		declared[name].methods = shallow_copy(decl.methods)
	end
	return setmetatable({ conn = conn, declarations = declared, cache = {} }, Resolver), nil
end

function Resolver:get(name, cap_id)
	local decl = self.declarations[name]
	if not decl then return nil, 'undeclared dependency: ' .. tostring(name) end
	local id = cap_id or decl.default_cap_id or 'main'
	local key = tostring(name) .. '\0' .. tostring(id)
	if self.cache[key] then return self.cache[key], nil end
	local ref = decl.sdk.new_ref(self.conn, id)
	local port, err = narrow(ref, decl.methods, {
		name = name,
		kind = decl.kind,
		capability_id = id,
	})
	if not port then return nil, err end
	self.cache[key] = port
	return port, nil
end

function Resolver:factory(name)
	return function (cap_id)
		local port, err = self:get(name, cap_id)
		if not port then return nil, err end
		return port
	end
end

M.Resolver = Resolver
return M
