-- services/ui/errors.lua
--
-- Boundary error vocabulary and simple HTTP mapping helpers.

local M = {}

M.codes = {
	bad_request      = { http = 400, message = 'bad_request' },
	invalid_json     = { http = 400, message = 'invalid_json' },
	invalid_body     = { http = 400, message = 'invalid_body' },
	request_body_too_large = { http = 413, message = 'request_body_too_large' },
	unsupported_media_type = { http = 415, message = 'unsupported_media_type' },
	unauthenticated  = { http = 401, message = 'unauthenticated' },
	forbidden        = { http = 403, message = 'forbidden' },
	not_found        = { http = 404, message = 'not_found' },
	timeout          = { http = 504, message = 'timeout' },
	conflict         = { http = 409, message = 'conflict' },
	closed           = { http = 499, message = 'closed' },
	internal         = { http = 500, message = 'internal_error' },
	upstream_failed  = { http = 502, message = 'upstream_failed' },
}

local function norm_key(err)
	if type(err) == 'table' then
		return err.code or err.kind or err.error or 'internal'
	end
	local s = tostring(err or 'internal')
	if M.codes[s] then return s end
	if s:find('timeout', 1, true) then return 'timeout' end
	if s:find('unauth', 1, true) then return 'unauthenticated' end
	if s:find('forbidden', 1, true) or s:find('permission', 1, true) then return 'forbidden' end
	if s:find('not_found', 1, true) or s:find('no_route', 1, true) then return 'not_found' end
	if s:find('closed', 1, true) or s:find('cancelled', 1, true) then return 'closed' end
	return 'internal'
end

function M.normalise(err)
	local key = norm_key(err)
	local spec = M.codes[key] or M.codes.internal
	local detail
	if type(err) == 'table' then
		detail = err.detail or err.reason or err.primary
	else
		detail = err
	end
	return {
		code    = key,
		status  = spec.http,
		message = spec.message,
		detail  = detail and tostring(detail) or nil,
	}
end

function M.http_status(err)
	return M.normalise(err).status
end

function M.http_body(err)
	local e = M.normalise(err)
	return {
		error   = e.message,
		code    = e.code,
		detail  = e.detail,
	}
end

return M
