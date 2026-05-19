-- services/update/backends/router.lua
-- Component backend router for active update work.

local op = require 'fibers.op'

local M = {}
local Router = {}
Router.__index = Router

local function component_of(job)
	return type(job) == 'table' and job.component or nil
end

local function backend_for(self, job)
	local component = component_of(job)
	local b = component and self._components[component] or nil
	return b or self._default
end

local function method_op(self, name, required, job, ctx)
	local b = backend_for(self, job)
	if type(b) ~= 'table' then
		if required then return op.always(nil, 'update_backend_unavailable') end
		return op.always(nil, nil)
	end
	local fn = b[name]
	if type(fn) ~= 'function' then
		if required then return op.always(nil, 'update_backend_missing_' .. name) end
		return op.always(nil, nil)
	end
	return fn(b, job, ctx)
end

function Router:preflight_op(job, ctx)
	return method_op(self, 'preflight_op', false, job, ctx)
end

function Router:prepare_op(job, ctx)
	return method_op(self, 'prepare_op', false, job, ctx)
end

function Router:stage_op(job, ctx)
	return method_op(self, 'stage_op', true, job, ctx)
end

function Router:pre_commit_record_op(job, ctx)
	return method_op(self, 'pre_commit_record_op', false, job, ctx)
end

function Router:commit_op(job, ctx)
	return method_op(self, 'commit_op', true, job, ctx)
end

function Router:evaluate_reconcile(job, snapshot, ctx)
	local b = backend_for(self, job)
	if type(b) == 'table' and type(b.evaluate_reconcile) == 'function' then
		return b:evaluate_reconcile(job, snapshot, ctx)
	end
	return { done = false, reason = 'reconcile_backend_unavailable' }
end

function Router:commit_capabilities()
	return { policy = self._commit_policy or 'no_duplicate' }
end

function M.new(opts)
	opts = opts or {}
	return setmetatable({
		_components = opts.components or {},
		_default = opts.default,
		_commit_policy = opts.commit_policy,
	}, Router)
end

M.Router = Router
return M
