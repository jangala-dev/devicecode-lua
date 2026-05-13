-- services/hal/support/driver_reconcile.lua
--
-- Generic sequential reconcile helper for strict HAL managers.  The caller owns
-- driver construction, event emission and shutdown semantics; this helper owns
-- only the repeated desired/current traversal.

local fibers = require 'fibers'

local M = {}

function M.desired_by_id(entries, id_of)
	local out = {}
	id_of = id_of or function (entry) return entry and entry.id end
	for _, entry in ipairs(entries or {}) do
		out[id_of(entry)] = entry
	end
	return out
end

function M.reconcile_op(spec)
	return fibers.run_scope_op(function ()
		if type(spec) ~= 'table' then return false, 'driver_reconcile: spec table required' end
		local current = spec.current
		local entries = spec.entries
		local desired = spec.desired
		local id_of = spec.id_of or function (entry) return entry and entry.id end
		local same = spec.same
		local stop = spec.stop
		local start = spec.start
		if type(current) ~= 'table' then return false, 'driver_reconcile: current table required' end
		if desired == nil and type(entries) ~= 'table' then return false, 'driver_reconcile: entries table required' end
		if desired ~= nil and type(desired) ~= 'table' then return false, 'driver_reconcile: desired table required' end
		if type(same) ~= 'function' then return false, 'driver_reconcile: same function required' end
		if type(stop) ~= 'function' then return false, 'driver_reconcile: stop function required' end
		if type(start) ~= 'function' then return false, 'driver_reconcile: start function required' end

		desired = desired or M.desired_by_id(entries, id_of)

		for id, driver in pairs(current) do
			local want = desired[id]
			if want == nil or not same(driver, want) then
				local ok_stop, stop_err = fibers.perform(stop(id, driver))
				if not ok_stop then return false, stop_err end
			end
		end

		for id, entry in pairs(desired) do
			if not current[id] then
				local ok_start, start_err = fibers.perform(start(id, entry))
				if not ok_start then return false, start_err end
			end
		end

		return true, nil
	end):wrap(function (st, rep, ok, err)
		if st ~= 'ok' then return false, tostring(err or rep) end
		return ok, err
	end)
end

return M
