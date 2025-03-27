local reactive_cache = require 'services.metrics.action_cache'
local processing = require "services.metrics.processing"
local timed_cache = require "services.metrics.timed_cache"
local service = require 'service'
local op = require "fibers.op"
local log = require 'log'
local trie = require 'trie'
local sc = require 'fibers.utils.syscall'
local unpack = table.unpack or unpack

local metrics_service = {
    name = 'metrics',
    metric_ops = {},
    str_trie = trie.new_string(nil, nil, '/')
}
metrics_service.__index = metrics_service

--- this is the only publish protocol
--- (for testing purposes)
--- @param val table
function metrics_service:_log_publish(val)
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
    print_recursive(val, 0)
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
    local process, process_err = processing.new_process_pipeline(process_config or self.default_process)
    if process_err or not process then
        return nil, process_err
    end
    for _, process_block_config in ipairs(process_config or self.default_process) do
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

---check that an overriding endpoint does not conflict with the original endpoint
---@param endpoint string[]
---@param override_endpoint string[]
---@return boolean
local function valid_override_endpoint(endpoint, override_endpoint)
    for i, endpart in ipairs(endpoint) do
        if i == #endpoint and endpart == '#' then return true end
        if endpart ~= override_endpoint[i] and endpart ~= '+' then
            return false
        end
    end
    return true
end

---use config to build cache and processing pipelines
---@param config table
function metrics_service:_handle_config(config)
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

    -- clean up any old metric pipelines
    self.metric_ops = {}
    self.default_process = config.default_process
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
        local metric_sub = self.bus_conn:subscribe(sub_topic)

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

        -- some specific endpoints require different processing, so we override
        -- wildcards and build specific pipelines for these cases
        local overrides = {}
        for override_endpoint, override_config in pairs(metric_config.sub_collections or {}) do
            local parts_ovrride_endpoint = self.str_trie:_key_to_tokens(override_endpoint)
            -- the overriden endpoint can only change wildcard fields,
            -- so check validity
            if valid_override_endpoint(sub_topic, parts_ovrride_endpoint) then
                local pipeline, pipeline_err = self:_build_metric_pipeline(override_endpoint, override_config)
                if pipeline_err then
                    log.error(pipeline_err)
                    return
                end
                overrides[override_endpoint] = pipeline
            else
                log.error(string.format("Invalid override for %s onto %s", override_endpoint, endpoint))
            end
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
            -- we may want a specific field from the bus message
            if metric_config.field then metric = metric[metric_config.field] end
            if metric == nil then
                log.debug('Metric is nil for endpoint: ' .. metric_endpoint)
                return
            end
            -- check for a custom pipeline otherwise apply default
            local process = overrides[metric_endpoint]
            if process == nil then
                process = default_pipeline
            end

            local val, short_circuit, err
            -- either set or update the value into our pipeline
            if self.cache:has_key(metric_msg.topic) then
                val, short_circuit, err = self.cache:update(metric_msg.topic, metric)
            else
                val, short_circuit, err = self.cache:set(metric_msg.topic, metric, process)
            end

            if err then
                log.error(err)
                return
            end
            -- if the pipeline completed with no early exit we can update our publish cache
            if not short_circuit then
                table.insert(metric_msg.topic, 1, protocol)
                self.publish_cache:set(metric_msg.topic, val)
            end
        end)

        table.insert(self.metric_ops, metric_op)
    end
end

---setup initial cache and config then loop over config, metrics and timed cache operations
function metrics_service:_main()
    self.cache = reactive_cache.new()

    local config_sub = self.bus_conn:subscribe({'config', 'metrics'})

    local initial_config, iconfig_err = config_sub:next_msg_with_context_op(self.ctx):perform()
    if iconfig_err then
        log.error(iconfig_err)
        return
    end
    self:_handle_config(initial_config.payload)

    -- local device_info_sub = self.bus_conn:subscribe({'system', 'device', 'idenitity'}) idk what this will be but
    -- it is a reminder to get system info that canopy will need for reporting

    while not self.ctx:err() do
        op.choice(
            self.ctx:done_op(),
            config_sub:next_msg_op():wrap(function (config_msg)
                self:_handle_config(config_msg.payload)
            end),
            self.publish_cache:get_op():wrap(function(data)
                self:_publish_all(data)
            end),
            unpack(self.metric_ops)
        ):perform()
    end
    log.info("Metrics Service Ending")
end

---Creates the metrics fiber
---@param ctx Context
---@param bus_connection Connection
function metrics_service:start(ctx, bus_connection)
    log.info("Metrics Service Starting")
    self.ctx = ctx
    self.bus_conn = bus_connection
    service.spawn_fiber('Metrics Fiber', bus_connection, ctx, function ()
        metrics_service:_main()
    end)
end

return metrics_service
