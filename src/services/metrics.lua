local reactive_cache = require 'services.metrics.action_cache'
local processing = require "services.metrics.processing"
local timed_cache = require "services.metrics.timed_cache"
local service = require 'service'
local op = require "fibers.op"
local log = require 'log'
local trie = require 'trie'
local sc = require 'fibers.utils.syscall'
local json = require 'cjson.safe'
local request = require 'http.request'
local senml = require 'services.metrics.senml'
local unpack = table.unpack or unpack

---@class metrics_service
---@field str_trie Trie
---@field default_process ProcessPipeline
local metrics_service = {
    name = 'metrics',
    metric_ops = {},
    str_trie = trie.new_string(nil, nil, '/')
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

local function validate_http_config(config)
    if not config then
        return false, "No cloud config set"
    elseif not config.url then
        return false, "No cloud url set"
    elseif not config.mainflux_key or not config.mainflux_channels then
        return false, "No mainflux config set"
    end
    return true, nil
end

function metrics_service:_http_publish(data)
    local senml_list = senml.encode_r("", data)
    local body = json.encode(senml_list)
    local valid_config, config_err = validate_http_config(self.cloud_config)
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
    for _, channel in ipairs(self.cloud_config.mainflux_channels) do
        if string.find(channel.name, "data") then
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
    local req = request.new_from_uri(uri)
    req.headers:upsert(":method", "POST")
    req.headers:upsert("authorization", "Thing " .. self.cloud_config.mainflux_key)
    req.headers:upsert("content-type", "senml+json")
    req:set_body(body)
    req.headers:delete("expect")
    local response_headers, _ = req:go()

    if not response_headers then
        log.error(string.format(
            "%s - %s: HTTP publish failed, reason: %s",
            self.ctx:value('service_name'),
            self.ctx:value('fiber_name'),
            "No response headers"
        ))
        return
    elseif response_headers:get(":status") ~= "202" then
        local header_msgs = ""
        for k, v in pairs(response_headers:each()) do
            header_msgs = string.format("%s\n\t%s: %s", header_msgs, k, v)
        end

        log.debug(string.format(
            "%s - %s: HTTP publish failed, header responses: %s",
            self.ctx:value('service_name'),
            self.ctx:value('fiber_name'),
            header_msgs
        ))
    else
        log.info(string.format(
            "%s - %s: HTTP publish success, response: %s",
            self.ctx:value('service_name'),
            self.ctx:value('fiber_name'),
            response_headers:get(":status")
        ))
    end
end

---iterates over a table of data to be published
---@param data table
function metrics_service:_publish_all(data)
    self.cache:reset()
    -- all first keys are the names of the publish protocols
    for protocol, values in pairs(data) do
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

--- Uses process configs to build a processing pipline made of
--- process blocks
--- @param endpoint string
--- @param process_config table
--- @return ProcessPipeline?
--- @return string? Error
function metrics_service:_build_metric_pipeline(endpoint, process_config)
    -- processing blocks take a value and output another value
    -- build up a processing pipeline between the cache and publish steps
    local process, process_err = processing.new_process_pipeline()
    if process_err or not process then
        return nil, process_err
    end
    if process_config == nil then
        return nil, "process config is nil"
    end
    for _, process_block_config in ipairs(process_config) do
        local process_type = process_block_config.type
        if process_type == nil then
            return nil, string.format('Metric config [%s] has process with no type', endpoint)
        end
        local proc_class = processing[process_type]

        if proc_class == nil then
            return nil, string.format('Metric config [%s] has invalid process [%s]', endpoint, process_type)
        end

        local proc, proc_err = proc_class.new(process_block_config)

        if proc_err or not proc then
            return nil, string.format('Metric config [%s] failed to create process block [%s]', endpoint, process_type)
        end
        local add_err = process:add(proc)
        if add_err then
            return nil, add_err
        end
    end

    return process, nil
end

local function merge_config(base_config, override_vals)
    if not base_config then return override_vals end
    if not override_vals then return base_config end

    for k, v in pairs(override_vals) do
        if type(v) == 'table' and type(base_config[k]) == 'table' then
            base_config[k] = merge_config(base_config[k], v)
        else
            base_config[k] = v
        end
    end

    return base_config
end
---use config to build cache and processing pipelines
---@param config table
function metrics_service:_handle_config(config)
    if config == nil then
        log.error("Metrics: Invalid configuration message")
        return
    end
    log.info("Metrics Config Received")

    -- config validation
    if not config.publish_cache or type(config.publish_cache.period) ~= "number" then
        log.error("Invalid publish cache configuration")
        return
    end

    if not config.collections then
        log.error("No metric collections defined in config")
        return
    end

    self.cloud_config = merge_config(self.cloud_config, { url = config.cloud_url })
    -- clean up any old metric pipelines
    if self.metric_subs then
        for _, metric_sub in pairs(self.metric_subs) do
            metric_sub:unsubscribe()
        end
    end
    self.metric_subs = {}
    self.metric_ops = {}
    if config.publish_cache then
        local period = config.publish_cache.period
        local publish_cache, cache_err = timed_cache.new(period, sc.monotime)
        if cache_err then
            log.error(cache_err)
            return
        end
        self.publish_cache = publish_cache
    else
        log.error('No cache config')
        return
    end

    -- iterate over each bus topic in our config
    -- and build up a pipeline for each one
    for endpoint, metric_config in pairs(config.collections) do
        -- could our bus just take tables or strings so I don't have to do this?
        local sub_topic = self.str_trie:_key_to_tokens(endpoint)
        local metric_sub = self.conn:subscribe(sub_topic)

        -- protocol defines the publish method to be used
        local protocol = metric_config.protocol
        if protocol == nil then
            log.error(string.format('Metric config [%s] has no defined protocol', endpoint))
            return
        end

        -- create our processing pipeline for this endpoint
        local default_pipeline, pipline_err = self:_build_metric_pipeline(endpoint, metric_config.process)
        if pipline_err then
            log.error(pipline_err)
            return
        end

        local endpoint_rename = metric_config.rename
        if type(endpoint_rename) ~= 'table' and type(endpoint_rename) ~= 'nil' then
            log.warn(string.format('Metric config [%s] rename is not of expected type: table', endpoint))
        elseif type(endpoint_rename) == 'table' then
            table.insert(endpoint_rename, 1, protocol)
        end
        -- Now we wrap our bus endpoint in a function to
        -- run our processing pipline in a cache
        -- the cache is needed to give each endpoint of a wildcard
        -- its own processing
        -- e.g. gsm/modem/+ could be gsm/modem/primary or gsm/modem/secondary
        local metric_op = metric_sub:next_msg_op():wrap(function (metric_msg)
            -- combine endpoint into string for override lookup
            local metric_endpoint = table.concat(metric_msg.topic, '/')
            local metric = metric_msg.payload
            if metric == nil then
                log.debug('Metric is nil for endpoint: ' .. metric_endpoint)
                return
            end
            -- we may want a specific field from the bus message
            if metric_config.field then metric = metric[metric_config.field] end

            local val, short_circuit, err
            -- either set or update the value into our pipeline
            if self.cache:has_key(metric_msg.topic) then
                val, short_circuit, err = self.cache:update(metric_msg.topic, metric)
            else
                val, short_circuit, err = self.cache:set(metric_msg.topic, metric, default_pipeline)
            end

            if err then
                log.error(err)
                return
            end
            -- if the pipeline completed with no early exit we can update our publish cache
            if not short_circuit then
                table.insert(metric_msg.topic, 1, protocol)
                local cache_topic = endpoint_rename or metric_msg.topic
                self.publish_cache:set(cache_topic, val)
            end
        end)

        table.insert(self.metric_subs, metric_sub)
        table.insert(self.metric_ops, metric_op)
    end
end

---setup initial cache and config then loop over config, metrics and timed cache operations
function metrics_service:_main(ctx)
    self.ctx = ctx
    self.cache = reactive_cache.new()

    local config_sub = self.conn:subscribe({ 'config', 'metrics' })
    local cloud_config_sub = self.conn:subscribe({ 'config', 'mainflux' })

    local initial_config, iconfig_err = config_sub:next_msg_with_context_op(self.ctx):perform()
    if iconfig_err then
        log.error(iconfig_err)
        return
    end
    self:_handle_config(initial_config.payload)

    -- local device_info_sub = self.conn:subscribe({'system', 'device', 'idenitity'}) idk what this will be but
    -- it is a reminder to get system info that canopy will need for reporting

    while not self.ctx:err() do
        op.choice(
            self.ctx:done_op(),
            config_sub:next_msg_op():wrap(function (config_msg)
                self:_handle_config(config_msg.payload)
            end),
            cloud_config_sub:next_msg_op():wrap(function(config_msg)
                self.cloud_config = merge_config(self.cloud_config, config_msg.payload)
            end),
            self.publish_cache:get_op():wrap(function(data)
                self:_publish_all(data)
            end),
            unpack(self.metric_ops)
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
