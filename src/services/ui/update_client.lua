-- services/ui/update_client.lua
--
-- Shared client for the update manager interface.

local update_topics = require 'services.update.topics'

local M = {}

local function call(conn, method, payload, timeout)
	return conn:call(update_topics.manager_rpc(method), payload or {}, {
		timeout = timeout or 10.0,
	})
end

function M.create(conn, payload, timeout) return call(conn, 'create-job', payload, timeout) end
function M.get(conn, job_id, timeout) return call(conn, 'get-job', { job_id = job_id }, timeout) end
function M.list(conn, timeout) return call(conn, 'list-jobs', {}, timeout) end
function M.start(conn, job_id, timeout) return call(conn, 'start-job', { job_id = job_id }, timeout) end
function M.commit(conn, job_id, timeout) return call(conn, 'commit-job', { job_id = job_id }, timeout) end
function M.cancel(conn, job_id, timeout) return call(conn, 'cancel-job', { job_id = job_id }, timeout) end
function M.retry(conn, job_id, timeout) return call(conn, 'retry-job', { job_id = job_id }, timeout) end
function M.discard(conn, job_id, timeout) return call(conn, 'discard-job', { job_id = job_id }, timeout) end

function M.do_job(conn, payload, timeout)
	payload = payload or {}
	local op = payload.op
	local job_id = payload.job_id
	if op == 'start' then return M.start(conn, job_id, timeout) end
	if op == 'commit' then return M.commit(conn, job_id, timeout) end
	if op == 'cancel' then return M.cancel(conn, job_id, timeout) end
	if op == 'retry' then return M.retry(conn, job_id, timeout) end
	if op == 'discard' then return M.discard(conn, job_id, timeout) end
	return nil, 'invalid_op'
end

return M
