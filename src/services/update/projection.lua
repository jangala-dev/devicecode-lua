-- services/update/projection.lua
--
-- Pure conversion from internal update snapshots to retained/public payloads.

local model = require 'services.update.model'

local M = {}

local function copy(v)
	return model.deep_copy(v)
end

function M.service_state(snapshot)
	snapshot = snapshot or {}
	return {
		service    = snapshot.service or 'update',
		state      = snapshot.state or 'unknown',
		ready      = snapshot.ready == true,
		reason     = snapshot.reason,
		generation = snapshot.generation,
		config     = copy(snapshot.config),
		active     = copy(snapshot.active),
		update_active = copy(snapshot.update_active),
		jobs       = copy(snapshot.jobs or { count = 0, by_id = {} }),
		ingest     = copy(snapshot.ingest or { count = 0, by_id = {} }),
		publisher  = copy(snapshot.publisher),
	}
end

function M.capability(snapshot)
	snapshot = snapshot or {}
	return {
		kind       = 'update.service',
		service    = snapshot.service or 'update',
		generation = snapshot.generation,
		ready      = snapshot.ready == true,
		methods    = {
			'status',
			'list-jobs',
			'get-job',
			'create-job',
			'start-job',
			'commit-job',
			'cancel-job',
			'retry-job',
			'discard-job',
		},
	}
end

function M.jobs(snapshot)
	local jobs = snapshot and snapshot.jobs or nil
	return copy(jobs or { count = 0, by_id = {} })
end

function M.job(job)
	return copy(job)
end

function M.ingest(record)
	return copy(record)
end

function M.manager_status(snapshot)
	return { ok = true, snapshot = M.service_state(snapshot) }
end

return M
