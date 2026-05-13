-- services/update/job_store_cap.lua
--
-- Operation-shaped adapter for durable update job storage.
--
-- Preferred backend shape:
--   load_all_op(self)       -> Op yielding snapshot, err
--   save_job_op(self, job)  -> Op yielding true|nil, err
--   delete_job_op(self, id) -> Op yielding true|nil, err
--
-- For tests and explicitly immediate in-memory adapters, synchronous methods
-- may be supplied. They are called immediately by the adapter method and then
-- wrapped in op.always. This deliberately avoids hiding slow synchronous work
-- inside guard builders. Real slow stores should implement *_op methods.

local safe  = require 'coxpcall'
local op    = require 'fibers.op'
local model = require 'services.update.model'

local M = {}

local unpack = rawget(table, 'unpack') or _G.unpack
local pack   = rawget(table, 'pack') or function (...)
	return { n = select('#', ...), ... }
end

local function copy(v)
	return model.deep_copy(v)
end

local function is_op(v)
	return type(v) == 'table' and getmetatable(v) == op.Op
end

local function protected_immediate(fn, ...)
	local args = pack(...)
	local ok, result = safe.pcall(function ()
		return pack(fn(unpack(args, 1, args.n)))
	end)

	if not ok then
		return op.always(nil, tostring(result))
	end

	return op.always(unpack(result, 1, result.n))
end

local Store = {}
Store.__index = Store

function Store:load_all_op()
	local backend = self._backend

	if type(backend.load_all_op) == 'function' then
		local ev = backend:load_all_op()
		if not is_op(ev) then
			return op.always(nil, 'load_all_op did not return an Op')
		end
		return ev
	end

	if type(backend.load_all) == 'function' then
		return protected_immediate(function ()
			return backend:load_all()
		end)
	end

	return op.always({ jobs = {}, order = {} }, nil)
end

function Store:save_job_op(job)
	local backend = self._backend
	local snapshot = copy(job)

	if type(backend.save_job_op) == 'function' then
		local ev = backend:save_job_op(snapshot)
		if not is_op(ev) then
			return op.always(nil, 'save_job_op did not return an Op')
		end
		return ev
	end

	if type(backend.save_job) == 'function' then
		return protected_immediate(function ()
			return backend:save_job(snapshot)
		end)
	end

	return op.always(nil, 'save_job not supported')
end

function Store:delete_job_op(job_id)
	local backend = self._backend

	if type(backend.delete_job_op) == 'function' then
		local ev = backend:delete_job_op(job_id)
		if not is_op(ev) then
			return op.always(nil, 'delete_job_op did not return an Op')
		end
		return ev
	end

	if type(backend.delete_job) == 'function' then
		return protected_immediate(function ()
			return backend:delete_job(job_id)
		end)
	end

	return op.always(nil, 'delete_job not supported')
end

function M.wrap(backend)
	if type(backend) ~= 'table' then
		error('job_store_cap.wrap: backend table required', 2)
	end

	return setmetatable({ _backend = backend }, Store)
end

function M.memory(initial)
	local state = { jobs = {} }

	for id, job in pairs((initial and initial.jobs) or {}) do
		state.jobs[id] = copy(job)
	end

	local backend = {}

	function backend:load_all()
		local jobs = copy(state.jobs)
		local order = {}
		for id in pairs(jobs) do order[#order + 1] = id end
		table.sort(order)
		return { jobs = jobs, order = order }, nil
	end

	function backend:save_job(job)
		if type(job) ~= 'table' or type(job.job_id) ~= 'string' or job.job_id == '' then
			return nil, 'invalid_job'
		end
		state.jobs[job.job_id] = copy(job)
		return true, nil
	end

	function backend:delete_job(job_id)
		if type(job_id) ~= 'string' or job_id == '' then
			return nil, 'invalid_job_id'
		end
		state.jobs[job_id] = nil
		return true, nil
	end

	local store = M.wrap(backend)
	store._memory_state = state
	return store
end

M.Store = Store
return M
