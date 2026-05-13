-- devicecode/support/queue.lua
--
-- Public queue helpers for service/coordinator code.
--
-- These helpers deliberately use the public Op interface:
--
--   op:or_else(function() ... end)
--
-- They do not inspect mailbox internals or primitive internals.
--
-- Contract:
--   * "now" means no readiness wait.
--   * "now" does not mean cancellation-atomic.
--   * calls still use scope-aware fibers.perform.
--   * fallback thunks must not yield.

local fibers = require 'fibers'

local unpack = rawget(table, 'unpack') or _G.unpack
local pack   = rawget(table, 'pack') or function (...)
	return { n = select('#', ...), ... }
end

local M = {}

--- Perform an Op as an immediate attempt.
---
--- If ev is not ready, returns the supplied fallback values.
--- This must not be used to hide a wait: the fallback is selected by or_else.
---
---@param ev Op
---@param ... any fallback values
---@return any ...
function M.try_now(ev, ...)
	local fallback = pack(...)

	return fibers.perform(ev:or_else(function ()
		return unpack(fallback, 1, fallback.n)
	end))
end

--- Try to send to a mailbox now.
---
--- Return shapes follow mailbox semantics:
---   true, nil            accepted
---   false, "full"        rejected by bounded policy
---   nil, "closed"        closed
---   nil, "would_block"   would have had to wait
---
---@param tx MailboxTx
---@param value any
---@return boolean|nil ok
---@return string|nil err
function M.try_send_now(tx, value)
	local ok, err = M.try_now(tx:send_op(value), nil, 'would_block')

	if ok == true then
		return true, nil
	end

	if ok == false then
		return false, err or 'full'
	end

	return nil, err or 'closed'
end

M.try_admit_now = M.try_send_now

--- Required immediate admission.
---
--- Suitable for coordinator/reporting paths where a completion event must not
--- silently disappear. The caller should fail the observing scope or apply an
--- explicit degradation policy if this returns nil.
---
---@param tx MailboxTx
---@param value any
---@param label? string
---@return boolean|nil ok
---@return string|nil err
function M.try_admit_required(tx, value, label)
	local ok, err = M.try_admit_now(tx, value)
	if ok == true then
		return true, nil
	end

	local prefix = label or 'queue_admission_failed'
	return nil, prefix .. ': ' .. tostring(err or 'closed')
end

--- Assert required immediate admission.
---
--- This is useful inside reporter fibres: a report failure is then an observer
--- failure, not a silent dropped completion.
---
---@param tx MailboxTx
---@param value any
---@param label? string
---@param level? integer
---@return true
function M.assert_admit_required(tx, value, label, level)
	local ok, err = M.try_admit_required(tx, value, label)
	if ok ~= true then
		error(err or 'queue_admission_failed', (level or 1) + 1)
	end
	return true
end

--- Try to receive from a mailbox now.
---
--- Return shapes:
---   item, nil           received an item
---   nil, "not_ready"  would have had to wait
---   nil, reason         closed and drained
---
---@param rx MailboxRx
---@return any item
---@return string|nil err
function M.try_recv_now(rx)
	return M.try_now(rx:recv_op():wrap(function (item)
		if item == nil then
			return nil, tostring((rx.why and rx:why()) or 'closed')
		end
		return item, nil
	end), nil, 'not_ready')
end

return M
