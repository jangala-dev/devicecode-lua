-- devicecode/support/model.lua
--
-- Pulse-backed observable state model.  Models are state only: they expose
-- snapshot/version/change Ops and immediate termination; they do not perform
-- Ops, publish, call services or own backend work.

local pulse  = require 'fibers.pulse'
local tablex = require 'shared.table'

local M = {}
local Model = {}
Model.__index = Model

local function default_copy(v)
	return tablex.deep_copy(v)
end

local function default_equals(a, b)
	return tablex.deep_equal(a, b)
end

local function assert_integer(n, name, level)
	if type(n) ~= 'number' or n < 0 or n % 1 ~= 0 then
		error(name .. ' must be a non-negative integer', (level or 1) + 1)
	end
end

function Model:version()
	return self._pulse:version()
end

function Model:is_closed()
	return self._closed
end

function Model:is_terminated()
	return self._closed
end

function Model:why()
	return self._closed_reason
end

function Model:termination_reason()
	return self._closed_reason
end

function Model:snapshot()
	return self._copy(self._snapshot)
end

function Model:set_snapshot(next_snapshot)
	if self._closed then
		return nil, self._closed_reason or 'closed'
	end

	local copied = self._copy(next_snapshot)
	if self._equals(self._snapshot, copied) then
		return false, self:version()
	end

	self._snapshot = copied
	local v = self._pulse:signal()
	return true, v
end

function Model:update(f)
	if type(f) ~= 'function' then
		error((self._label or 'model') .. ':update expects a function', 2)
	end
	if self._closed then
		return nil, self._closed_reason or 'closed'
	end

	local current = self:snapshot()
	local next_snapshot = f(current)
	if next_snapshot == nil then next_snapshot = current end
	return self:set_snapshot(next_snapshot)
end

function Model:changed_op(last_seen)
	assert_integer(last_seen, (self._label or 'model') .. '.changed_op: last_seen', 2)

	return self._pulse:changed_op(last_seen):wrap(function (version, reason)
		if version == nil then
			return nil, nil, reason or self._closed_reason or 'closed'
		end
		return version, self:snapshot(), nil
	end)
end

function Model:terminate(reason)
	if self._closed then
		if self._closed_reason == nil and reason ~= nil then
			self._closed_reason = reason
		end
		return true
	end

	self._closed = true
	self._closed_reason = reason or 'closed'
	self._pulse:close(self._closed_reason)
	return true
end

function M.new(initial, opts)
	opts = opts or {}
	if opts.copy ~= nil and type(opts.copy) ~= 'function' then
		error('model.new: opts.copy must be a function', 2)
	end
	if opts.equals ~= nil and type(opts.equals) ~= 'function' then
		error('model.new: opts.equals must be a function', 2)
	end

	local copy_fn = opts.copy or default_copy
	return setmetatable({
		_snapshot      = copy_fn(initial or {}),
		_pulse         = pulse.new(0),
		_copy          = copy_fn,
		_equals        = opts.equals or default_equals,
		_label         = opts.label or 'model',
		_closed        = false,
		_closed_reason = nil,
	}, Model)
end

M.Model = Model
M.default_copy = default_copy
M.default_equals = default_equals

return M
