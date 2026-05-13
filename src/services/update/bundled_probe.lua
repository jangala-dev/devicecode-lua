-- services/update/bundled_probe.lua
--
-- Scoped desired-artifact probing for bundled update policy.

local fibers = require 'fibers'
local scoped_work = require 'devicecode.support.scoped_work'
local queue = require 'devicecode.support.queue'

local M = {}

function M.run(scope, params)
	params = params or {}
	local store = assert(params.artifact_store, 'bundled_probe: artifact_store required')
	local source = assert(params.source, 'bundled_probe: source required')
	local result, err = fibers.perform(store:probe_op(source))
	if result == nil then error(err or 'bundled_probe_failed', 0) end
	return {
		tag = 'bundled_desired',
		component = params.component,
		desired = result,
	}
end

function M.start(spec)
	spec = spec or {}
	return scoped_work.start {
		lifetime_scope = assert(spec.lifetime_scope, 'lifetime_scope required'),
		reaper_scope   = spec.reaper_scope or spec.lifetime_scope,
		report_scope   = assert(spec.report_scope or spec.lifetime_scope, 'report_scope required'),

		identity = {
			kind       = 'bundled_probe_done',
			service_id = spec.service_id,
			generation = spec.generation,
			component  = spec.component,
		},

		run = function (scope)
			return M.run(scope, spec)
		end,

		report = function (ev)
			if not spec.done_tx then return true, nil end
			return queue.try_admit_required(
				spec.done_tx,
				ev,
				'update_bundled_probe_completion_report_failed'
			)
		end,
	}
end

return M
