-- services/http/policy.lua
-- Validation, locality and basic egress policy.  This module is deliberately
-- conservative: it rejects before backend admission where it can.

local body = require 'services.http.body'
local uri_util = require 'services.http.transport.uri'

local M = {}

local SAFE_METHODS = { GET = true, HEAD = true, OPTIONS = true }
local METHODS = {
	GET = true, HEAD = true, POST = true, PUT = true, PATCH = true,
	DELETE = true, OPTIONS = true,
}

local function copy_headers(h)
	if h == nil then return nil end
	if type(h) ~= 'table' then return nil, 'invalid_args' end
	local out = {}
	for k, v in pairs(h) do
		if type(k) ~= 'string' then return nil, 'invalid_args' end
		if type(v) ~= 'string' and type(v) ~= 'number' then return nil, 'invalid_args' end
		out[k] = tostring(v)
	end
	return out, nil
end

local function reject_backend_payload_fields(args)
	local forbidden = {
		server = true, server_options = true, http_server = true, request_module = true,
		websocket_module = true, cq = true, driver = true, socket = true, onstream = true,
		onerror = true, condition_factory = true, context_terminator = true,
		on_context = true, on_context_transferred = true, on_context_terminated = true,
		on_terminate = true, stream = true, ws = true, exchange = true, listener = true,
	}
	for k in pairs(args or {}) do
		if forbidden[k] then return nil, 'invalid_args' end
	end
	return true
end

local function require_only_fields(args, allowed)
	local ok, ferr = reject_backend_payload_fields(args)
	if not ok then return nil, ferr end
	for k in pairs(args or {}) do
		if not allowed[k] then return nil, 'invalid_args' end
	end
	return true
end

function M.is_local_origin(origin)
	return origin
		and origin.kind == 'local'
		and origin.link_id == nil
		and origin.peer_node == nil
		and origin.peer_sid == nil
end

function M.require_local_origin(origin)
	if M.is_local_origin(origin) then return true, nil end
	return nil, 'not_local'
end


function M.validate_method(method)
	method = tostring(method or 'GET'):upper()
	if not METHODS[method] then return nil, 'invalid_args' end
	return method
end

function M.is_safe_method(method)
	return SAFE_METHODS[tostring(method or ''):upper()] or false
end

function M.validate_uri(uri, opts)
	opts = opts or {}
	local parsed, perr = uri_util.parse(uri)
	if not parsed then return nil, perr or 'invalid_args' end

	local allowed = opts.allowed_schemes or { http = true, https = true, ws = true, wss = true }
	if not allowed[parsed.scheme] then return nil, 'unsupported_scheme' end

	return {
		uri = parsed.uri,
		scheme = parsed.scheme,
		authority = parsed.authority,
		host = parsed.host,
		port = parsed.port,
		path = parsed.path,
	}, nil
end

function M.validate_listen_args(args)
	args = args or {}
	if type(args) ~= 'table' then return nil, 'invalid_args' end
	local ok, ferr = require_only_fields(args, { host = true, port = true, path = true, tls = true, max_accept_queue = true })
	if not ok then return nil, ferr end
	local out = {}
	if args.host ~= nil and type(args.host) ~= 'string' then return nil, 'invalid_args' end
	if args.port ~= nil and (type(args.port) ~= 'number' or args.port < 0 or args.port > 65535) then
		return nil, 'invalid_args'
	end
	if args.path ~= nil and type(args.path) ~= 'string' then return nil, 'invalid_args' end
	if args.tls ~= nil and type(args.tls) ~= 'boolean' then return nil, 'invalid_args' end
	if args.max_accept_queue ~= nil and (type(args.max_accept_queue) ~= 'number' or args.max_accept_queue < 0) then return nil, 'invalid_args' end
	out.host = args.host
	out.port = args.port
	out.path = args.path
	out.tls = args.tls
	out.max_accept_queue = args.max_accept_queue
	if out.host == nil and out.path == nil then out.host = '127.0.0.1' end
	if out.port == nil and out.path == nil then out.port = 0 end
	if out.tls == nil then out.tls = false end
	return out, nil
end

local function host_denied(parsed_uri, opts)
	local host = parsed_uri and parsed_uri.host or nil
	if host == nil then return true end
	if opts.denied_hosts and opts.denied_hosts[host] then return true end
	if opts.allowed_hosts and not opts.allowed_hosts[host] then return true end
	if opts.allow_loopback == false and (host == '127.0.0.1' or host == 'localhost' or host == '::1') then return true end
	return false
end

function M.validate_exchange_args(args, opts)
	opts = opts or {}
	if type(args) ~= 'table' then return nil, 'invalid_args' end
	local ok, ferr = require_only_fields(args, { uri = true, method = true, headers = true, body_source = true, response_sink = true })
	if not ok then return nil, ferr end
	local uri, uerr = M.validate_uri(args.uri, opts)
	if not uri then return nil, uerr end
	if uri.scheme == 'ws' or uri.scheme == 'wss' then return nil, 'unsupported_scheme' end
	if host_denied(uri, opts) then return nil, 'host_denied' end
	local method, merr = M.validate_method(args.method or 'GET')
	if not method then return nil, merr end
	local headers, herr = copy_headers(args.headers)
	if herr then return nil, herr end

	local bodies, derr = body.validate_exchange_bodies(args)
	if not bodies then return nil, derr end

	return {
		uri = uri.uri,
		method = method,
		headers = headers,
		_uri = uri,
		body_source = bodies.source,
		response_sink = bodies.sink,
	}, nil
end

function M.validate_connect_ws_args(args, opts)
	opts = opts or {}
	if type(args) ~= 'table' then return nil, 'invalid_args' end
	local ok, ferr = require_only_fields(args, { uri = true, headers = true })
	if not ok then return nil, ferr end
	local uri, uerr = M.validate_uri(args.uri, opts)
	if not uri then return nil, uerr end
	if uri.scheme ~= 'ws' and uri.scheme ~= 'wss' then return nil, 'unsupported_scheme' end
	if host_denied(uri, opts) then return nil, 'host_denied' end
	local headers, herr = copy_headers(args.headers)
	if herr then return nil, herr end
	return { uri = uri.uri, headers = headers, _uri = uri }, nil
end

M._reject_backend_payload_fields = reject_backend_payload_fields
M._require_only_fields = require_only_fields

return M
