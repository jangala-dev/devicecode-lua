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

local function has_explicit_header(fields, name)
	name = tostring(name or ''):lower()
	for k in pairs(fields or {}) do
		if tostring(k):lower() == name then return true end
	end
	return false
end

local function request_expect_option(args, opts, key)
	if args and args[key] ~= nil then return args[key] end
	return opts and opts[key]
end

local function delete_header(headers, name)
	if not headers then return false end
	if type(headers.delete) == 'function' then return headers:delete(name) end
	if type(headers.remove) == 'function' then return headers:remove(name) end
	return false
end

local function configure_expect_100(req, args, opts)
	local expect_100_continue = request_expect_option(args, opts, 'expect_100_continue')
	local expect_100_timeout  = request_expect_option(args, opts, 'expect_100_timeout')

	if expect_100_continue ~= nil and type(expect_100_continue) ~= 'boolean' then
		return nil, 'invalid_args'
	end

	if expect_100_timeout ~= nil then
		if type(expect_100_timeout) ~= 'number' or expect_100_timeout < 0 then
			return nil, 'invalid_args'
		end
		req.expect_100_timeout = expect_100_timeout
	end

	-- lua-http adds Expect: 100-continue for iterator/function request bodies
	-- because their length is not known to set_body().  That also introduces
	-- lua-http's default one-second expect_100_timeout unless the caller/backend
	-- has deliberately opted in.  The HTTP service keeps timeout policy explicit,
	-- so implicit Expect is suppressed by default.
	if expect_100_continue == true then
		if req.headers and type(req.headers.upsert) == 'function' then
			req.headers:upsert('expect', '100-continue')
		end
		return true
	end

	if has_explicit_header(args.headers, 'expect') then
		return true
	end

	delete_header(req.headers, 'expect')
	return true
end

local function build_request(request_module, args, opts)
	opts = opts or {}
	local req, err = request_module.new_from_uri(args.uri)
	if not req then return nil, err end
	if args.method then req.headers:upsert(':method', args.method) end
	apply_headers(req, args.headers)
	if args._request_body ~= nil then
		if type(req.set_body) == 'function' then req:set_body(args._request_body)
		else return nil, 'request_body_not_supported' end
		local ok, cerr = configure_expect_100(req, args, opts)
		if not ok then return nil, cerr end
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
			local req, berr = build_request(request_module, checked_args, opts)
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
