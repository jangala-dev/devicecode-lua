-- services/update/backends/component_proxy.lua
--
-- Generic device-component update backend.
--
-- Backend contract:
--   * prepare(conn, job, ctx)
--   * stage(conn, job, ctx)
--   * commit(conn, job, ctx)
--   * evaluate(job, component_state)
--   * observe_specs(component_cfg) -> optional observer feed descriptions
--
-- This backend talks to the device service's generic component RPC surface and
-- leaves component-specific reconcile policy to the caller.

local device_topics = require 'services.device.topics'

local M = {}

function M.new(opts)
	opts = opts or {}

	local component = opts.component or 'component'
	local retention = opts.artifact_retention
	local timeout_prepare = opts.timeout_prepare or 10.0
	local timeout_stage = opts.timeout_stage or 60.0
	local timeout_commit = opts.timeout_commit or 10.0
	local evaluate_fn = assert(opts.reconcile, 'reconcile fn required')

	local backend = {}

	local function device_call(conn, op_name, args, timeout)
		return conn:call(device_topics.component_cap_rpc(component, op_name), args or {}, { timeout = timeout })
	end

	function backend:prepare(conn, job, _ctx)
		return device_call(conn, 'prepare-update', {
			target = job.component,
			metadata = job.metadata,
		}, timeout_prepare)
	end

	function backend:stage(conn, job, _ctx)
		local value, err = device_call(conn, 'stage-update', {
			artifact_ref = job.artifact_ref,
			job_id = job.job_id,
			metadata = job.metadata,
			expected_image_id = job.expected_image_id,
		}, timeout_stage)
		if value == nil then return nil, err end
		if type(value) == 'table' and value.artifact_retention == nil then
			value.artifact_retention = retention
		end
		return value, nil
	end

	function backend:commit(conn, job, _ctx)
		return device_call(conn, 'commit-update', {
			mode = job.component,
			metadata = job.metadata,
		}, timeout_commit)
	end

	function backend:evaluate(job, component_state)
		return evaluate_fn(component_state, job)
	end

	function backend:observe_specs(_component_cfg)
		return {
			{
				key = 'component:' .. component,
				topic = { 'state', 'device', 'component', component },
				on_event = function(ctx, _rec, ev)
					if type(ev) == 'table' and ev.op == 'retain' and type(ev.payload) == 'table' then
						ctx.observer:note_component(component, ev.payload)
					elseif type(ev) == 'table' and ev.op == 'unretain' then
						ctx.observer:clear_component(component)
					end
				end,
			},
		}
	end

	return backend
end

return M
