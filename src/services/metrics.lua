-- services/metrics.lua
--
-- Metrics service:
--  - subscribes to {'obs', 'v1', '+', 'metric', '+'} for all observable metrics
--  - applies per-pipeline processing (DiffTrigger, DeltaValue, etc.)
--  - maintains per-endpoint processing state (shared pipeline logic, isolated state)
--  - periodically publishes accumulated metrics via http, log, or bus protocol
--  - fetches Mainflux cloud credentials from the HAL filesystem capability
--
-- Topics consumed:
--   {'obs', 'v1', '+', 'metric', '+'}  - incoming metric values
--   {'cfg', 'metrics'}                  - metrics config (retained)
--   {'svc', 'time', 'synced'}           - NTP sync status (retained)
--   {'cap', 'fs', 'configs', 'state'}   - HAL filesystem capability readiness
--
-- Topics produced:
--   {'svc', 'metrics', 'status'}        - service lifecycle status (retained)
--   {'svc', 'metrics', ...}             - per-metric bus publications (bus protocol)

local fibers         = require 'fibers'
local op             = require 'fibers.op'
local sleep          = require 'fibers.sleep'
local runtime        = require 'fibers.runtime'
local time           = require 'fibers.utils.time'
local perform        = fibers.perform

local json           = require 'cjson.safe'
local log            = require 'services.log'
local external_types = require 'services.hal.types.external'

local senml          = require 'services.metrics.senml'
local http_m         = require 'services.metrics.http'
local conf           = require 'services.metrics.config'
local types          = require 'services.metrics.types'


local unpack = unpack or rawget(table, 'unpack')

local NAME = 'metrics'

-------------------------------------------------------------------------------
-- Topic helpers
-------------------------------------------------------------------------------

---@param name string
---@return table
local function t_svc_status(name) return { 'svc', name, 'status' } end

---@param service string
---@param name string
---@return table
local function t_obs_metric(service, name) return { 'obs', 'v1', service, 'metric', name } end

---@param name string
---@return table
local function t_cfg(name) return { 'cfg', name } end

---@return table
local function t_time_ntp_synced() return { 'svc', 'time', 'synced' } end

---@return table
local function t_cap_fs_state() return { 'cap', 'fs', 'configs', 'state' } end

---@param method string
---@return table
local function t_cap_fs_rpc(method) return { 'cap', 'fs', 'configs', 'rpc', method } end

---@param tokens table
---@return table
local function t_svc_metrics_bus(tokens) return { 'svc', 'metrics', unpack(tokens) } end

---@return number
local function now() return runtime.now() end

---@return number
local function now_real() return time.realtime() end

---@param conn Connection
---@param name string
---@param state string
---@param extra table?
local function publish_status(conn, name, state, extra)
	local payload = { state = state, ts = now() }
	if type(extra) == 'table' then
		for k, v in pairs(extra) do payload[k] = v end
	end
	conn:retain(t_svc_status(name), payload)
end

-------------------------------------------------------------------------------
-- Metric helpers
-------------------------------------------------------------------------------

--- Validate a topic array (no gaps, no nils, at least one element).
---@param topic any
---@return boolean
local function validate_topic(topic)
	if type(topic) ~= 'table' then return false end
	local count = 0
	for k in pairs(topic) do
		if type(k) ~= 'number' or k < 1 or k ~= math.floor(k) then return false end
		count = count + 1
	end
	if count == 0 then return false end
	for i = 1, count do
		if topic[i] == nil then return false end
	end
	return true
end

--- Shift per-endpoint metric timestamps from monotonic to real-time milliseconds.
--- base_time = { real = wall_clock_at_mono_base, mono = mono_at_base }
---@param base_time BaseTime
---@param metrics table
---@return table
local function set_timestamps_realtime_millis(base_time, metrics)
	for _, metric in pairs(metrics) do
		metric.time = math.floor((base_time.real + (metric.time - base_time.mono)) * 1000)
	end
	return metrics
end

-------------------------------------------------------------------------------
-- Config warnings (pure: no service state)
-------------------------------------------------------------------------------

