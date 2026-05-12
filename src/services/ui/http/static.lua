-- services/ui/http/static.lua
--
-- Static file response worker for one HTTP request scope.  Static responses are
-- streamed through the response owner; this module never writes transport bytes
-- directly.

local fibers  = require 'fibers'
local file_io = require 'fibers.io.file'
local resource = require 'devicecode.support.resource'

local M = {}

local TYPES = {
	['.html'] = 'text/html',
	['.css']  = 'text/css',
	['.js']   = 'application/javascript',
	['.json'] = 'application/json',
	['.png']  = 'image/png',
	['.svg']  = 'image/svg+xml',
	['.txt']  = 'text/plain',
}

local function content_type(path)
	local ext = tostring(path or ''):match('(%.[^.]+)$')
	return (ext and TYPES[ext]) or 'application/octet-stream'
end

local function clean_path(root, path)
	path = tostring(path or '/index.html')
	path = path:gsub('%.%.+', '')
	if path == '/' then path = '/index.html' end
	return (root or '.') .. path
end

local function perform_required(op, label)
	local ok, err = fibers.perform(op)
	if ok ~= true then error(err or label or 'response write failed', 0) end
	return true
end

function M.run(scope, owner, route, opts)
	opts = opts or {}
	local filename = clean_path(opts.root or opts.static_root or '.', route.path)
	local f, err = file_io.open(filename, 'r')
	if not f then
		perform_required(owner:reply_error_op(404, 'not_found'), 'static not found response failed')
		return { status = 'not_found', path = route.path, err = err }
	end

	local file_owner = resource.owned(f, {
		label = 'static file cleanup',
		terminate = function (file)
			if file and type(file.close) == 'function' then return file:close() end
			return true, nil
		end,
	})
	scope:finally(function (_, status, primary)
		file_owner:terminate_checked(primary or status or 'request_closed', 'static file cleanup')
	end)

	perform_required(owner:write_headers_op(200, { ['content-type'] = content_type(filename) }), 'static headers write failed')

	local bytes = 0
	local chunk_size = opts.static_chunk_size or opts.chunk_size or 16384
	while true do
		local chunk, rerr = fibers.perform(f:read_some_op(chunk_size))
		if rerr ~= nil then
			owner:abandon_now(rerr)
			error(rerr, 0)
		end
		if chunk == nil then break end
		bytes = bytes + #chunk
		perform_required(owner:write_chunk_op(chunk), 'static chunk write failed')
	end

	perform_required(owner:end_stream_op(), 'static end write failed')
	file_owner:terminate_checked('done', 'static file cleanup')
	f = nil
	return { status = 'ok', path = route.path, bytes = bytes }
end

return M
