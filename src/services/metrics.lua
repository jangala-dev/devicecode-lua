-- services/metrics.lua
--
-- Transitional metrics pipeline: long-term, metrics should observe retained
-- domain /state and derive export series from those models. Services may
-- still publish legacy obs metrics during migration, but UI-critical state
-- should live under /state.
--
-- Metrics service:
--  - subscribes to {'obs', 'v1', '+', 'metric', '+'} for all observable metrics
--  - applies per-pipeline processing (DiffTrigger, DeltaValue, etc.)
--  - maintains per-endpoint processing state (shared pipeline logic, isolated state)
--  - periodically publishes accumulated metrics via http, log, or bus protocol
--  - fetches Mainflux cloud credentials from the HAL filesystem capability
--
-- Topics consumed:
--   {'obs', 'v1', '+', 'metric', '+'}       - incoming metric values
--   {'cfg', 'metrics'}                       - metrics config (retained)
--   {'state', 'time', 'synced'}              - NTP sync status (retained)
--   {'cap', 'fs', 'configs', ...}             - HAL filesystem capability (via cap listener)
--   {'cap', 'http', 'main', 'rpc', ...}      - HTTP capability service (exchange RPC)
--
-- Topics produced:
--   {'svc', 'metrics', 'status'}             - service lifecycle status (retained)
--   {'obs', 'v1', 'metrics', 'output', ...}  - per-metric bus publications (bus protocol)

local fibers         = require 'fibers'
local op             = require 'fibers.op'
local sleep          = require 'fibers.sleep'
local runtime        = require 'fibers.runtime'
local time           = require 'fibers.utils.time'
local perform        = fibers.perform

local json           = require 'cjson.safe'
local base           = require 'devicecode.service_base'
local cap_sdk        = require 'services.hal.sdk.cap'
local http_sdk       = require('services.http').sdk

local senml          = require 'services.metrics.senml'
local http_m         = require 'services.metrics.http'
local conf           = require 'services.metrics.config'
local types          = require 'services.metrics.types'


local unpack = unpack or rawget(table, 'unpack')

local NAME = 'metrics'
local HTTP_MAX_RECORDS = 25

-------------------------------------------------------------------------------
-- Topic helpers
-------------------------------------------------------------------------------

---@param service string
---@param name string
---@return table
local function t_obs_metric(service, name) return { 'obs', 'v1', service, 'metric', name } end

---@param name string
---@return table
local function t_cfg(name) return { 'cfg', name } end

---@return table
local function t_state_time_synced() return { 'state', 'time', 'synced' } end

---@param tokens table
---@return table
local function t_obs_metrics_output(tokens) return { 'obs', 'v1', 'metrics', 'output', unpack(tokens) } end

---@return number
local function now() return runtime.now() end

---@return number
local function now_real() return time.realtime() end

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
-- Service state
-------------------------------------------------------------------------------

