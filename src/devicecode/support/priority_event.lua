-- devicecode/support/priority_event.lua
--
-- Deterministic semantic event selection for the few places where readiness
-- order is not enough.
--
-- Fibers choice combinators select a ready operation. They are deliberately not
-- priority mechanisms. This helper keeps that contract: callers provide an
-- explicit, non-yielding selector for already-ready semantic events, then a
-- normal unordered wait used only as a wake-up source. After any wake-up, the
-- selector is run again before the coordinator commits to an event.
--
-- Contract:
--   * select_now must be non-yielding.
--   * store_wake, when supplied, must be non-yielding.
--   * wait_op returns an Op and may use ordinary choice/named_choice.
--   * the event returned by wait_op should be stored by store_wake; the helper
--     will then re-run select_now and return whichever ready event has semantic
--     priority.

local fibers = require 'fibers'
local op        = require 'fibers.op'
local validate  = require 'shared.validate'

local M = {}

local function require_function(v, name, level)
	return validate.function_(v, name, (level or 1) + 1)
end

local function require_table(v, name, level)
	return validate.table(v, name, (level or 1) + 1)
end

--- Build an Op that selects ready semantic events before and after blocking.
---
--- Shape:
---   select_now() -> ev|nil
---   wait_op()    -> Op
---   store_wake(...) -- optional, stores the wait result for later selection
---
--- If no event is ready, wait_op() is performed. Its result is only treated as
--- a wake-up. If store_wake is supplied, it is called with the wake result. The
--- helper then calls select_now() again and returns that selected event.
---
---@param spec table
---@return Op
function M.next_op(spec)
	spec = require_table(spec, 'priority_event.next_op: spec', 2)

	local select_now = require_function(spec.select_now, 'priority_event.next_op: select_now', 2)
	local wait_op    = require_function(spec.wait_op, 'priority_event.next_op: wait_op', 2)
	local store_wake = spec.store_wake
	if store_wake ~= nil then
		require_function(store_wake, 'priority_event.next_op: store_wake', 2)
	end

	local label = spec.label or 'priority_event.next_op'
	local allow_no_event = not not spec.allow_no_event

	return op.guard(function ()
		local ev = select_now()
		if ev ~= nil then
			return op.always(ev)
		end

		return wait_op():wrap(function (...)
			if store_wake ~= nil then
				store_wake(...)
			end

			local selected = select_now()
			if selected ~= nil then
				return selected
			end

			if allow_no_event then
				return nil
			end

			error(label .. ': wake produced no selectable event', 0)
		end)
	end)
end

--- Store a consumed wake-up event by source name.
---
--- This is suitable for named_choice arms that return one semantic event:
---   fibers.named_choice{ a = rx_a:recv_op():wrap(map_a), ... }
---
--- The key prepended by named_choice becomes the pending bucket.
---
---@param pending table
---@return function
function M.store_named_event(pending)
	pending = require_table(pending, 'priority_event.store_named_event: pending', 2)

	return function (name, ev)
		if name ~= nil and ev ~= nil then
			pending[name] = ev
		end
	end
end

--- Take a pending event, if present.
---@param pending table
---@param name any
---@return any ev
function M.take_pending(pending, name)
	if type(pending) ~= 'table' then
		return nil
	end

	local ev = pending[name]
	if ev ~= nil then
		pending[name] = nil
	end
	return ev
end

--- Convenience helper for queue-like event sources.
---
--- sources are checked in array order. Each source has:
---   name     = pending bucket / named_choice arm key
---   try_now  = function() -> ev|nil
---   recv_op  = function() -> Op returning ev
---   enabled  = optional function() -> boolean
---
--- The helper stores a consumed blocking wake under its source name, then
--- re-runs the priority selector. The caller owns the source-specific mapping
--- from queue item/closure to semantic event.
---
---@param spec table
---@return Op
function M.sources_op(spec)
	spec = require_table(spec, 'priority_event.sources_op: spec', 2)

	local sources = require_table(spec.sources, 'priority_event.sources_op: sources', 2)
	local pending = spec.pending or {}
	local label   = spec.label or 'priority_event.sources_op'

	local function select_now()
		for _, source in ipairs(sources) do
			local name = source.name
			if name == nil then
				error(label .. ': source missing name', 0)
			end

			if source.enabled == nil or source.enabled() then
				local ev = M.take_pending(pending, name)
				if ev ~= nil then
					return ev
				end

				if source.try_now ~= nil then
					local ready = source.try_now()
					if ready ~= nil then
						return ready
					end
				end
			end
		end

		return nil
	end

	local function wait_op()
		local arms = {}

		for _, source in ipairs(sources) do
			if source.enabled == nil or source.enabled() then
				require_function(source.recv_op, label .. ': source.recv_op', 0)
				arms[source.name] = source.recv_op()
			end
		end

		if next(arms) == nil then
			return op.always('__closed__', { kind = 'priority_event_no_sources' })
		end

		return fibers.named_choice(arms)
	end

	return M.next_op {
		label      = label,
		select_now = select_now,
		wait_op    = wait_op,
		store_wake = M.store_named_event(pending),
	}
end

return M
