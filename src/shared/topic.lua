-- shared/topic.lua
--
-- Pure dense topic-array helpers.

local tablex = require 'shared.table'

local M = {}

function M.copy(t)
	return tablex.array_copy(t)
end

function M.append(base, ...)
	local out = M.copy(base)
	for i = 1, select('#', ...) do
		local v = select(i, ...)
		if type(v) == 'table' then
			for j = 1, #v do out[#out + 1] = v[j] end
		else
			out[#out + 1] = v
		end
	end
	return out
end

function M.starts_with(topic, prefix)
	if type(topic) ~= 'table' or type(prefix) ~= 'table' then return false end
	if #prefix > #topic then return false end
	for i = 1, #prefix do
		if topic[i] ~= prefix[i] then return false end
	end
	return true
end

function M.replace_prefix(topic, from, to)
	if not M.starts_with(topic, from) then return nil, 'topic does not start with prefix' end
	local out = M.copy(to)
	for i = #from + 1, #topic do out[#out + 1] = topic[i] end
	return out, nil
end

function M.key(topic, sep)
	sep = sep or '/'
	local parts = {}
	for i = 1, #(topic or {}) do parts[i] = tostring(topic[i]) end
	return table.concat(parts, sep)
end

function M.to_string(topic)
	return M.key(topic, '/')
end

function M.validate_dense(t, opts)
	opts = opts or {}
	local name = opts.name or 'topic'
	if type(t) ~= 'table' then return nil, name .. ' must be a table' end
	local n = #t
	for k, v in pairs(t) do
		if type(k) ~= 'number' or k < 1 or k % 1 ~= 0 or k > n then
			return nil, name .. ' must be a dense array'
		end
		local tv = type(v)
		if tv ~= 'string' and tv ~= 'number' then
			return nil, name .. '[' .. tostring(k) .. '] must be a string or number'
		end
		if opts.non_empty ~= false and tv == 'string' and v == '' then
			return nil, name .. '[' .. tostring(k) .. '] must be non-empty'
		end
	end
	return true, nil
end

return M