--- Log config warnings and prune invalid entries from the raw config in-place.
---@param warns table
---@param config table
local function process_config_warnings(warns, config)
	if #warns == 0 then return end

	local warn_msgs         = {}
	local dropped_metrics   = {}
	local dropped_templates = {}

	for _, warn in ipairs(warns) do
		table.insert(warn_msgs, warn.msg)
		if warn.endpoint then
			if warn.type == 'metric' then
				config.pipelines[warn.endpoint] = nil
				dropped_metrics[warn.endpoint]  = true
			elseif warn.type == 'template' then
				if config.templates then
					config.templates[warn.endpoint] = nil
				end
				dropped_templates[warn.endpoint] = true
			end
		end
	end

	local summary_parts = {}

	local dm_list = {}
	for ep in pairs(dropped_metrics) do dm_list[#dm_list + 1] = ep end
	if #dm_list > 0 then
		table.insert(summary_parts, string.format(
			'Dropped %d metric(s): %s', #dm_list, table.concat(dm_list, ', ')))
	end

	local dt_list = {}
	for ep in pairs(dropped_templates) do dt_list[#dt_list + 1] = ep end
	if #dt_list > 0 then
		table.insert(summary_parts, string.format(
			'Dropped %d template(s): %s', #dt_list, table.concat(dt_list, ', ')))
	end

	log.warn(string.format(
		'metrics: config warnings (invalid entries will be dropped):\n\t%s\n\nSummary: %s',
		table.concat(warn_msgs, '\n\t'),
		table.concat(summary_parts, '; ')))
end

-------------------------------------------------------------------------------
-- Service state
-------------------------------------------------------------------------------

---@type ServiceState
local State = {
	conn             = nil,
	name             = nil,
	http_send_ch     = nil,
	pipelines_map    = {},
	metric_states    = {},
	endpoint_to_pipe = {},
	metric_values    = {},
	publish_period   = nil,
	cloud_url        = nil,
	mainflux_config  = nil,
	cloud_config     = nil,
	base_time        = nil,
}

-------------------------------------------------------------------------------
-- Cloud config
-------------------------------------------------------------------------------

local function rebuild_cloud_config()
	local mf = State.mainflux_config
	if not mf or not State.cloud_url or not mf.thing_key or not mf.channels then
		State.cloud_config = nil
		return
	end
	local cfg, cfg_err = types.new.CloudConfig(State.cloud_url, mf.thing_key, mf.channels)
	if not cfg then
		log.warn('metrics: failed to build cloud config: ' .. tostring(cfg_err))
		State.cloud_config = nil
		return
	end
	State.cloud_config = cfg
end

local function fetch_mainflux_config()
	local read_opts, opts_err = external_types.new.FilesystemReadOpts('mainflux.cfg')
	if not read_opts then
		log.warn('metrics: failed to build mainflux.cfg read opts:', tostring(opts_err))
		return
	end

	local reply, err = State.conn:call(t_cap_fs_rpc('read'), read_opts)
	if not reply then
		log.warn('metrics: failed to read mainflux.cfg:', tostring(err))
		return
	end
	if reply.ok ~= true then
		log.warn('metrics: mainflux.cfg read failed:', tostring(reply.reason))
		return
	end

	local raw, decode_err = json.decode(reply.reason)
	if not raw then
		log.warn('metrics: failed to decode mainflux.cfg:', tostring(decode_err))
		return
	end

	State.mainflux_config = conf.standardise_config(raw)
	rebuild_cloud_config()
end

-------------------------------------------------------------------------------
-- Protocol publish handlers
-------------------------------------------------------------------------------

---@param data table<string, MetricSample>
local function bus_publish(data)
	for endpoint_str, metric in pairs(data) do
		local tokens = {}
		for part in endpoint_str:gmatch('[^.]+') do
			tokens[#tokens + 1] = part
		end
		State.conn:publish(t_svc_metrics_bus(tokens), { value = metric.value, time = metric.time })
	end
end

---@param data table<string, MetricSample>
local function log_publish(data)
	for endpoint_str, metric in pairs(data) do
		log.info(string.format('metrics: %s = %s (t=%s)',
			endpoint_str, tostring(metric.value), tostring(metric.time)))
	end
end

---@param data table<string, MetricSample>
local function http_publish(data)
	local senml_list, encode_err = senml.encode_r('', data)
	if encode_err then
		log.error('metrics: SenML encode failed: ' .. tostring(encode_err))
		return
	end
	if #senml_list == 0 then return end

	local body = json.encode(senml_list)

	local valid, config_err = conf.validate_http_config(State.cloud_config)
	if not valid then
		log.error('metrics: HTTP publish skipped, invalid cloud config: ' .. tostring(config_err))
		return
	end

	local channel_id
	for _, ch in ipairs(State.cloud_config.channels) do
		if ch.metadata and ch.metadata.channel_type == 'data' then
			channel_id = ch.id
			break
		end
	end
	if channel_id == nil then
		log.error('metrics: HTTP publish failed, no data channel id found')
		return
	end

	local uri   = string.format('%s/http/channels/%s/messages',
		State.cloud_config.url, channel_id)
	local auth  = 'Thing ' .. State.cloud_config.thing_key

	-- Non-blocking enqueue: drop and log if the channel is at capacity.
	local full = perform(State.http_send_ch:put_op({ uri = uri, auth = auth, body = body })
		:or_else(function() return true end))

	if full then
		log.error('metrics: HTTP send queue full, dropping publish payload')
	end
end

local publish_fns = { bus = bus_publish, log = log_publish, http = http_publish }

---@param values table<string, table<string, MetricSample>>
local function publish_all(values)
	for protocol, pv in pairs(values) do
		-- Reset per-endpoint pipeline states for published endpoints.
		for endpoint_str, _ in pairs(pv) do
			local metric_name = State.endpoint_to_pipe[endpoint_str]
			if metric_name then
				local pipe_cfg = State.pipelines_map[metric_name]
				if pipe_cfg and State.metric_states[endpoint_str] then
					pipe_cfg.pipeline:reset(State.metric_states[endpoint_str])
				end
			end
		end

		pv = set_timestamps_realtime_millis(State.base_time, pv)

		local fn = publish_fns[protocol]
		if fn == nil then
			log.error('metrics: no publish function for protocol: ' .. tostring(protocol))
		else
			fn(pv)
		end
	end
end

-------------------------------------------------------------------------------
-- Metric handling
-------------------------------------------------------------------------------

---@param msg Message?
local function handle_metric(msg)
	if not msg then return end

	-- Topic layout: {'obs', 'v1', <service>, 'metric', <metric_name>}
	local metric_name = msg.topic and msg.topic[5]
	if not metric_name then return end

	local pipe_cfg = State.pipelines_map[metric_name]
	if not pipe_cfg then return end -- no matching pipeline, drop silently

	local payload = msg.payload
	if type(payload) ~= 'table' then return end

	local value = payload.value
	if value == nil then return end

	-- Optional namespace overrides the topic used as the SenML name and state key.
	local topic = payload.namespace or msg.topic
	if not validate_topic(topic) then
		log.warn('metrics: received metric with invalid topic array, skipping')
		return
	end

	local endpoint_str = table.concat(topic, '.')

	-- Get-or-create per-endpoint processing state.
	if not State.metric_states[endpoint_str] then
		State.metric_states[endpoint_str]    = pipe_cfg.pipeline:new_state()
		State.endpoint_to_pipe[endpoint_str] = metric_name
	end

	local ret, short, err = pipe_cfg.pipeline:run(value, State.metric_states[endpoint_str])
	if err then
		log.error(string.format(
			'metrics: pipeline error for [%s]: %s', endpoint_str, tostring(err)))
		return
	end

	if not short then
		State.metric_values[pipe_cfg.protocol] = State.metric_values[pipe_cfg.protocol] or {}
		State.metric_values[pipe_cfg.protocol][endpoint_str] = types.new.MetricSample(ret, now())
	end
end

-------------------------------------------------------------------------------
-- Config handling
-------------------------------------------------------------------------------

---@param payload table?
---@return number next_publish_time
local function handle_config(payload)
	if not payload then return math.huge end

	local valid, warns, err = conf.validate_config(payload)
	if not valid then
		log.error('metrics: invalid config received: ' .. tostring(err))
		return math.huge
	end

	process_config_warnings(warns, payload)

	local new_pipelines_map, new_publish_period = conf.apply_config(payload)

	if next(new_pipelines_map) == nil then
		log.warn('metrics: no valid pipelines after config apply; service will be idle')
	end

	-- Cache cloud_url from the metrics config and rebuild cloud_config.
	State.cloud_url = payload.cloud_url
	rebuild_cloud_config()

	-- Replace all pipeline state (logic may have changed).
	State.pipelines_map    = new_pipelines_map
	State.metric_states    = {}
	State.endpoint_to_pipe = {}
	State.publish_period   = new_publish_period

	if State.base_time.synced and State.publish_period then
		return now() + State.publish_period
	end
	return math.huge
end

---@param synced boolean
---@return boolean first_sync
local function handle_time_sync(synced)
	if synced == true then
		if not State.base_time.synced then
			State.base_time.synced = true
			local real = now_real()
			local mono = now()
			-- Compute the wall-clock time that corresponds to base_time.mono.
			State.base_time.real = real - (mono - State.base_time.mono)
			return true -- first sync
		end
	else
		State.base_time.synced = false
	end
	return false
end

-------------------------------------------------------------------------------
-- Main loop
-------------------------------------------------------------------------------

---@return boolean ok
local function wait_for_fs_capability()
	local sub = State.conn:subscribe(
		t_cap_fs_state(),
		{ queue_len = 10, full = 'drop_oldest' })

	while true do
		local msg, err = perform(sub:recv_op())
		if not msg then
			log.warn('metrics: filesystem capability subscription closed:', tostring(err))
			sub:unsubscribe()
			return false
		end
		if msg.payload == 'added' then
			sub:unsubscribe()
			return true
		end
	end
end

local function main()
	-- Subscribe to all observable metrics.
	local obs_sub = State.conn:subscribe(
		t_obs_metric('+', '+'),
		{ queue_len = 100, full = 'drop_oldest' })

	-- Subscribe to the metrics config (retained; first message is current config).
	local cfg_sub = State.conn:subscribe(
		t_cfg(NAME),
		{ queue_len = 10, full = 'drop_oldest' })

	-- Subscribe to NTP sync status.
	local time_sub = State.conn:subscribe(
		t_time_ntp_synced(),
		{ queue_len = 5, full = 'drop_oldest' })

	local next_publish_time = math.huge

	while true do
		local which, a, b = perform(op.named_choice({
			config   = cfg_sub:recv_op(),
			metric   = obs_sub:recv_op(),
			timesync = time_sub:recv_op(),
			-- timesync = State.base_time.synced and op.never() or op.always({ payload = true }),
			tick     = sleep.sleep_until_op(next_publish_time),
		}))


		if which == 'config' then
			local msg, err = a, b
			if not msg then
				log.warn('metrics: config subscription closed:', tostring(err))
				break
			end
			next_publish_time = handle_config(msg.payload)
			-- Re-read mainflux.cfg in case cloud_url or credentials changed.
			fetch_mainflux_config()
		elseif which == 'metric' then
			local msg = a
			if msg then
				handle_metric(msg)
			end
		elseif which == 'timesync' then
			local msg = a
			if msg then
				local first_sync = handle_time_sync(msg.payload)
				if first_sync and State.publish_period then
					next_publish_time = now() + State.publish_period
				elseif not State.base_time.synced then
					next_publish_time = math.huge
				end
			end
		elseif which == 'tick' then
			local values        = State.metric_values
			State.metric_values = {}

			if State.base_time.synced and State.publish_period then
				next_publish_time = now() + State.publish_period
			else
				next_publish_time = math.huge
			end

			publish_all(values)
		end
	end

	obs_sub:unsubscribe()
	cfg_sub:unsubscribe()
	time_sub:unsubscribe()
	log.info('metrics: service stopping')
end

-------------------------------------------------------------------------------
-- Module entry point
-------------------------------------------------------------------------------

local M = {}

---@param conn Connection
---@param opts table?
function M.start(conn, opts)
	opts = opts or {}
	local name = opts.name or NAME

	publish_status(conn, name, 'starting')

	State.conn             = conn
	State.name             = name
	State.http_send_ch     = http_m.start_http_publisher()
	State.pipelines_map    = {}
	State.metric_states    = {}
	State.endpoint_to_pipe = {}
	State.metric_values    = {}
	State.publish_period   = nil
	State.cloud_url        = nil
	State.mainflux_config  = nil
	State.cloud_config     = nil
	State.base_time        = types.new.BaseTime(now_real(), now())

	fibers.current_scope():finally(function(_, st, primary)
		local reason = primary or st
		log.info(('metrics: scope closed (status: %s, reason: %s)'):format(tostring(st), tostring(primary)))
		publish_status(conn, name, 'stopped', reason and { reason = tostring(reason) } or nil)
	end)

	local fs_ok = wait_for_fs_capability()
	if not fs_ok then
		publish_status(conn, name, 'error', { reason = 'filesystem capability unavailable' })
		return
	end

	fetch_mainflux_config()

	publish_status(conn, name, 'running')

	main()
end

return M
