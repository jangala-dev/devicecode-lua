-- One-way compatibility profile for original Big Box MCU firmware.
--
-- The peer emits newline-delimited JSON objects whose slash-delimited keys are
-- metric namespaces. This is supervised as a Fabric link, but deliberately has
-- no Fabric session, RPC bridge, writer, or transfer manager.

local fibers      = require 'fibers'
local mailbox     = require 'fibers.mailbox'
local link_mod    = require 'services.fabric.link'
local state_mod   = require 'services.fabric.state'
local resource    = require 'devicecode.support.resource'
local bus_cleanup = require 'devicecode.support.bus_cleanup'
local tablex      = require 'shared.table'
local processor_mod = require 'services.fabric.profiles.legacy_mcu_metrics_v1.processor'

local M = {}

local shallow_copy = tablex.shallow_copy
local DEFAULT_STATE_QUEUE = 64

M.new_processor = processor_mod.new_processor
M.process_line = processor_mod.process_line

local function snapshot(processor, state, last_error)
	return {
		state = state,
		protocol = processor.profile_kind,
		lines = processor.lines,
		decoded = processor.decoded,
		decode_errors = processor.decode_errors,
		published = processor.published,
		unchanged = processor.unchanged,
		last_error = last_error,
		last_rx_at = processor.last_rx_at,
	}
end

local function publish_snapshot(state_tx, params, processor, state, last_error)
	local ok, err = state_mod.admit_component_snapshot_now(
		state_tx,
		params.link_id,
		params.link_generation,
		'legacy_metrics_reader',
		snapshot(processor, state, last_error),
		'legacy_mcu_metrics_state_admit_failed'
	)
	if ok ~= true then error(err or 'legacy MCU metrics state publish failed', 0) end
end

local function publish_metric(conn, args, metric_name, value, namespace)
	return bus_cleanup.retain(conn, {
		'obs', 'v1', args.publish_service, 'metric', metric_name,
	}, {
		value = value,
		namespace = namespace,
	})
end

local function run_reader(_, params, conn, state_tx)
	local protocol = params.protocol or {}
	local args = protocol.args or {}
	local processor = M.new_processor(args)
	processor.profile_kind = protocol.kind
	local cooldown = args.error_log_initial_s or 1
	local cooldown_max = args.error_log_max_s or 60
	local next_error_log_at = -math.huge
	local svc = params.svc

	publish_snapshot(state_tx, params, processor, 'running')
	while true do
		local line, read_err = fibers.perform(params.transport:read_line_op())
		if line == nil then
			publish_snapshot(state_tx, params, processor, 'stopped', read_err)
			return {
				role = 'legacy_metrics_reader',
				reason = read_err or 'eof',
				snapshot = snapshot(processor, 'stopped', read_err),
			}
		end

		processor.last_rx_at = fibers.now()
		local ok, err = M.process_line(processor, line, function(metric_name, value, namespace)
			return publish_metric(conn, args, metric_name, value, namespace)
		end)
		if ok ~= true then
			local now = fibers.now()
			if now >= next_error_log_at then
				if svc and type(svc.obs_log) == 'function' then
					svc:obs_log('error', {
						what = 'legacy_mcu_json_decode_failed',
						link_id = params.link_id,
						err = tostring(err),
						line = line,
					})
				end
				next_error_log_at = now + cooldown
				cooldown = math.min(cooldown * 2, cooldown_max)
			end
		end
		publish_snapshot(state_tx, params, processor, 'running', ok == true and nil or err)
	end
end

function M.run(scope, params, service_caps)
	if type(scope) ~= 'table' then error('legacy_mcu_metrics.run: scope required', 2) end
	if type(params) ~= 'table' then error('legacy_mcu_metrics.run: params required', 2) end
	local conn = params.conn or (service_caps and service_caps.conn)
	if conn == nil then error('legacy_mcu_metrics.run: bus connection required', 2) end
	if type(params.transport) ~= 'table' or type(params.transport.read_line_op) ~= 'function' then
		error('legacy_mcu_metrics.run: line transport required', 2)
	end

	scope:finally(function (_, status, primary)
		resource.terminate_checked(params.transport, primary or status or 'legacy MCU link closed',
			'legacy MCU transport cleanup failed')
	end)

	local state_tx, state_rx = mailbox.new(DEFAULT_STATE_QUEUE, { full = 'reject_newest' })
	local run_params = shallow_copy(params)
	run_params.svc = run_params.svc or (service_caps and service_caps.svc)
	run_params.state_tx = state_tx
	run_params.state_tx_owned = true
	run_params.state_projector_conn = conn
	run_params.state_projector_rx = state_rx
	run_params.state_projector_svc = (service_caps and service_caps.svc) or params.svc
	run_params.components = {
		{
			name = 'legacy_metrics_reader',
			run = function(component_scope)
				return run_reader(component_scope, run_params, conn, state_tx)
			end,
		},
	}
	return link_mod.run(scope, run_params)
end

return M
