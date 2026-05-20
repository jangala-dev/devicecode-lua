-- services/update/projection.lua
--
-- Pure conversion from internal update snapshots to retained/public payloads.

local model = require 'services.update.model'

local M = {}

local function copy(v)
	return model.deep_copy(v)
end

local function transfer_from_stage(job)
	local stage = type(job) == 'table' and job.stage_result or nil
	if type(stage) ~= 'table' then return nil end
	local reply = type(stage.reply) == 'table' and stage.reply or nil
	local transfer = type(stage.transfer) == 'table' and copy(stage.transfer) or {}
	if reply then
		local inner = type(reply.transfer) == 'table' and reply.transfer or reply
		if type(inner) == 'table' then
			local result = type(inner.result) == 'table' and inner.result or inner
			transfer.xfer_id = transfer.xfer_id or result.xfer_id or inner.xfer_id
			transfer.request_id = transfer.request_id or result.request_id or inner.request_id
			transfer.link_id = transfer.link_id or inner.link_id or result.link_id
			transfer.target = transfer.target or result.target or inner.target
			transfer.digest_alg = transfer.digest_alg or result.digest_alg or inner.digest_alg
			transfer.digest = transfer.digest or result.digest or inner.digest
			transfer.size = transfer.size or result.size or inner.size
			transfer.sent_bytes = transfer.sent_bytes or result.sent_bytes or inner.sent_bytes
			transfer.retransmits = transfer.retransmits or result.retransmits or inner.retransmits
		end
	end
	return next(transfer) ~= nil and transfer or nil
end

local function correlation(job)
	job = type(job) == 'table' and job or {}
	local meta = type(job.metadata) == 'table' and job.metadata or {}
	local stage = type(job.stage_result) == 'table' and job.stage_result or {}
	local transfer = transfer_from_stage(job)
	local pre = type(job.commit_attempt) == 'table' and job.commit_attempt.pre_commit or nil
	pre = type(pre) == 'table' and pre or nil
	return {
		job_id = job.job_id,
		component = job.component,
		artifact_ref = job.artifact_ref
			or (type(job.artifact) == 'table' and (job.artifact.artifact_ref or job.artifact.ref or job.artifact.id))
			or (type(job.artifact) == 'string' and job.artifact or nil),
		ingest_id = job.ingest_id or meta.ingest_id,
		xfer_id = transfer and transfer.xfer_id or nil,
		request_id = transfer and transfer.request_id or nil,
		link_id = transfer and transfer.link_id or nil,
		call_id = type(job.commit_attempt) == 'table' and job.commit_attempt.call_id or nil,
		expected_image_id = job.expected_image_id or meta.expected_image_id or meta.image_id or stage.expected_image_id or (pre and pre.expected_image_id),
		pre_commit_boot_id = pre and pre.pre_commit_boot_id or nil,
		pre_commit_image_id = pre and pre.pre_commit_image_id or nil,
	}
end

local function add_corr(dst, corr)
	for k, v in pairs(corr or {}) do
		if v ~= nil then dst[k] = v end
	end
	return dst
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
		pending    = copy(snapshot.pending),
		dependencies = copy(snapshot.dependencies),
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
	local out = copy(job)
	if type(out) == 'table' then
		out.correlation = correlation(job)
	end
	return out
end

function M.job_timeline(job)
	job = type(job) == 'table' and job or {}
	local corr = correlation(job)
	local events = {}
	for _, ev in ipairs(type(job.history) == 'table' and job.history or {}) do
		local item = add_corr({
			seq = ev.seq,
			state = ev.state,
			reason = ev.reason,
		}, corr)
		events[#events + 1] = item
	end
	return {
		kind = 'update.job.timeline',
		job_id = job.job_id,
		component = job.component,
		state = job.state,
		updated_seq = job.updated_seq,
		correlation = corr,
		transfer = transfer_from_stage(job),
		commit_attempt = copy(job.commit_attempt),
		events = events,
	}
end

function M.ingest(record)
	return copy(record)
end

function M.manager_status(snapshot)
	return { ok = true, snapshot = M.service_state(snapshot) }
end

return M
