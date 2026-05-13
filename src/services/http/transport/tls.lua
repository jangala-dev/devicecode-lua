-- services/http/transport/tls.lua
local M = {}
local function require_tls()
	local ok, mod = pcall(require, 'http.tls')
	if not ok then return nil, mod end
	return mod
end
function M.new_server_context(opts)
	local tls, err = require_tls()
	if not tls then return nil, err end
	if type(tls.new_server_context) == 'function' then return tls.new_server_context(opts or {}) end
	return nil, 'http.tls.new_server_context is not available'
end
function M.new_client_context(opts)
	local tls, err = require_tls()
	if not tls then return nil, err end
	if type(tls.new_client_context) == 'function' then return tls.new_client_context(opts or {}) end
	return nil, 'http.tls.new_client_context is not available'
end
return M
