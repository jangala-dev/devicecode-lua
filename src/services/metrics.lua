local caching = require 'reactive_cache'
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

function metrics_service:_handle_config(config)
    log.info("Metrics Config Recieved")
    self.metric_ops = {}
    for endpoint, metric_config in pairs(config) do
        -- could our bus just take tables or strings so I don't have to do this?
        local sub_topic = self.str_trie:_key_to_tokens(endpoint)
        local metric_sub = self.bus_conn:subscribe(sub_topic)

        local trigger_type = metric_config.delta_trigger.type
        local trigger
        if trigger_type == 'absolute' then
            trigger = caching.DiffTrigger.new('absolute', metric_config.delta_trigger.threshold, metric_config.delta_trigger.initial_value)
        elseif trigger_type == 'percent' then
            trigger = caching.DiffTrigger.new('percent', metric_config.delta_trigger.threshold, metric_config.delta_trigger.initial_value)
        elseif trigger_type == 'time' then
            trigger = caching.TimeTrigger.new(metric_config.delta_trigger.timeout)
        elseif trigger_type == 'none' then
            trigger = caching.AlwaysTrigger.new()
        else
            log.error('Invalid trigger type: ' .. trigger_type)
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
            if self.cache:has_key(metric_endpoint) then
                val, err = self.cache:update(metric_endpoint, metric)
            else
                val, err = self.cache:set(metric_endpoint, metric, trigger)
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
    self.cache = caching.ReactiveCache.new()

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
