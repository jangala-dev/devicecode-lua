-- services/update/artifacts/lifetime.lua
--
-- Artifact-specific finaliser-safe ownership helper.
--
-- Scope-owned artifact and sink resources must expose:
--   terminate(reason)  immediate, idempotent, non-yielding cleanup
--
-- Graceful Op-based close paths belong in workers before finalisation. Legacy cleanup names are adapted at capability/test boundaries, not in
-- this ownership helper.

local resource = require 'devicecode.support.resource'

local M = {}

local Owned = {}
Owned.__index = Owned

local function has_terminate(obj)
	return type(obj) == 'table' and type(obj.terminate) == 'function'
end

function M.has_immediate_cleanup(obj)
	return has_terminate(obj)
end

function M.own(scope, obj, opts)
	opts = opts or {}
	if type(scope) ~= 'table' or type(scope.finally) ~= 'function' then
		error('artifact lifetime requires a scope', 2)
	end
	if type(obj) ~= 'table' then
		return nil, 'resource required'
	end
	if not has_terminate(obj) then
		if type(obj['close' .. '_op']) == 'function' then
			return nil, 'resource exposes close' .. '_op but no terminate(reason) method'
		end
		return nil, 'resource has no terminate(reason) method'
	end

	local owner = resource.owned(obj, {
		label = opts.label or 'artifact cleanup',
	})

	local self = setmetatable({
		_owner = owner,
		_reason = opts.reason or 'artifact scope terminated',
		_label = opts.label or 'artifact cleanup',
	}, Owned)

	scope:finally(function (_, status, primary)
		owner:terminate_checked(primary or status or self._reason, self._label)
	end)

	return self, nil
end

function Owned:resource()
	return self._owner:value()
end

function Owned:is_owned()
	return self._owner:is_owned()
end

function Owned:terminate(reason)
	return self._owner:terminate(reason or self._reason)
end

function Owned:terminate_checked(reason)
	return self._owner:terminate_checked(reason or self._reason, self._label)
end

function Owned:detach()
	return self._owner:detach()
end

function Owned:handoff(receiver_install)
	return self._owner:handoff(receiver_install)
end

function Owned:append_op(chunk)
	local sink = self:resource()
	if type(sink) ~= 'table' or type(sink.append_op) ~= 'function' then
		return nil, 'append_op not supported'
	end
	return sink:append_op(chunk)
end

function Owned:commit_op(...)
	local sink = self:resource()
	if type(sink) ~= 'table' or type(sink.commit_op) ~= 'function' then
		return nil, 'commit_op not supported'
	end
	return sink:commit_op(...)
end

M.Owned = Owned
return M
