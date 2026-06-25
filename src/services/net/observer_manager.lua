-- services/net/observer_manager.lua
-- Owns the NET network-state observation subscription and watch request.

local fibers = require 'fibers'
local scoped_work = require 'devicecode.support.scoped_work'
local queue = require 'devicecode.support.queue'

local M = {}
local Observer = {}
Observer.__index = Observer

function M.start(spec)
	if type(spec) ~= 'table' then return nil, 'observer spec required' end
	local hal = spec.hal
	if not hal or type(hal.open_observed_subscription) ~= 'function' then return nil, 'network-state HAL capability not configured' end

	local sub, sub_err = hal:open_observed_subscription({
		queue_len = spec.queue_len or 64,
		full = spec.full or 'drop_oldest',
	})
	if not sub then return nil, sub_err or 'network observed subscription failed' end

	local handle, err
	if type(hal.start_observation_op) == 'function' then
		handle, err = scoped_work.start {
			lifetime_scope = spec.lifetime_scope,
			reaper_scope = spec.reaper_scope or spec.lifetime_scope,
			report_scope = spec.report_scope or spec.lifetime_scope,
			identity = {
				kind = 'net_observation_started',
				service_id = spec.service_id or 'net',
				generation = spec.generation or 0,
			},
			run = function ()
				local result = fibers.perform(hal:start_observation_op(spec.options or {}))
				return { ok = result and result.ok == true, result = result }
			end,
			report = function (ev)
				return queue.try_admit_required(spec.done_tx, ev, 'net_observation_start_report_failed')
			end,
		}
		if not handle then
			if sub.close then sub:close(err or 'observation_start_failed') end
			return nil, err or 'network observation start failed'
		end
	end

	return setmetatable({ sub = sub, handle = handle }, Observer), nil
end

function Observer:subscription()
	return self.sub
end

function Observer:terminate(reason)
	if self.handle and self.handle.cancel then self.handle:cancel(reason or 'observer terminated') end
	self.handle = nil
	if self.sub then
		local sub = self.sub
		self.sub = nil
		if sub.close then return sub:close(reason or 'observer terminated') end
		if sub.unsubscribe then return sub:unsubscribe() end
	end
	return true, nil
end

return M
