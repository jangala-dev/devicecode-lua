local service = require 'service'
local op = require "fibers.op"
local log = require 'services.log'
local sc = require 'fibers.utils.syscall'
local sleep = require 'fibers.sleep'
local json = require 'cjson.safe'
local senml = require 'services.metrics.senml'
local http = require 'services.metrics.http'
local conf = require 'services.metrics.config'
local unpack = table.unpack or unpack

---@class metrics_service
---@field default_process ProcessPipeline
local metrics_service = {
    name = 'metrics',
    metrics = {},
    metric_values = {},
    pipelines = {},
}
metrics_service.__index = metrics_service

--- this is the only publish protocol
--- (for testing purposes)
--- @param data table
function metrics_service:_log_publish(data)
    local function print_recursive(t, indent)
        for k, v in pairs(t) do
            if type(v) == "table" then
                print(string.rep(" ", indent) .. k .. ":")
                print_recursive(v, indent + 2)
            else
                print(string.rep(" ", indent) .. k .. ": " .. tostring(v))
            end
        end
    end
    print_recursive(data, 0)
end

function metrics_service:_http_publish(data)
    local senml_list, err = senml.encode_r("", data)
    if err then
        log.error(string.format(
            "%s - %s: %s",
            self.ctx:value("service_name"),
            self.ctx:value("fiber_name"),
            err
        ))
        return
    end
    if #senml_list == 0 then return end
    local body = json.encode(senml_list)
    local valid_config, config_err = conf.validate_http_config(self.cloud_config)
    if not valid_config then
        log.error(string.format(
            "%s - %s: HTTP publish failed, reason: %s",
            self.ctx:value('service_name'),
            self.ctx:value('fiber_name'),
            config_err
        ))
        return
    end
    local channel_id
    for _, channel in ipairs(self.cloud_config.channels) do
        if channel.metadata and channel.metadata.channel_type == "data" then
            channel_id = channel.id
            break
        end
    end
    if channel_id == nil then
        log.error(string.format(
            "%s - %s: HTTP publish failed, reason: no channel id found",
            self.ctx:value('service_name'),
            self.ctx:value('fiber_name')
        ))
        return
    end
    local uri = string.format("%s/http/channels/%s/messages",
        self.cloud_config.url,
        channel_id
    )
    local auth = "Thing " .. self.cloud_config.thing_key
    local http_payload = {
        uri = uri,
        auth = auth,
        body = body
    }
    self.http_send_q:put_op(http_payload):perform_alt(function()
        log.error(string.format(
            "%s - %s: HTTP publish failed, reason: HTTP send queue is full",
            self.ctx:value('service_name'),
            self.ctx:value('fiber_name')
        ))
    end)
end

local function reset_pipelines(pipelines, metrics)
    for endpoint, _ in pairs(metrics) do
        if pipelines[endpoint] then
            pipelines[endpoint]:reset()
        end
    end
end

local function set_timestamps_realtime_millis(base_time, metrics)
    for _, metric in pairs(metrics) do
        metric.time = math.floor((base_time.real + (metric.time - base_time.mono))*1000)
    end
    return metrics
end

--- Validates that a topic array is properly formed with no gaps or nil values
--- @param topic table The topic array to validate
--- @return boolean true if the topic is valid (contiguous array with no nils), false otherwise
local function validate_topic(topic)
    if #topic == 0 then return false end

    -- Count all keys using pairs
    local pairs_count = 0
    for k, v in pairs(topic) do
        pairs_count = pairs_count + 1
        if type(k) ~= "number" or k < 1 or k ~= math.floor(k) then
            return false -- non-integer or non-positive key
        end
        if v == nil then
            return false -- explicit nil value
        end
    end

    -- If pairs_count equals #topic, array is contiguous with no gaps
    return pairs_count == #topic
end

---iterates over a table of data to be published
---@param data table
function metrics_service:_publish_all(data)
    -- all first keys are the names of the publish protocols
    for protocol, values in pairs(data) do
        -- reset all pipelines after publish
        reset_pipelines(self.pipelines, values)
        values = set_timestamps_realtime_millis(self.base_time, values)
        local protocol_fn = self["_" .. protocol .. "_publish"]
        if protocol_fn == nil then
            log.error(string.format('Failed to publish for %s, no function associated with protocol', protocol))
        else
            local ok, err = pcall(protocol_fn, self, values)
            if not ok then
                log.error(string.format("failed to publish with protocol %s: %s", protocol, err))
            end
        end
    end
end

function metrics_service:_handle_metric(metric, msg)
    local protocol = metric.protocol
    local field = metric.field
    local rename = metric.rename
    local base_pipeline = metric.base_pipeline

    local value = msg.payload
    if value == nil then return end
    if field then
        value = value[field]
    end
    if value == nil then return end

    local topic = rename or msg.topic
    if not validate_topic(topic) then
        log.warn(string.format(
            "%s - %s: Invalid topic array (nil value or gap detected), skipping metric",
            self.ctx:value('service_name'),
            self.ctx:value('fiber_name')
        ))
        return
    end

    local str_endpoint = table.concat(topic, '.')

    if self.pipelines[str_endpoint] == nil then
        self.pipelines[str_endpoint] = base_pipeline:clone()
    end

    local pipeline = self.pipelines[str_endpoint]

    local ret, short, err = pipeline:run(value)
    if err then
        log.error(string.format(
            "%s - %s: Metric processing error for endpoint %s: %s",
            self.ctx:value('service_name'),
            self.ctx:value('fiber_name'),
            str_endpoint,
            err
        ))
        return
    end
    if not short then
        self.metric_values[protocol] = self.metric_values[protocol] or {}
        self.metric_values[protocol][str_endpoint] = {
            value = ret,
            time = sc.monotime()
        }
    end
