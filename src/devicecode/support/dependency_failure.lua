-- devicecode/support/dependency_failure.lua
--
-- Strict helpers for canonical dependency failures.
--
-- Edges normalise messy backend/bus failures into this explicit shape:
--   { kind = 'dependency_failure', err = 'no_route', dependency_key = '<key>', ... }
-- Core helpers consume that shape and a small set of direct bus call failures;
-- they do not search arbitrary reports, children, primary wrappers, or strings
-- containing diagnostic text.

local tablex = require 'shared.table'

local M = {}

local function copy(v) return tablex.deep_copy(v) end

local function non_empty(v)
	return type(v) == 'string' and v ~= ''
end

local function direct_no_route(v)
	if v == 'no_route' then return true end
	if type(v) ~= 'table' then return false end
	return v.err == 'no_route'
		or v.detail == 'no_route'
		or v.reason == 'no_route'
		or v.code == 'no_route'
end

local function result_no_route(v)
	return type(v) == 'table' and direct_no_route(v.result)
end

function M.is(v)
	return type(v) == 'table' and v.kind == 'dependency_failure'
end

function M.key(v)
	if M.is(v) and non_empty(v.dependency_key) then return v.dependency_key end
	return nil
end

function M.is_no_route_value(v)
	return direct_no_route(v) or result_no_route(v)
end

function M.is_no_route(...)
	for i = 1, select('#', ...) do
		local v = select(i, ...)
		if M.is(v) then
			return v.err == 'no_route' or v.code == 'no_route'
		end
		if M.is_no_route_value(v) then return true end
	end
	return false
end

function M.no_route(dependency_key, detail, extra)
	local out = {
		kind = 'dependency_failure',
		err = 'no_route',
		dependency_key = dependency_key,
		detail = copy(detail),
	}
	if type(extra) == 'table' then
		for k, v in pairs(extra) do
			if out[k] == nil then out[k] = copy(v) end
		end
	end
	return out
end

function M.from_no_route(dependency_key, reason, extra)
	if not non_empty(dependency_key) then return nil end
	if not M.is_no_route(reason) then return nil end
	if M.is(reason) then
		local out = copy(reason)
		out.kind = 'dependency_failure'
		out.err = 'no_route'
		out.dependency_key = out.dependency_key or dependency_key
		if type(extra) == 'table' then
			for k, v in pairs(extra) do
				if out[k] == nil then out[k] = copy(v) end
			end
		end
		return out
	end
	return M.no_route(dependency_key, reason, extra)
end

function M.classify_call_failure(reply, err)
	if M.is_no_route(reply, err) then return 'route_missing', err or reply or 'no_route' end
	return 'failure', err or reply
end

return M