---@type ServiceState
local State = {
	conn             = nil,
	svc              = nil,
	name             = nil,
	http_ref         = nil,
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
	fs_cap           = nil,
}

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

	local dm_list = {}
	for ep in pairs(dropped_metrics) do dm_list[#dm_list + 1] = ep end

	local dt_list = {}
	for ep in pairs(dropped_templates) do dt_list[#dt_list + 1] = ep end

	State.svc:obs_log('warn', {
		what             = 'config_warnings',
		warnings         = warn_msgs,
		dropped_metrics  = dm_list,
		dropped_templates = dt_list,
	})
end

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
		State.svc:obs_log('warn', { what = 'cloud_config_build_failed', err = tostring(cfg_err) })
		State.cloud_config = nil
		return
	end
	State.cloud_config = cfg
	State.svc:obs_log('debug', 'cloud config ready')
end

local function fetch_mainflux_config()
	local read_opts, opts_err = cap_sdk.args.new.FilesystemReadOpts('mainflux.cfg')
	if not read_opts then
		State.svc:obs_log('warn', { what = 'mainflux_read_opts_failed', err = tostring(opts_err) })
		return
	end

	local reply, err = State.fs_cap:call_control('read', read_opts)
	if not reply then
		State.svc:obs_log('warn', { what = 'mainflux_read_failed', err = tostring(err) })
		return
	end
	if reply.ok ~= true then
		State.svc:obs_log('warn', { what = 'mainflux_read_error', err = tostring(reply.reason) })
		return
	end

	local raw, decode_err = json.decode(reply.reason)
	if not raw then
		State.svc:obs_log('warn', { what = 'mainflux_decode_failed', err = tostring(decode_err) })
		return
	end

	State.mainflux_config = conf.standardise_config(raw)
	State.svc:obs_log('debug', 'mainflux config loaded')
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
		State.conn:publish(t_obs_metrics_output(tokens), { value = metric.value, time = metric.time })
	end
end

---@param data table<string, MetricSample>
local function log_publish(data)
	for endpoint_str, metric in pairs(data) do
		State.svc:obs_log('trace', { what = 'metric_value',
			endpoint = endpoint_str, value = metric.value, time = metric.time })
	end
end

local function sorted_metric_keys(data)
	local keys = {}
	for endpoint_str in pairs(data or {}) do keys[#keys + 1] = endpoint_str end
	table.sort(keys)
	return keys
end

local function metric_chunks(data, max_records)
	local keys = sorted_metric_keys(data)
	local chunks = {}
	if #keys == 0 then return chunks end

	local limit = tonumber(max_records) or #keys
	if limit < 1 then limit = #keys end

	for i = 1, #keys, limit do
		local chunk = {}
		for j = i, math.min(i + limit - 1, #keys) do
			local key = keys[j]
			chunk[key] = data[key]
		end
		chunks[#chunks + 1] = chunk
	end
	return chunks
end

---@param data table<string, MetricSample>
local function http_publish(data)
	local valid, config_err = conf.validate_http_config(State.cloud_config)
	if not valid then
		State.svc:obs_log('error', { what = 'http_publish_skipped', err = tostring(config_err) })
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
		State.svc:obs_log('error', { what = 'http_publish_failed', err = 'no data channel id found' })
		return
	end

	local uri   = string.format('%s/http/channels/%s/messages',
		State.cloud_config.url, channel_id)
	local auth  = 'Thing ' .. State.cloud_config.thing_key

	local chunks = metric_chunks(data, HTTP_MAX_RECORDS)
	for chunk_index, chunk in ipairs(chunks) do
		local senml_list, encode_err = senml.encode_r('', chunk)
		if encode_err then
			State.svc:obs_log('error', {
				what = 'senml_encode_failed',
				err = tostring(encode_err),
				chunk_index = chunk_index,
				chunk_count = #chunks,
			})
		elseif #senml_list > 0 then
			local body = json.encode(senml_list)

			-- Non-blocking enqueue: drop and log if the channel is at capacity.
			local full = perform(State.http_send_ch:put_op({ uri = uri, auth = auth, body = body })
				:or_else(function() return true end))

			if full then
				State.svc:obs_log('error', {
					what = 'http_queue_full',
					err = 'dropping publish payload',
					chunk_index = chunk_index,
					chunk_count = #chunks,
				})
			end
		end
	end
end


local function count_pipelines()
	local n = 0
	for _ in pairs(State.pipelines_map or {}) do n = n + 1 end
	return n
end

local function log_metrics_summary(reason, extra)
	local parts = {}
	parts[#parts + 1] = 'publishing=' .. ((State.publish_period and State.base_time and State.base_time.synced) and 'enabled' or 'waiting')
	if State.publish_period then parts[#parts + 1] = 'interval=' .. tostring(State.publish_period) .. 's' end
	parts[#parts + 1] = 'pipelines=' .. tostring(count_pipelines())
	local summary = 'metrics summary ' .. table.concat(parts, ' ')
	local tnow = now()
	if State._operator_summary_key == summary and (tnow - (State._operator_summary_at or 0)) < 600 then return end
	State._operator_summary_key = summary
	State._operator_summary_at = tnow
	State.svc:obs_log('info', { what = 'metrics_summary', summary = summary, reason = reason })
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
			State.svc:obs_log('error', { what = 'unknown_protocol', protocol = tostring(protocol) })
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
	local payload = msg.payload
	if not pipe_cfg then return end -- no matching pipeline, drop silently

	if type(payload) ~= 'table' then return end

	local value = payload.value
	if value == nil then return end

	-- Optional namespace overrides the topic used as the SenML name and state key.
	local topic = payload.namespace or msg.topic
	if not validate_topic(topic) then
		State.svc:obs_log('warn', { what = 'metric_invalid_topic', metric = metric_name })
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
		State.svc:obs_log('error', { what = 'pipeline_error', endpoint = endpoint_str, err = tostring(err) })
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
		State.svc:obs_log('error', { what = 'config_invalid', err = tostring(err) })
		State.svc:obs_event('config_rejected', { err = tostring(err) })
		return math.huge
	end

	process_config_warnings(warns, payload)

	local log_fn = function(level, msg) State.svc:obs_log(level, msg) end
	local new_pipelines_map, new_publish_period = conf.apply_config(payload, log_fn)

	if next(new_pipelines_map) == nil then
		State.svc:obs_log('warn', { what = 'config_no_pipelines' })
	end

	-- Cache cloud_url from the metrics config and rebuild cloud_config.
	State.cloud_url = payload.data and payload.data.cloud_url
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
		t_state_time_synced(),
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
				State.svc:obs_log('warn', { what = 'config_sub_closed', err = tostring(err) })
				break
			end
			State.svc:obs_log('debug', 'config received, applying')
			next_publish_time = handle_config(msg.payload)
			-- Re-read mainflux.cfg in case cloud_url or credentials changed.
			fetch_mainflux_config()
			local next_s = next_publish_time == math.huge and nil or (next_publish_time - now())
			State.svc:obs_event('config_applied', { next_publish_s = next_s })
			State.svc:obs_log('debug', next_s
				and string.format('config applied, next publish in %.1fs', next_s)
				or 'config applied, publishing suspended (waiting for NTP sync)')
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
					State.svc:obs_event('ntp_synced', { first = true, next_publish_s = State.publish_period })
					State.svc:obs_log('info', { what = 'metrics_ready', summary = string.format('metrics ready; next publish in %ss', tostring(State.publish_period)), next_publish_s = State.publish_period })
				elseif first_sync then
					State.svc:obs_event('ntp_synced', { first = true })
					State.svc:obs_log('debug', 'NTP synced, waiting for config before scheduling publish')
				elseif not State.base_time.synced then
					next_publish_time = math.huge
					State.svc:obs_event('ntp_lost', {})
					State.svc:obs_log('debug', { what = 'ntp_lost' })
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

			local total = 0
			for _, pv in pairs(values) do
				for _ in pairs(pv) do total = total + 1 end
			end
			State.svc:obs_event('publish', { count = total })
			if total > 0 then
				State.svc:obs_log('debug', string.format('publishing %d metric(s)', total))
			end
			publish_all(values)
		end
	end

	obs_sub:unsubscribe()
	cfg_sub:unsubscribe()
	time_sub:unsubscribe()
	State.svc:obs_log('debug', 'service stopping')
end

-------------------------------------------------------------------------------
-- Module entry point
-------------------------------------------------------------------------------

local M = {}

---@param conn Connection
---@param opts table?
function M.start(conn, opts)
	opts = opts or {}
	local name        = opts.name or NAME
	local heartbeat_s = (type(opts.heartbeat_s) == 'number') and opts.heartbeat_s or 30.0

	local svc = base.new(conn, { name = name, env = opts.env })

	svc:obs_state('boot', { at = svc:wall(), ts = svc:now(), state = 'entered' })
	svc:obs_log('debug', 'service start() entered')
	svc:announce({})
	svc:starting()
	svc:spawn_heartbeat(heartbeat_s, 'tick')

	State.conn             = conn
	State.svc              = svc
	State.name             = name
	State.http_ref         = http_sdk.new_ref(conn, opts.http_service_id or 'main')
	State.http_send_ch     = http_m.start_http_publisher(State.http_ref, function(level, payload)
		svc:obs_log(level, payload)
	end)
	State.pipelines_map    = {}
	State.metric_states    = {}
	State.endpoint_to_pipe = {}
	State.metric_values    = {}
	State.publish_period   = nil
	State.cloud_url        = nil
	State.mainflux_config  = nil
	State.cloud_config     = nil
	State.base_time        = types.new.BaseTime(now_real(), now())
	State.fs_cap           = nil

	fibers.current_scope():finally(function()
		local _, primary = fibers.current_scope():status()
		svc:lifecycle('stopped', { ready = false, reason = tostring(primary or 'scope_exit') })
		svc:obs_log('debug', 'service stopped')
	end)

	svc:obs_log('debug', 'waiting for filesystem capability')
	local fs_listener = cap_sdk.new_cap_listener(conn, 'fs', 'credentials')
	local fs_cap, cap_err = fs_listener:wait_for_cap()
	fs_listener:close()
	if not fs_cap then
		svc:failed('filesystem capability unavailable')
		svc:obs_log('error', { what = 'start_failed', err = tostring(cap_err) })
		return
	end
	State.fs_cap = fs_cap

	svc:obs_event('fs_ready', {})
	svc:obs_log('debug', 'fetching mainflux config')
	fetch_mainflux_config()

	svc:running()
	svc:obs_log('debug', 'service is live')

	main()
end

return M