end

---Process validation warnings and remove invalid configs
---@param warns table
---@param config table
function metrics_service:_process_config_warnings(warns, config)
    if #warns == 0 then return end

    local warn_msgs = {}
    local dropped_metrics = {}
    local dropped_templates = {}

    for _, warn in ipairs(warns) do
        table.insert(warn_msgs, warn.msg)
        if warn.endpoint then
            if warn.type == "metric" then
                config.collections[warn.endpoint] = nil
                dropped_metrics[warn.endpoint] = true
            elseif warn.type == "template" then
                config.templates[warn.endpoint] = nil
                dropped_templates[warn.endpoint] = true
            end
        end
    end

    local summary_parts = {}
    local dropped_metric_list = {}
    for endpoint, _ in pairs(dropped_metrics) do
        table.insert(dropped_metric_list, endpoint)
    end
    if #dropped_metric_list > 0 then
        table.insert(summary_parts, string.format("Dropped %d metric(s): %s",
            #dropped_metric_list, table.concat(dropped_metric_list, ", ")))
    end

    local dropped_template_list = {}
    for endpoint, _ in pairs(dropped_templates) do
        table.insert(dropped_template_list, endpoint)
    end
    if #dropped_template_list > 0 then
        table.insert(summary_parts, string.format("Dropped %d template(s): %s",
            #dropped_template_list, table.concat(dropped_template_list, ", ")))
    end

    log.warn(string.format(
        "%s - %s: Metrics config warnings (invalid configs will be dropped):\n\t%s\n\nSummary: %s",
        self.ctx:value('service_name'),
        self.ctx:value('fiber_name'),
        table.concat(warn_msgs, "\n\t"),
        table.concat(summary_parts, "; ")
    ))
end

---use config to build cache and processing pipelines
---@param config table
function metrics_service:_handle_config(config)
    local valid, warns, err = conf.validate_config(config)
    if not valid then
        log.error(string.format(
            "%s - %s: Metrics config invalid: %s",
            self.ctx:value('service_name'),
            self.ctx:value('fiber_name'),
            err
        ))
        return
    end

    self:_process_config_warnings(warns, config)

    local metrics, publish_period, merged_cloud_config = conf.apply_config(self.conn, config, self.cloud_config)
    if #metrics == 0 then
        log.warn(string.format(
            "%s - %s: No valid metrics created, metrics service will be idle",
            self.ctx:value('service_name'),
            self.ctx:value('fiber_name')
        ))
    end

    -- clean up any old metric pipelines
    for _, metric in ipairs(self.metrics) do
        metric.sub:unsubscribe()
    end
    self.pipelines = {}
    self.metrics = metrics
    self.publish_period = publish_period
    self.cloud_config = merged_cloud_config
end

---setup initial cache and config then loop over config, metrics and timed cache operations
function metrics_service:_main(ctx)
    self.ctx = ctx
    self.http_send_q = http.start_http_publisher(self.ctx, self.conn)
    self.base_time = {
        synced = false,
        real = sc.realtime(),
        mono = sc.monotime()
    }

    local config_sub = self.conn:subscribe({ 'config', 'metrics' })
    local cloud_config_sub = self.conn:subscribe({ 'config', 'mainflux' })
    local time_sync_sub = self.conn:subscribe({ 'time', 'ntp_synced' })

    local next_publish_time = math.huge

    -- local device_info_sub = self.conn:subscribe({'system', 'device', 'idenitity'}) idk what this will be but
    -- it is a reminder to get system info that canopy will need for reporting

    while not self.ctx:err() do
        local metric_ops = {}
        for _, metric in ipairs(self.metrics) do
            table.insert(metric_ops, metric.sub:next_msg_op():wrap(function (msg)
                self:_handle_metric(metric, msg)
            end))
        end
        op.choice(
            self.ctx:done_op(),
            config_sub:next_msg_op():wrap(function(config_msg)
                self:_handle_config(config_msg.payload)
                next_publish_time = self.base_time.synced and (sc.monotime() + self.publish_period) or math.huge
            end),
            cloud_config_sub:next_msg_op():wrap(function(config_msg)
                local config = conf.standardise_config(config_msg.payload)
                self.cloud_config = conf.merge_config(self.cloud_config, config)
            end),
            time_sync_sub:next_msg_op():wrap(function(msg)
                if msg.payload == true then
                    if not self.base_time.synced then
                        -- First time sync - calculate real time at base and schedule first publish
                        self.base_time.synced = true
                        local real = sc.realtime()
                        local mono = sc.monotime()
                        local real_at_base = real - (mono - self.base_time.mono)
                        self.base_time.real = real_at_base
                        if self.publish_period then
                            next_publish_time = mono + self.publish_period
                        end
                    end
                else
                    self.base_time.synced = false
                    next_publish_time = math.huge
                end
            end),
            sleep.sleep_until_op(next_publish_time):wrap(function()
                local values = self.metric_values
                self.metric_values = {}
                next_publish_time = self.base_time.synced and (sc.monotime() + self.publish_period) or math.huge
                self:_publish_all(values)
            end),
            unpack(metric_ops)
        ):perform()
    end
    config_sub:unsubscribe()
    cloud_config_sub:unsubscribe()
    log.info("Metrics Service Ending")
end

---Creates the metrics fiber
---@param ctx Context
---@param conn Connection
function metrics_service:start(ctx, conn)
    log.info("Metrics Service Starting")
    self.conn = conn
    service.spawn_fiber('Main Fiber', conn, ctx, function(metrics_ctx)
        metrics_service:_main(metrics_ctx)
    end)
end

return metrics_service
