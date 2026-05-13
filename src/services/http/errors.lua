-- services/http/errors.lua

local M = {}

local stable = {
	invalid_args = true,
	forbidden = true,
	unsupported_scheme = true,
	host_denied = true,
	backend_unavailable = true,
	connect_failed = true,
	tls_failed = true,
	timeout = true,
	request_body_too_large = true,
	response_body_too_large = true,
	accept_queue_full = true,
	closed = true,
	cancelled = true,
	aborted = true,
	not_local = true,
	unsupported_remote_handle = true,
}

function M.normalise(err)
	if type(err) == 'table' and err.code then return err end
	local s = tostring(err or 'failed')
	if stable[s] then return { code = s, message = s } end
	return { code = 'backend_unavailable', message = s }
end

function M.code(err)
	return M.normalise(err).code
end

return M
