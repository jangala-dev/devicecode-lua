local reactive_cache = require 'services.metrics.action_cache'
local processing = require "services.metrics.processing"
local service = require 'service'
local op = require "fibers.op"
local log = require 'log'
local trie = require 'trie'
local unpack = table.unpack or unpack

local metrics_service = {
    name = 'metrics',
    metric_ops = {}
}
metrics_service.__index = metrics_service


-- metric endpoint triggers (gsm/modem/1/rx)
-- val = metric
-- tr_u = trigger_update(val)
-- if tr_u then
-- pub_val = process(val)
-- pub(pub_val)

function metrics_service:_log_publish(identity, val)
    if type(val) == 'table' then
        local log_msg = identity .. ': [ '
        for _, v in ipairs(val) do
            log_msg = log_msg .. ', ' .. v
        end
        log_msg = log_msg .. ' ]'
        log.info(log_msg)
    else
        log.info(identity .. ': ' .. val)
    end
end

function metrics_service:_build_metric_pipeline(endpoint, process_config)
    -- processing blocks take a value and output another value
    -- build up a processing pipeline between the cache and publish steps
    local process = processing.new_process_pipeline()
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

        if proc_err then
            return nil, string.format('Metric config [%s] failed to create process block [%s]', endpoint, process_type)
        end
        local add_err = process:add(proc)
        if add_err then
            log.error(add_err)
            return
        end
    end

    return process, nil
end

local function valid_override_endpoint(endpoint, override_endpoint)
    for i, endpart in ipairs(endpoint) do
        if i == #endpoint and endpart == '#' then return true end
        if endpart ~= override_endpoint[i] and endpart ~= '+' then
            return false
        end
    end
    return true
end

function metrics_service:_handle_config(config)
    log.info("Metrics Config Recieved")
    self.metric_ops = {}
    self.default_process = config.default_process
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

        local publish_fn = self["_" .. protocol .. "_publish"]
        if publish_fn == nil then
            log.error(string.format('Metric config [%s] invalid protocol [%s]', endpoint, protocol))
            return
        end
        local default_pipeline, pipline_err = self:_build_metric_pipeline(endpoint, metric_config.process)
        if pipline_err then
            log.error(pipline_err)
            return
        end

        local overrides = {}

        for override_endpoint, override_config in ipairs(metric_config.sub_collections or {}) do
            local parts_ovrride_endpoint = self.str_trie:_key_to_tokens(override_endpoint)
            if valid_override_endpoint(sub_topic, parts_ovrride_endpoint) then
                local pipeline, pipeline_err = self:_build_metric_pipeline(override_endpoint, override_config)
                if pipeline_err then
                    log.error(pipeline_err)
                    return
                end
                overrides[override_endpoint] = pipeline
            end
        end

        local metric_op = metric_sub:next_msg_op():wrap(function (metric_msg)
            local metric_endpoint = table.concat(metric_msg.topic, '/')
            local metric = metric_msg.payload
            if metric_config.field then metric = metric[metric_config.field] end
            if metric == nil then
                log.debug('Metric is nil for endpoint: ' .. metric_endpoint)
                return
            end
            local process = overrides[metric_endpoint]
            if process == nil then
                process = default_pipeline
            end

            local val, short_circuit, err
            if self.cache:has_key(metric_msg.topic) then
                val, short_circuit, err = self.cache:update(metric_msg.topic, metric)
            else
                val, short_circuit, err = self.cache:set(metric_msg.topic, metric, process)
            end

            if err then
                log.error(err)
                return
            end
            if not short_circuit then
                publish_fn(self, metric_endpoint, val)
                self.cache:reset(metric_msg.topic, val)
            end
        end)

        table.insert(self.metric_ops, metric_op)
    end
end

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
            config_sub:next_msg_op():wrap(function (config_msg)
                self:_handle_config(config_msg.payload)
            end),
            self.ctx:done_op(),
            unpack(self.metric_ops)
        ):perform()
    end
end

function metrics_service:start(ctx, bus_connection)
    log.info("Metrics Service Starting")
    self.ctx = ctx
    self.bus_conn = bus_connection
    self.str_trie = trie.new_string(nil, nil, '/')
    service.spawn_fiber('Metrics Fiber', bus_connection, ctx, function ()
        metrics_service:_main()
    end)
end

return metrics_service
