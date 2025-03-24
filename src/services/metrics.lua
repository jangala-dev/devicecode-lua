local reactive_cache = require 'services.metrics.reactive_cache'
local triggers = require "services.metrics.triggers"
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

function metrics_service:_build_metric_pipeline(endpoint, config)
    -- make a trigger to define when a value should be published
    local trigger_type = config.delta_trigger.type
    if trigger_type == nil then
        log.error(string.format('Metric config [%s] no delta_trigger type provided', endpoint))
        return
    end
    local trigger_class = triggers[trigger_type]
    if trigger_class == nil then
        log.error(string.format('Metric config [%s] has invalid delta_trigger [%s]', endpoint, config.delta_trigger.type))
        return
    end

    local trigger, trigger_err = trigger_class.new(config.delta_trigger)
    if trigger_err then
        log.error(string.format('Metric config [%s] failed to create trigger [%s]', endpoint, trigger_err))
        return
    end

    -- protocol defines the publish method to be used
    local protocol = config.protocol
    if protocol == nil then
        log.error(string.format('Metric config [%s] has no defined protocol', endpoint))
        return
    end

    local publish_fn = self["_" .. protocol .. "_publish"]
    if publish_fn == nil then
        log.error(string.format('Metric config [%s] invalid protocol [%s]', endpoint, protocol))
        return
    end

    -- processing blocks take a value and output another value
    -- build up a processing pipeline between the cache and publish steps
    local process = processing.new_process()
    for _, process_config in ipairs(config.process) do
        local process_type = process_config.type
        if process_type == nil then
            log.error(string.format('Metric config [%s] has process with no type', endpoint))
            return
        end
        local proc = processing[process_type]

        if proc == nil then
            log.error(string.format('Metric config [%s] has invalid process [%s]', endpoint, process_type))
            return
        end

        process:add(proc)
    end

    -- finally build the function to put together the steps
    -- 1. put value into cache
    -- 2. if cache returns a value pass it to processing
    -- 3. if processing returns a value publish it
    -- Note: I think both cache and processing should make use of another return
    -- type which is a is_value flag, this can be used to short circuit
    -- processing and pass nil values if needed

    -- MAJOR ISSUE WITH CURRENT IMPLEMENTATION
    -- each unqiue endpoint within a single or multi wild needs its own instance
    -- of the pipeline, right now the pipeline only allows unique treatment for the triggers
    -- but not the processing (publish can be shared)
    -- this means we need to unify the trigger and processing
    -- why does trigger even need to be its own thing?
    -- new cache can hold a pipeline per endpoint
    -- set will create an instance of the pipeline and
    -- update will put the new value into the pipeline
    -- both set and update will check if a value is returned (using a short circuit flag)
    -- and the publish method will be run if so
    local pipeline = function(metric_msg)
        local metric_endpoint = table.concat(metric_msg.topic, '/')
        local metric = metric_msg.payload
        if config.field then metric = metric[config.field] end
        if metric == nil then
            log.debug('Metric is nil for endpoint: ' .. metric_endpoint)
            return
        end
        local val, err
        if self.cache:has_key(metric_msg.topic) then
            val, err = self.cache:update(metric_msg.topic, metric)
        else
            val, err = self.cache:set(metric_msg.topic, metric, trigger)
        end

        if err then
            log.error(err)
            return
        end
        if val then
            local processed_val, proc_err = process:run(val)
            if proc_err then
                log.error(proc_err)
                return
            end
            if processed_val then
                publish_fn(self, metric_endpoint, val)
            end
        end
    end

    return pipeline
end
function metrics_service:_handle_config(config)
    log.info("Metrics Config Recieved")
    self.metric_ops = {}
    for endpoint, metric_config in pairs(config.collections) do
        -- could our bus just take tables or strings so I don't have to do this?
        local sub_topic = self.str_trie:_key_to_tokens(endpoint)
        local metric_sub = self.bus_conn:subscribe(sub_topic)

        local trigger_type = metric_config.delta_trigger.type
        local trigger
        local trigger_err
        if trigger_type == 'absolute' then
            trigger, trigger_err = triggers.DiffTrigger.new('absolute', metric_config.delta_trigger.threshold,
                metric_config.delta_trigger.initial_value)
        elseif trigger_type == 'percent' then
            trigger, trigger_err = triggers.DiffTrigger.new('percent', metric_config.delta_trigger.threshold,
                metric_config.delta_trigger.initial_value)
        elseif trigger_type == 'time' then
            trigger, trigger_err = triggers.TimeTrigger.new(metric_config.delta_trigger.timeout)
        elseif trigger_type == 'none' then
            trigger, trigger_err = triggers.AlwaysTrigger.new()
        else
            log.error('Invalid trigger type: ' .. trigger_type)
            return
        end

        if trigger_err then
            log.error(trigger_err)
            return
        end
        local protocol = metric_config.protocol
        local publish_method
        if protocol == 'log' then
            publish_method = self._log_publish
        else
            log.error('Invalid protocol: ' .. protocol)
            return
        end

        local metric_op = metric_sub:next_msg_op():wrap(function (metric_msg)
            local metric_endpoint = table.concat(metric_msg.topic, '/')
            local metric = metric_msg.payload
            if metric_config.field then metric = metric[metric_config.field] end
            if metric == nil then
                log.debug('Metric is nil for endpoint: ' .. metric_endpoint)
                return
            end
            local val, err
            if self.cache:has_key(metric_msg.topic) then
                val, err = self.cache:update(metric_msg.topic, metric)
            else
                val, err = self.cache:set(metric_msg.topic, metric, trigger)
            end

            if err then
                log.error(err)
                return
            end
            if val then
                publish_method(self, metric_endpoint, val)
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
