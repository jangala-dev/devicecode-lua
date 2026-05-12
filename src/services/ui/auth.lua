-- services/ui/auth.lua
--
-- Authentication/verifier boundary. The default verifier is deliberately local
-- and immediate; callers that need blocking authentication should wrap it as a
-- scoped operation outside this module.

local M = {}
local Verifier = {}
Verifier.__index = Verifier

function M.new(opts)
	opts = opts or {}
	if opts.verify ~= nil and type(opts.verify) ~= 'function' then
		error('auth.new: verify must be a function', 2)
	end
	return setmetatable({
		_verify = opts.verify,
		_users = opts.users or {},
	}, Verifier)
end

function Verifier:verify(credentials)
	credentials = credentials or {}
	if self._verify then
		return self._verify(credentials)
	end

	local username = credentials.username or credentials.user
	local password = credentials.password
	local rec = username and self._users[username] or nil
	if rec == nil then
		return nil, 'unauthenticated'
	end
	if type(rec) == 'table' then
		if rec.password ~= nil and rec.password ~= password then
			return nil, 'unauthenticated'
		end
		return rec.principal or username, nil
	end
	if rec ~= password then
		return nil, 'unauthenticated'
	end
	return username, nil
end

function M.verify(verifier, credentials)
	if verifier == nil then
		return nil, 'auth verifier unavailable'
	end
	if type(verifier) == 'function' then
		return verifier(credentials)
	end
	if type(verifier) == 'table' and type(verifier.verify) == 'function' then
		return verifier:verify(credentials)
	end
	return nil, 'invalid auth verifier'
end

M.Verifier = Verifier
return M
