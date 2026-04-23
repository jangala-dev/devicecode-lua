-- services/ui/update_client.lua
--
-- Shared client for the update job command surface.

local M = {}

local function call(conn, verb, payload, timeout)
	return conn:call({ 'cmd', 'update', 'job', verb }, payload or {}, {
		timeout = timeout or 10.0,
	})
end

function M.create(conn, payload, timeout)
	return call(conn, 'create', payload, timeout)
end

function M.get(conn, job_id, timeout)
	return call(conn, 'get', { job_id = job_id }, timeout)
end

function M.list(conn, timeout)
	return call(conn, 'list', {}, timeout)
end

function M.do_job(conn, payload, timeout)
	return call(conn, 'do', payload, timeout)
end

return M
