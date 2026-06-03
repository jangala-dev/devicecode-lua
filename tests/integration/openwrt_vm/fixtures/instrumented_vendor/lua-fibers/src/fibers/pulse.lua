-- fibers/pulse.lua
--
-- Pulse: a versioned broadcast notifier for fibers.
--
-- Purpose
--   A Pulse holds a monotonic version counter. Callers can:
--     * read the current version (snapshot),
--     * signal an update (increments version, wakes all waiters),
--     * wait (as an Op) until the version advances past a seen value.
--
-- Semantics
--   * This is a notification primitive, not a queue: updates coalesce.
--   * changed_op(last_seen) completes when version > last_seen.
--   * close(reason) is optional but useful for clean shutdown and end-of-stream.
--
-- Return conventions (changed/next):
--   * on change:   returns (version, nil)
--   * on closed:   returns (nil, reason)
--
---@module 'fibers.pulse'

local op       = require 'fibers.op'
local cond_mod = require 'fibers.cond'
local perform  = require 'fibers.performer'.perform
local runtime  = require 'fibers.runtime'

local M = {}

---@class Pulse
---@field _ver integer
---@field _cond any          -- Cond (per-generation)
---@field _closed boolean
---@field _reason any|nil
local Pulse = {}
Pulse.__index = Pulse

local function assert_in_fiber(errlvl)
	if not runtime.current_fiber() then
		error('pulse: must be called from inside a fiber', errlvl or 3)
	end
end

--- Create a new Pulse.
---@param initial_version? integer
---@return Pulse
function M.new(initial_version)
	if initial_version ~= nil then
		if type(initial_version) ~= 'number' or initial_version < 0 or initial_version % 1 ~= 0 then
			error('pulse.new: initial_version must be a non-negative integer', 2)
		end
	end

	return setmetatable({
		_ver    = initial_version or 0,
		_cond   = cond_mod.new(),
		_closed = false,
		_reason = nil,
	}, Pulse)
end

--- Create a Pulse tied to the current scope; closes on scope finalisation.
---@param opts? { close_reason?: any }
---@return Pulse
function M.scoped(opts)
	assert_in_fiber(3)

	local fibers = require 'fibers'
	local scope  = fibers.current_scope()

	local p = M.new()
	opts = opts or {}

	scope:finally(function (_, st, primary)
		local reason = opts.close_reason
			or primary
			or ((st ~= 'ok') and st)
			or 'scope finalised'
		p:close(reason)
	end)

	return p
end

--- Current version (monotonic).
---@return integer
function Pulse:version()
	return self._ver
end

--- Whether this pulse is closed.
---@return boolean
function Pulse:is_closed()
	return self._closed
end

--- Close reason, if any.
---@return any|nil
function Pulse:why()
	return self._reason
end

--- Signal an update: increments version, wakes all waiters, and rolls the generation.
--- Returns the new version, or nil if closed.
---@return integer|nil version
function Pulse:signal()
	if self._closed then
		return nil
	end

	self._ver = self._ver + 1

	local c = self._cond
	if c then
		c:signal()
	end
	self._cond = cond_mod.new()

	return self._ver
end

--- Close the pulse (idempotent) and wake all waiters.
---@param reason any|nil
---@return boolean ok
function Pulse:close(reason)
	if self._reason == nil and reason ~= nil then
		self._reason = reason
	end
	if self._closed then
		return true
	end

	self._closed = true

	local c = self._cond
	if c then
		c:signal()
	end

	return true
end

--- Op that completes when version > last_seen, or when closed.
---@param last_seen integer
---@return Op  -- when performed: (version, nil) | (nil, reason)
function Pulse:changed_op(last_seen)
	if type(last_seen) ~= 'number' or last_seen % 1 ~= 0 then
		error('pulse.changed_op: last_seen must be an integer', 2)
	end

	return op.guard(function ()
		if self._ver > last_seen then
			return op.always(self._ver, nil)
		end

		if self._closed then
			return op.always(nil, self._reason)
		end

		local c = self._cond
		return c:wait_op():wrap(function ()
			if self._closed then
				return nil, self._reason
			end
			-- A signal implies _ver advanced; return current snapshot.
			return self._ver, nil
		end)
	end)
end

--- Convenience op: wait for the next signal from "now" (evaluated at perform time).
---@return Op
function Pulse:next_op()
	return op.guard(function ()
		local v = self._ver
		return self:changed_op(v)
	end)
end

--- Synchronous convenience: block until changed since last_seen.
---@param last_seen integer
---@return integer|nil version
---@return any|nil reason
function Pulse:changed(last_seen)
	return perform(self:changed_op(last_seen))
end

--- Synchronous convenience: block until next signal.
---@return integer|nil version
---@return any|nil reason
function Pulse:next()
	return perform(self:next_op())
end

M.Pulse = Pulse

return M
