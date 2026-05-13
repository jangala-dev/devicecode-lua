-- services/http/transport/uri.lua
-- lua-http-backed URI parsing boundary for the HTTP capability service.
--
-- Policy code should not keep a separate hand-written parser for the same URI
-- shape that lua-http will later consume.  This module uses lua-http's request
-- constructor and utility helpers to produce the small normalised view needed by
-- service policy without starting any network work.

local http_request = require 'http.request'
local http_util    = require 'http.util'

local M = {}

local function normalise_error(err)
	local s = tostring(err or ''):lower()
	if s:find('scheme not valid', 1, true) or s:find('unknown scheme', 1, true) then
		return 'unsupported_scheme'
	end
	return 'invalid_args'
end

local function leading_scheme(uri)
	return uri:match('^([%a][%w+.-]*)://')
end

local function lua_http_uri(uri, scheme)
	-- http.request.new_from_uri is the authority/path parser used by the
	-- backend.  WebSocket URIs are HTTP Upgrade requests, but lua-http's
	-- request constructor is deliberately HTTP(S)-shaped, so parse ws/wss via
	-- the corresponding HTTP scheme and restore the public scheme below.
	if scheme == 'ws' then
		return 'http://' .. uri:sub(6), 'http'
	end
	if scheme == 'wss' then
		return 'https://' .. uri:sub(7), 'https'
	end
	return uri, scheme
end

function M.parse(uri)
	if type(uri) ~= 'string' or uri == '' then return nil, 'invalid_args' end

	local public_scheme = leading_scheme(uri)
	if type(public_scheme) ~= 'string' then return nil, 'invalid_args' end
	public_scheme = public_scheme:lower()

	local parse_uri, authority_scheme = lua_http_uri(uri, public_scheme)
	local ok, req_or_err = pcall(function ()
		return http_request.new_from_uri(parse_uri)
	end)
	if not ok or not req_or_err then return nil, normalise_error(req_or_err) end

	local req = req_or_err
	local headers = req.headers
	local parsed_scheme = headers and headers:get(':scheme') or nil
	local authority = headers and headers:get(':authority') or nil
	local path = headers and headers:get(':path') or nil
	if type(parsed_scheme) ~= 'string' or parsed_scheme == '' then return nil, 'invalid_args' end
	if type(authority) ~= 'string' or authority == '' then return nil, 'invalid_args' end

	local ok_split, host, port = pcall(http_util.split_authority, authority, authority_scheme)
	if not ok_split then return nil, 'invalid_args' end
	if type(host) ~= 'string' or host == '' then return nil, 'invalid_args' end

	return {
		uri = uri,
		scheme = public_scheme,
		authority = authority,
		host = host,
		port = port,
		path = path,
		request = req,
	}, nil
end

return M
