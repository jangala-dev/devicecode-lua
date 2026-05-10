-- shared/table.lua
--
-- Pure table helpers.  This module must not depend on fibers, bus or services.

local M = {}

function M.shallow_copy(t)
	if t == nil then return {} end
	local out = {}
	for k, v in pairs(t) do out[k] = v end
	return out
end

M.copy = M.shallow_copy

function M.array_copy(t)
	local out = {}
	for i = 1, #(t or {}) do out[i] = t[i] end
	return out
end

function M.copy_array(t)
	return M.array_copy(t)
end

function M.table_or_empty(v)
	if type(v) == 'table' then return v end
	return {}
end

function M.list_or_empty(v)
	if type(v) == 'table' then return v end
	return {}
end

function M.first_non_nil(...)
	for i = 1, select('#', ...) do
		local v = select(i, ...)
		if v ~= nil then return v end
	end
	return nil
end

function M.is_array(t)
	if type(t) ~= 'table' then return false end
	local n = #t
	for k in pairs(t) do
		if type(k) ~= 'number' or k < 1 or k % 1 ~= 0 or k > n then
			return false
		end
	end
	return true
end

local function deep_copy_impl(v, seen)
	if type(v) ~= 'table' then return v end
	seen = seen or {}
	if seen[v] then return seen[v] end
	local out = {}
	seen[v] = out
	for k, val in pairs(v) do
		out[deep_copy_impl(k, seen)] = deep_copy_impl(val, seen)
	end
	return out
end

function M.deep_copy(v)
	return deep_copy_impl(v, {})
end

local function deep_equal_impl(a, b, seen)
	if a == b then return true end
	if type(a) ~= 'table' or type(b) ~= 'table' then return false end
	seen = seen or {}
	seen[a] = seen[a] or {}
	if seen[a][b] then return true end
	seen[a][b] = true
	for k, av in pairs(a) do
		if not deep_equal_impl(av, b[k], seen) then return false end
	end
	for k in pairs(b) do
		if a[k] == nil then return false end
	end
	return true
end

function M.deep_equal(a, b)
	return deep_equal_impl(a, b, {})
end

function M.keys(t)
	local out = {}
	for k in pairs(t or {}) do out[#out + 1] = k end
	return out
end

function M.sorted_keys(t, cmp)
	local out = M.keys(t)
	table.sort(out, cmp or function(a, b) return tostring(a) < tostring(b) end)
	return out
end

return M
