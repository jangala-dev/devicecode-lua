-- shared/validate.lua
--
-- Pure validation helpers.  This module must not depend on fibers, bus or services.

local M = {}

local function fail(name, msg, level)
	error((name or 'value') .. ' ' .. msg, (level or 1) + 1)
end

function M.table(v, name, level)
	if type(v) ~= 'table' then fail(name, 'must be a table', (level or 1) + 1) end
	return v
end

function M.function_(v, name, level)
	if type(v) ~= 'function' then fail(name, 'must be a function', (level or 1) + 1) end
	return v
end

M.func = M.function_

function M.string(v, name, level)
	if type(v) ~= 'string' then fail(name, 'must be a string', (level or 1) + 1) end
	return v
end

function M.non_empty_string(v, name, level)
	if type(v) ~= 'string' or v == '' then fail(name, 'must be a non-empty string', (level or 1) + 1) end
	return v
end

function M.non_empty_string_or_nil(v, name, level)
	if v == nil then return nil end
	return M.non_empty_string(v, name, (level or 1) + 1)
end

function M.boolean_or_nil(v, name, level)
	if v ~= nil and type(v) ~= 'boolean' then fail(name, 'must be a boolean or nil', (level or 1) + 1) end
	return v
end

function M.number(v, name, level)
	if type(v) ~= 'number' then fail(name, 'must be a number', (level or 1) + 1) end
	return v
end

function M.positive_number(v, name, level)
	if type(v) ~= 'number' or v <= 0 then fail(name, 'must be a positive number', (level or 1) + 1) end
	return v
end

function M.non_negative_number(v, name, level)
	if type(v) ~= 'number' or v < 0 then fail(name, 'must be a non-negative number', (level or 1) + 1) end
	return v
end

function M.integer(v, name, level)
	if type(v) ~= 'number' or v % 1 ~= 0 then fail(name, 'must be an integer', (level or 1) + 1) end
	return v
end

function M.positive_integer(v, name, level)
	if type(v) ~= 'number' or v <= 0 or v % 1 ~= 0 then fail(name, 'must be a positive integer', (level or 1) + 1) end
	return v
end

function M.non_negative_integer(v, name, level)
	if type(v) ~= 'number' or v < 0 or v % 1 ~= 0 then fail(name, 'must be a non-negative integer', (level or 1) + 1) end
	return v
end

function M.table_or_empty(v, name, level)
	if v == nil then return {} end
	return M.table(v, name, (level or 1) + 1)
end

function M.list_or_empty(v, name, level)
	if v == nil then return {} end
	return M.table(v, name, (level or 1) + 1)
end

function M.only_fields(t, allowed, name, level)
	M.table(t, name, (level or 1) + 1)
	local ok = {}
	for _, k in ipairs(allowed or {}) do ok[k] = true end
	for k in pairs(t) do
		if not ok[k] then
			fail((name or 'table') .. '.' .. tostring(k), 'is not permitted', (level or 1) + 1)
		end
	end
	return t
end

return M
