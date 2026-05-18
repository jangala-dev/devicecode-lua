-- services/net/apply_runtime.lua
-- Scoped apply work for NET.

local fibers = require 'fibers'
local scoped_work = require 'devicecode.support.scoped_work'
local queue = require 'devicecode.support.queue'

local M = {}

local function make_identity(service_id, generation, apply_id)
	return {
		kind = 'net_apply_done',
		service_id = service_id,
		generation = generation,
		apply_id = apply_id,
	}
end

function M.start_apply(spec)
	if type(spec) ~= 'table' then return nil, 'start_apply spec required' end
	local lifetime_scope = spec.lifetime_scope
	local hal = spec.hal
	local intent = spec.intent
	local done_tx = spec.done_tx
	local generation = spec.generation
	local apply_id = spec.apply_id
	local service_id = spec.service_id or 'net'

	if not lifetime_scope then return nil, 'lifetime_scope required' end
	if not hal then return nil, 'hal client required' end
	if not intent then return nil, 'intent required' end
	if not done_tx then return nil, 'done_tx required' end
	if type(generation) ~= 'number' then return nil, 'generation required' end
	if type(apply_id) ~= 'number' then return nil, 'apply_id required' end

	return scoped_work.start {
		lifetime_scope = lifetime_scope,
		reaper_scope = spec.reaper_scope or lifetime_scope,
		report_scope = spec.report_scope or lifetime_scope,
		identity = make_identity(service_id, generation, apply_id),

		run = function ()
			local result = fibers.perform(hal:apply_intent_op(intent, {
				generation = generation,
				apply_id = apply_id,
			}))
			return {
				intent_rev = intent.rev,
				ok = result and result.ok == true,
				result = result,
			}
		end,

		report = function (ev)
			return queue.try_admit_required(
				done_tx,
				ev,
				'net_apply_completion_report_failed'
			)
		end,
	}
end

return M
