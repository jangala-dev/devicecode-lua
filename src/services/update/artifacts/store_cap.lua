-- services/update/artifacts/store_cap.lua
-- Operation-shaped artifact store adapter.

local safe  = require 'coxpcall'
local op    = require 'fibers.op'
local model = require 'services.update.model'

local M = {}
local Store = {}
Store.__index = Store

local function copy(v) return model.deep_copy(v) end
local function is_op(v) return type(v) == 'table' and getmetatable(v) == op.Op end

local function immediate(fn, ...)
	local args = { n = select('#', ...), ... }
	local ok, a, b = safe.pcall(function () return fn(unpack(args, 1, args.n)) end)
	if not ok then return op.always(nil, tostring(a)) end
	return op.always(a, b)
end

function Store:create_sink_op(spec)
	local b = self._backend
	if type(b.create_sink_op) == 'function' then
		local ev = b:create_sink_op(copy(spec or {}))
		if not is_op(ev) then return op.always(nil, 'create_sink_op did not return an Op') end
		return ev
	end
	if type(b.create_sink) == 'function' then
		return immediate(function () return b:create_sink(copy(spec or {})) end)
	end
	return op.always(nil, 'create_sink not supported')
end

function Store:probe_op(source)
	local b = self._backend
	if type(b.probe_op) == 'function' then
		local ev = b:probe_op(copy(source or {}))
		if not is_op(ev) then return op.always(nil, 'probe_op did not return an Op') end
		return ev
	end
	if type(b.probe) == 'function' then
		return immediate(function () return b:probe(copy(source or {})) end)
	end
	return op.always(nil, 'probe not supported')
end

function M.wrap(backend)
	if type(backend) ~= 'table' then error('artifact store backend table required', 2) end
	return setmetatable({ _backend = backend }, Store)
end

M.Store = Store
return M
