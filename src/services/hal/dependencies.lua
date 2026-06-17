-- services/hal/dependencies.lua
-- Declared cross-service dependency ports for the HAL service root.

local capdeps = require 'services.support.capdeps'
local http_sdk = require 'services.http.sdk'

local M = {}

function M.declarations()
	local http_client = assert(capdeps.capability({
		sdk = http_sdk,
		default_cap_id = 'main',
		methods = {
			'status_op',
			'open_exchange_op',
			'exchange_op',
		},
	}))
	return {
		http_client = http_client,
	}
end

function M.resolver(conn)
	return capdeps.new(conn, M.declarations())
end

function M.manager_options(manager_name, resolver, base)
	local out = {}
	for k, v in pairs(base or {}) do out[k] = v end
	if manager_name == 'wired' and resolver then
		out.http_client_for = resolver:factory('http_client')
	end
	return out
end

return M
