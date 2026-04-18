local authz  = require 'devicecode.authz'
local errors = require 'services.ui.errors'

local M = {}

local function getenv_nonempty(name)
	local v = os.getenv(name)
	if v == nil or v == '' then return nil end
	return v
end

function M.bootstrap_verify_login(username, password)
	local expected = getenv_nonempty('DEVICECODE_UI_ADMIN_PASSWORD')
	if not expected then
		return nil, errors.unavailable('ui admin password is not configured')
	end
	if username ~= 'admin' then
		return nil, errors.unauthorised('invalid credentials')
	end
	if type(password) ~= 'string' or password ~= expected then
		return nil, errors.unauthorised('invalid credentials')
	end
	return authz.user_principal('admin', { roles = { 'admin' } }), nil
end

return M
