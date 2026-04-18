local M = {}

local ERR_MT = {}
ERR_MT.__index = ERR_MT
ERR_MT.__tostring = function(self)
	return tostring(self.message or self.code or 'error')
end

local function new(code, message, http_status, extra)
	return setmetatable({
		code = code or 'error',
		message = message or code or 'error',
		http_status = http_status or 500,
		extra = extra,
	}, ERR_MT)
end

function M.is_error(x)
	return type(x) == 'table' and getmetatable(x) == ERR_MT
end

function M.err(code, message, http_status, extra)
	return new(code, message, http_status, extra)
end

function M.bad_request(message, extra) return new('bad_request', message or 'bad request', 400, extra) end
function M.unauthorised(message, extra) return new('unauthorised', message or 'unauthorised', 401, extra) end
function M.forbidden(message, extra) return new('forbidden', message or 'forbidden', 403, extra) end
function M.not_found(message, extra) return new('not_found', message or 'not found', 404, extra) end
function M.conflict(message, extra) return new('conflict', message or 'conflict', 409, extra) end
function M.timeout(message, extra) return new('timeout', message or 'timeout', 504, extra) end
function M.unavailable(message, extra) return new('unavailable', message or 'unavailable', 503, extra) end
function M.upstream(message, extra) return new('upstream_error', message or 'upstream error', 502, extra) end
function M.not_ready(message, extra) return new('not_ready', message or 'not ready', 503, extra) end
function M.internal(message, extra) return new('internal_error', message or 'internal error', 500, extra) end

function M.code(err)
	return M.is_error(err) and err.code or nil
end

function M.message(err)
	if M.is_error(err) then return err.message end
	if err == nil then return nil end
	return tostring(err)
end

function M.http_status(err)
	return M.is_error(err) and (err.http_status or 500) or 500
end

function M.from(err, fallback_http)
	if M.is_error(err) then return err end
	if err == nil then return nil end
	local s = tostring(err)
	if s == '' then return new('error', 'error', fallback_http or 500) end
	if s == 'timeout' or s:find('timeout', 1, true) then return M.timeout(s) end
	if s == 'no_route' or s == 'closed' or s == 'full' or s:find('queue', 1, true) then return M.unavailable(s) end
	if s:find('not found', 1, true) or s == 'no_such_link' then return M.not_found(s) end
	if s:find('invalid', 1, true) or s:find('missing', 1, true) or s:find('must be', 1, true) then
		return M.bad_request(s)
	end
	if s:find('unauthor', 1, true) or s == 'forbidden' then return M.unauthorised(s) end
	return new('error', s, fallback_http or 500)
end

return M
