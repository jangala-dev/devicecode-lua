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

---iterates over a table of data to be published
---@param data table
function metrics_service:_publish_all(data)
    -- all first keys are the names of the publish protocols
    for protocol, values in pairs(data) do
        -- reset all pipelines after publish
        for endpoint, _ in pairs(values) do
            if self.pipelines[endpoint] then
                self.pipelines[endpoint]:reset()
            end
        end
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
    if field then
        value = value[field]
    end
    if value == nil then return end

    local str_endpoint = table.concat(rename or msg.topic, '/')

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
            time = math.floor(sc.realtime() * 1000)
        }
    end
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
    -- log any warnings and remove invalid metric configs
    if #warns > 0 then
        local warn_msgs = {}
        for _, warn in ipairs(warns) do
            table.insert(warn_msgs, warn.msg)
            if warn.endpoint then
                config.collections[warn.endpoint] = nil
            end
        end
        log.warn(string.format(
            "%s - %s: Metrics config warnings:\n\t%s",
            self.ctx:value('service_name'),
            self.ctx:value('fiber_name'),
            table.concat(warn_msgs, "\n\t")
        ))
    end

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

    local config_sub = self.conn:subscribe({ 'config', 'metrics' })
    local cloud_config_sub = self.conn:subscribe({ 'config', 'mainflux' })

    local next_publish_time = os.time() + math.huge

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
                next_publish_time = os.time() + self.publish_period
            end),
            cloud_config_sub:next_msg_op():wrap(function(config_msg)
                local config = conf.standardise_config(config_msg.payload)
                self.cloud_config = conf.merge_config(self.cloud_config, config)
            end),
            sleep.sleep_until_op(next_publish_time):wrap(function()
                local values = self.metric_values
                self.metric_values = {}
                next_publish_time = os.time() + self.publish_period
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
