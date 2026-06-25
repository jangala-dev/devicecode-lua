-- services/update/job_store_memory.lua
-- Strict op-only in-memory Update job store for tests and harnesses.

local op    = require 'fibers.op'
local model = require 'services.update.model'

local M = {}
local Store = {}
Store.__index = Store

local function copy(v)
	return model.deep_copy(v)
end

local function sorted_ids(jobs)
	local ids = {}
	for id in pairs(jobs or {}) do ids[#ids + 1] = id end
	table.sort(ids)
	return ids
end

function Store:load_all_op()
	local jobs = copy(self._jobs)
	return op.always({ jobs = jobs, order = sorted_ids(jobs) }, nil)
end

function Store:save_job_op(job)
	if type(job) ~= 'table' or type(job.job_id) ~= 'string' or job.job_id == '' then
		return op.always(nil, 'invalid_job')
	end
	self._jobs[job.job_id] = copy(job)
	return op.always(true, nil)
end

function Store:delete_job_op(job_id)
	if type(job_id) ~= 'string' or job_id == '' then
		return op.always(nil, 'invalid_job_id')
	end
	self._jobs[job_id] = nil
	return op.always(true, nil)
end

function M.new(initial)
	local jobs = {}
	for id, job in pairs((initial and initial.jobs) or {}) do
		jobs[id] = copy(job)
	end
	return setmetatable({ _jobs = jobs }, Store)
end

M.Store = Store
return M
