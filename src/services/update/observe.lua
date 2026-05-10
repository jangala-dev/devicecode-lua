-- services/update/observe.lua
--
-- Generation-owned component observer model.
--
-- This is deliberately only an observation owner. It stores the latest
-- component snapshots, exposes versioned changes, and may be consumed by
-- active reconcile workers. It does not decide update policy and does not
-- perform Ops.

local model_mod = require 'services.update.model'

local M = {}

local Observer = {}
Observer.__index = Observer

local function copy(v)
	return model_mod.deep_copy(v)
end

local function initial_components(components)
	local by_id = {}
	for id, cfg in pairs(components or {}) do
		by_id[id] = {
			id = id,
			config = copy(cfg),
			state = nil,
			origin = nil,
		}
	end
	return by_id
end

local function make_snapshot(service_id, components)
	local by_id = initial_components(components)
	local count = 0
	for _ in pairs(by_id) do count = count + 1 end
	return {
		service = service_id or 'update',
		count = count,
		by_id = by_id,
	}
end

function M.new(opts)
	opts = opts or {}
	return setmetatable({
		_model = model_mod.new(make_snapshot(opts.service_id, opts.components), {
			label = opts.label or 'update.observe',
		}),
	}, Observer)
end

function Observer:version()
	return self._model:version()
end

function Observer:snapshot()
	return self._model:snapshot()
end

function Observer:changed_op(seen)
	return self._model:changed_op(seen)
end

function Observer:terminate(reason)
	return self._model:terminate(reason or 'observer_closed')
end

function Observer:update_component(component, snapshot, origin)
	if type(component) ~= 'string' or component == '' then
		return nil, 'component required'
	end

	return self._model:update(function (s)
		s.by_id = s.by_id or {}
		local cur = s.by_id[component] or { id = component }
		cur.state = copy(snapshot)
		cur.origin = copy(origin)
		s.by_id[component] = cur
		local count = 0
		for _ in pairs(s.by_id) do count = count + 1 end
		s.count = count
		return s
	end)
end

function Observer:remove_component(component, reason)
	if type(component) ~= 'string' or component == '' then
		return nil, 'component required'
	end

	return self._model:update(function (s)
		if s.by_id then
			s.by_id[component] = nil
		end
		local count = 0
		for _ in pairs(s.by_id or {}) do count = count + 1 end
		s.count = count
		s.reason = reason
		return s
	end)
end

M.Observer = Observer
return M
