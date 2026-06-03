-- devicecode/support/request_owner.lua
--
-- Small single-resolution owner for caller-visible request objects.
--
-- A request owner belongs inside the scope that owns the request lifetime. It
-- separates visible resolution (reply/fail/finalise) from local abandonment.
-- This keeps client-close and stale-completion paths from accidentally sending
-- protocol-visible replies.

local M = {}

local ok_probe, leak_probe = pcall(require, 'devicecode.support.leak_probe')
if not ok_probe then leak_probe = nil end

local RequestOwner = {}
RequestOwner.__index = RequestOwner

local function default_reply(req, value)
	if type(req) == 'table' and type(req.reply) == 'function' then
		return req:reply(value)
	end
	return false, 'request has no reply method'
end

local function default_fail(req, reason)
	if type(req) == 'table' and type(req.fail) == 'function' then
		return req:fail(reason)
	end
	return false, 'request has no fail method'
end

function M.new(request, opts)
	opts = opts or {}
	if type(opts) ~= 'table' then
		error('request_owner.new: opts must be a table or nil', 2)
	end

	if opts.reply ~= nil and type(opts.reply) ~= 'function' then
		error('request_owner.new: opts.reply must be a function', 2)
	end
	if opts.fail ~= nil and type(opts.fail) ~= 'function' then
		error('request_owner.new: opts.fail must be a function', 2)
	end

	return setmetatable({
		_probe_id = leak_probe and leak_probe.request_owner_created() or nil,
		_request = request,
		_done = false,
		_reply = opts.reply or default_reply,
		_fail = opts.fail or default_fail,
	}, RequestOwner)
end

function RequestOwner:request()
	return self._request
end

function RequestOwner:done()
	return not not self._done
end

function RequestOwner:reply_once(value)
	if self._done then
		return false, 'request already resolved'
	end

	self._done = true
	if leak_probe then leak_probe.request_owner_resolved(self._probe_id, 'reply') end

	return self._reply(self._request, value)
end

function RequestOwner:fail_once(reason)
	if self._done then
		return false, 'request already resolved'
	end

	self._done = true
	if leak_probe then leak_probe.request_owner_resolved(self._probe_id, 'fail') end
	return self._fail(self._request, reason)
end

function RequestOwner:finalise_unresolved(reason)
	if self._done then
		return false, 'request already resolved'
	end
	return self:fail_once(reason or 'request finalised')
end

function RequestOwner:abandon_unresolved(_reason)
	if self._done then
		return false, 'request already resolved'
	end

	self._done = true
	if leak_probe then leak_probe.request_owner_resolved(self._probe_id, 'abandon') end
	return true, nil
end


function RequestOwner:caller_cancel_op()
	local req = self._request
	if type(req) ~= 'table' or type(req.done_op) ~= 'function' then
		return nil, 'request has no done_op'
	end

	return req:done_op():wrap(function (status, _value, err)
		if status == 'abandoned' and not self:done() then
			local reason = err or 'caller_abandoned'
			self:abandon_unresolved(reason)
			return reason
		end

		return false
	end)
end

M.RequestOwner = RequestOwner

return M
