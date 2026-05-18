-- services/net/wan_runtime.lua
-- Scoped WAN runtime work: speedtests and live multi-WAN weighting.

local fibers = require 'fibers'
local scoped_work = require 'devicecode.support.scoped_work'
local queue = require 'devicecode.support.queue'

local M = {}

local function report_to(done_tx, label)
	return function (ev)
		return queue.try_admit_required(done_tx, ev, label)
	end
end

function M.start_speedtest(spec)
	if type(spec) ~= 'table' then return nil, 'speedtest spec required' end
	local lifetime_scope = spec.lifetime_scope
	local hal = spec.hal
	local done_tx = spec.done_tx
	local request = spec.request
	if not lifetime_scope then return nil, 'lifetime_scope required' end
	if not hal then return nil, 'hal client required' end
	if not done_tx then return nil, 'done_tx required' end
	if type(request) ~= 'table' then return nil, 'speedtest request required' end
	if type(spec.generation) ~= 'number' then return nil, 'generation required' end
	if type(spec.speedtest_id) ~= 'number' then return nil, 'speedtest_id required' end
	if type(spec.uplink_id) ~= 'string' or spec.uplink_id == '' then return nil, 'uplink_id required' end

	return scoped_work.start {
		lifetime_scope = lifetime_scope,
		reaper_scope = spec.reaper_scope or lifetime_scope,
		report_scope = spec.report_scope or lifetime_scope,
		identity = {
			kind = 'net_speedtest_done',
			service_id = spec.service_id or 'net',
			generation = spec.generation,
			speedtest_id = spec.speedtest_id,
			uplink_id = spec.uplink_id,
		},
		run = function ()
			local result = fibers.perform(hal:speedtest_op(request, {
				timeout = request.max_duration_s or spec.timeout_s or 30,
			}))
			return {
				uplink_id = spec.uplink_id,
				request = request,
				result = result,
				ok = result and result.ok == true,
			}
		end,
		report = report_to(done_tx, 'net_speedtest_completion_report_failed'),
	}
end

function M.start_live_weights(spec)
	if type(spec) ~= 'table' then return nil, 'live weight spec required' end
	local lifetime_scope = spec.lifetime_scope
	local hal = spec.hal
	local done_tx = spec.done_tx
	if not lifetime_scope then return nil, 'lifetime_scope required' end
	if not hal then return nil, 'hal client required' end
	if not done_tx then return nil, 'done_tx required' end
	if type(spec.generation) ~= 'number' then return nil, 'generation required' end
	if type(spec.weight_apply_id) ~= 'number' then return nil, 'weight_apply_id required' end

	local request = {
		policy = spec.policy or 'balanced',
		members = spec.members or {},
		persist = spec.persist ~= false,
	}

	return scoped_work.start {
		lifetime_scope = lifetime_scope,
		reaper_scope = spec.reaper_scope or lifetime_scope,
		report_scope = spec.report_scope or lifetime_scope,
		identity = {
			kind = 'net_live_weights_done',
			service_id = spec.service_id or 'net',
			generation = spec.generation,
			weight_apply_id = spec.weight_apply_id,
		},
		run = function ()
			local result = fibers.perform(hal:apply_live_weights_op(request, {
				timeout = spec.timeout_s or 10,
			}))
			return {
				request = request,
				members = request.members,
				result = result,
				ok = result and result.ok == true,
			}
		end,
		report = report_to(done_tx, 'net_live_weights_completion_report_failed'),
	}
end

return M
