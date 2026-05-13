-- devicecode/support/resource.lua
--
-- Canonical finaliser-safe resource helpers.
--
-- Finaliser-owned resources must expose:
--   terminate(reason)  immediate, idempotent, non-yielding cleanup
--
-- Graceful cleanup belongs in resource-specific close_op() paths outside
-- finalisers.  This module deliberately does not call legacy close methods,
-- close_op(), perform(), sleep(), or join operations.

local M = {}

local function stringify_error(err, fallback)
	if err == nil then
		return fallback or 'resource termination failed'
	end
	return tostring(err)
end

local function normalise_terminate_result(a, b)
	-- terminate() is expected to return true,nil on success.  A nil,nil return is
	-- accepted for idempotent immediate cleanup methods.
	if a == nil and b == nil then
		return true, nil
	end
	if a == true then
		return true, nil
	end
	if a == false or a == nil then
		return nil, stringify_error(b, 'resource termination failed')
	end

	-- Non-boolean truthy values are accepted as success for Lua cleanup methods
	-- that return the terminated object or another sentinel.
	return true, nil
end

--- Terminate a resource through its immediate finaliser-safe method.
---
--- Accepted shapes:
---   nil                              -> true
---   table with :terminate(reason)     -> terminate result
---
--- Return shape:
---   true, nil     success
---   nil, err      termination failed or unsupported
---
---@param obj any
---@param reason any
---@return boolean|nil ok
---@return string|nil err
function M.terminate(obj, reason)
	if obj == nil then
		return true, nil
	end

	if type(obj) ~= 'table' or type(obj.terminate) ~= 'function' then
		return nil, 'resource has no terminate(reason) method'
	end

	local ok, a, b = pcall(function ()
		return obj:terminate(reason)
	end)

	if not ok then
		return nil, stringify_error(a, 'resource termination raised')
	end

	return normalise_terminate_result(a, b)
end

--- Terminate and raise on failure. Suitable for scope finalisers.
function M.terminate_checked(obj, reason, label)
	local ok, err = M.terminate(obj, reason)
	if ok ~= true then
		error((label or 'resource termination failed') .. ': ' .. tostring(err), 2)
	end
	return true
end

--- Install a standard finaliser for a finaliser-safe resource.
---
--- The returned owner is handoff-friendly: callers that transfer ownership can
--- call :handoff(...) or :detach() on it, leaving the finaliser installed but
--- inert.
function M.finally(scope, obj, label)
	if type(scope) ~= 'table' or type(scope.finally) ~= 'function' then
		error('resource.finally: scope required', 2)
	end

	local owner = M.owned(obj, { label = label })

	scope:finally(function (_, status, primary)
		owner:terminate_checked(primary or status or 'terminated', label)
	end)

	return owner
end

-------------------------------------------------------------------------------
-- Explicit ownership / handoff
-------------------------------------------------------------------------------

local Owned = {}
Owned.__index = Owned

local function terminate_owned_value(self, reason)
	local value = self._value
	if not self._owned then
		return true, nil
	end

	-- Disable ownership before cleanup so finalisers remain idempotent even if
	-- the cleanup method reports failure. The caller still receives that failure.
	self._owned = false
	self._value = nil

	local terminate_fn = self._terminate
	if terminate_fn then
		local ok, a, b = pcall(function ()
			return terminate_fn(value, reason)
		end)
		if not ok then
			return nil, stringify_error(a, 'resource termination raised')
		end
		return normalise_terminate_result(a, b)
	end

	return M.terminate(value, reason)
end

--- Create an owned finaliser-safe resource lease. Ownership is released only by
--- :handoff(), :detach(), or :terminate().
---
--- opts may be:
---   nil                                -> use resource.terminate(value, reason)
---   { terminate = function, label = ? }  -> resource-specific immediate cleanup
function M.owned(value, opts)
	local terminate_fn
	local label

	if type(opts) == 'table' then
		terminate_fn = opts.terminate
		label = opts.label
		if terminate_fn ~= nil and type(terminate_fn) ~= 'function' then
			error('resource.owned: opts.terminate must be a function', 2)
		end
	elseif opts ~= nil then
		error('resource.owned: opts must be a table or nil', 2)
	end

	return setmetatable({
		_value = value,
		_owned = true,
		_terminate = terminate_fn,
		_label = label,
	}, Owned)
end

function Owned:is_owned()
	return self._owned == true
end

function Owned:value()
	return self._value
end

function Owned:terminate(reason)
	return terminate_owned_value(self, reason)
end

function Owned:terminate_checked(reason, label)
	local ok, err = self:terminate(reason)
	if ok ~= true then
		error((label or self._label or 'resource termination failed') .. ': ' .. tostring(err), 2)
	end
	return true
end

function Owned:detach()
	if not self._owned then
		return nil, 'resource is not owned'
	end

	local value = self._value
	self._owned = false
	self._value = nil
	return value, nil
end

--- Transfer ownership to another owner. receiver_install(value) is called before
--- this lease releases cleanup ownership. If receiver_install fails or raises,
--- this lease remains responsible for termination.
function Owned:handoff(receiver_install)
	if not self._owned then
		return nil, 'resource is not owned'
	end

	local value = self._value

	if receiver_install ~= nil then
		if type(receiver_install) ~= 'function' then
			return nil, 'handoff receiver must be a function'
		end

		local ok, a, b = pcall(receiver_install, value)
		if not ok then
			return nil, stringify_error(a, 'handoff receiver raised')
		end
		if a == false or a == nil then
			return nil, stringify_error(b, 'handoff receiver rejected resource')
		end
	end

	self._owned = false
	self._value = nil
	return value, nil
end

M.Owned = Owned

return M
