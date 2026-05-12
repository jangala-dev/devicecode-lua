-- services/http/transport/client.lua
-- lua-http request integration. This layer constructs requests and returns
-- raw lua-http response headers and streams; public handles are built above this layer.

local op = require 'fibers.op'
local headers_mod = require 'services.http.headers'
local terminate = require 'services.http.transport.terminate'

local M = {}

local function require_request(opts)
	if opts and opts.request_module then return opts.request_module end
	local ok, mod = pcall(require, 'http.request')
	if not ok then return nil, mod end
	return mod
end

local function apply_headers(req, fields)
	if not fields then return true end
	for _, pair in ipairs(headers_mod.to_pairs(fields)) do
		req.headers:append(tostring(pair[1]), tostring(pair[2] or ''))
	end
	return true
end

local function build_request(request_module, args)
	local req, err = request_module.new_from_uri(args.uri)
	if not req then return nil, err end
	if args.method then req.headers:upsert(':method', args.method) end
	apply_headers(req, args.headers)
	if args._request_body ~= nil then
		if type(req.set_body) == 'function' then req:set_body(args._request_body)
		else return nil, 'request_body_not_supported' end
	end
	return req, nil
end

function M.open_exchange_op(driver, checked_args, opts)
	opts = opts or {}
	return op.guard(function ()
		local request_module, rerr = require_request(opts)
		if not request_module then return op.always(nil, rerr) end
		local active = { request = nil, stream = nil }
		return driver:run_op('http.client.open_exchange', function ()
			local req, berr = build_request(request_module, checked_args)
			if not req then return nil, berr end
			active.request = req
			local response_headers, stream = req:go(opts.backend_timeout)
			if not response_headers then return nil, stream or 'connect_failed' end
			active.stream = stream
			return response_headers, stream
		end, {
			on_active_abort = function (reason)
				local why = reason or 'open_exchange_aborted'
				if active.stream then
					terminate.terminate_stream(active.stream, why)
				elseif active.request then
					terminate.terminate_request(active.request, why)
				elseif driver and driver.terminate then
					driver:terminate(why)
				end
			end,
		})
	end)
end

-- One-shot exchange setup only. Body copy/drain/commit is owned by
-- services.http.client so leases and finalisers are installed in that operation
-- scope, not inside the transport job.
function M.exchange_open_op(driver, checked_args, opts)
	return M.open_exchange_op(driver, checked_args, opts)
end

return M
