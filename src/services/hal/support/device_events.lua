-- services/hal/support/device_events.lua
--
-- Shared HAL DeviceEvent construction and emission helpers.

local op        = require 'fibers.op'
local hal_types = require 'services.hal.types.core'

local M = {}

function M.emit_op(dev_ev_ch, action, class, id, metadata, caps)
	return op.guard(function ()
		if type(dev_ev_ch) ~= 'table' or type(dev_ev_ch.put_op) ~= 'function' then
			return op.always(false, 'device event channel missing')
		end

		local ev, err = hal_types.new.DeviceEvent(
			action,
			class,
			id,
			metadata or {},
			caps or {}
		)
		if not ev then
			return op.always(false, tostring(err))
		end

		return dev_ev_ch:put_op(ev):wrap(function ()
			return true, nil
		end)
	end)
end

function M.added_op(dev_ev_ch, class, id, metadata, caps)
	return M.emit_op(dev_ev_ch, 'added', class, id, metadata, caps)
end

function M.removed_op(dev_ev_ch, class, id, metadata)
	return M.emit_op(dev_ev_ch, 'removed', class, id, metadata or {}, {})
end

return M
