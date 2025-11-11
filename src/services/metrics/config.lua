local log = require "services.log"
local processing = require "services.metrics.processing"

local VALID_PROTOCOLS = { http = true, log = true }
local VALID_PROCESS_TYPES = { DiffTrigger = true, TimeTrigger = true, DeltaValue = true }

local function is_array(t)
    if type(t) ~= "table" then
        return false
    end
    local i = 1
    for k, _ in pairs(t) do
        if k ~= i then
            return false
        end
        i = i + 1
    end

    return true
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

local function standardise_config(config)
    local standard_config = {}

    standard_config.thing_id = config.mainflux_id or config.thing_id
    standard_config.thing_key = config.mainflux_key or config.thing_key
    standard_config.channels = config.mainflux_channels or config.channels
    for _, channel in ipairs(standard_config.channels) do
        channel.metadata = channel.metadata or {}
        if type(channel.metadata) == "userdata" then channel.metadata = {} end
        if string.find(channel.name, "data") then
            channel.metadata.channel_type = "data"
        elseif string.find(channel.name, "control") then
            channel.metadata.channel_type = "events"
        end
    end

    standard_config.content = config.content
    return standard_config
end

--- Uses process configs to build a processing pipeline made of
--- process blocks
--- @param endpoint string
--- @param process_config table
--- @return ProcessPipeline?
--- @return string? Error
local function build_metric_pipeline(endpoint, process_config)
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

local function validate_http_config(config)
    if not config then
        return false, "No cloud config set"
    elseif not config.url then
        return false, "No cloud url set"
    elseif not config.thing_key or not config.channels then
        return false, "No cloud config set"
    end

    if type(config.url) ~= "string" then
        return false, "Cloud url is not a string"
    end
    return true, nil
end

local function validate_config(config)
    local warnings = {}

    if type(config) ~= "table" then
        return false, warnings, "Invalid configuration message"
    end

    if type(config.publish_period) ~= "number" or tonumber(config.publish_period) == nil then
        return false, warnings, "Invalid publish cache configuration"
    end

    if config.publish_period <= 0 then
        return false, warnings, "Publish period must be greater than 0"
    end

    if type(config.collections) ~= "table" then
        return false, warnings, "No metric collections defined in config"
    end

    local renames = {}
    for endpoint, metric_config in pairs(config.collections) do
        if type(endpoint) ~= "string" then
            table.insert(warnings, {
                msg = "Metric endpoint is not a string",
                endpoint = endpoint
            })
        end
        if type(metric_config) ~= "table" then
            table.insert(warnings, {
                msg = string.format("Metric config [%s] is not a table", tostring(endpoint)),
                endpoint = endpoint
            })
        end

        -- Validate protocol
        if metric_config.protocol == nil then
            table.insert(warnings, {
                msg = string.format("Metric config [%s] has no defined protocol", tostring(endpoint)),
                endpoint = endpoint
            })
        elseif not VALID_PROTOCOLS[metric_config.protocol] then
            table.insert(warnings, {
                msg = string.format("Metric config [%s] has invalid protocol '%s' (valid: http, log)",
                    tostring(endpoint), tostring(metric_config.protocol)),
                endpoint = endpoint
            })
        end

        -- Validate process pipeline
        if metric_config.process ~= nil then
            if not is_array(metric_config.process) then
                table.insert(warnings, {
                    msg = string.format("Metric config [%s] process must be an array", tostring(endpoint)),
                    endpoint = endpoint
                })
            else
                -- Validate each process block
                for i, process_block in ipairs(metric_config.process) do
                    if type(process_block) ~= "table" then
                        table.insert(warnings, {
                            msg = string.format("Metric config [%s] process block %d is not a table",
                                tostring(endpoint), i),
                            endpoint = endpoint
                        })
                    elseif process_block.type == nil then
                        table.insert(warnings, {
                            msg = string.format("Metric config [%s] process block %d has no type field",
                                tostring(endpoint), i),
                            endpoint = endpoint
                        })
                    elseif not VALID_PROCESS_TYPES[process_block.type] then
                        local valid_types = table.concat({"DiffTrigger", "TimeTrigger", "DeltaValue"}, ", ")
                        table.insert(warnings, {
                            msg = string.format(
                                "Metric config [%s] process block %d has invalid type '%s' (valid: %s)",
                                tostring(endpoint), i, tostring(process_block.type), valid_types),
                            endpoint = endpoint
                        })
                    end
                end
            end
        end

        -- Validate rename
        if metric_config.rename then
            if (not is_array(metric_config.rename)) then
                table.insert(warnings, {
                    msg = string.format("Metric config [%s] rename is not of expected type: table", tostring(endpoint)),
                    endpoint = endpoint
                })
            else
                local rename = table.concat(metric_config.rename, ",")
                if renames[rename] then
                    table.insert(warnings, {
                        msg = string.format("Metric config [%s] has duplicate rename definition", tostring(endpoint)),
                        endpoint = endpoint
                    })
                else
                    renames[rename] = true
                end
            end
        end

        -- Validate field
        local field_type = type(metric_config.field)
        if metric_config.field and (field_type ~= "string" and field_type ~= "number") then
            table.insert(warnings, {
                msg = string.format("Metric config [%s] field must be string or number",
                    tostring(endpoint)),
                endpoint = endpoint
            })
        end
    end

    return true, warnings, nil
end

local function apply_config(conn, config, cloud_config)
    local merged_cloud_config = merge_config(cloud_config, { url = config.cloud_url })

    local publish_period = config.publish_period
    local metrics = {}

    -- iterate over each bus topic in our config
    -- and build up a pipeline for each one
    for endpoint, metric_config in pairs(config.collections) do
        local sub_topic = {}
        for part in endpoint:gmatch("[^/]+") do
            sub_topic[#sub_topic + 1] = part
        end
        local sub = conn:subscribe(sub_topic)

        -- protocol defines the publish method to be used
        local protocol = metric_config.protocol

        -- create our processing pipeline for this endpoint
        local base_pipeline, pipeline_err = build_metric_pipeline(endpoint, metric_config.process)
        if pipeline_err then
            log.error(pipeline_err)
        else
            local metric_inst = {
                sub = sub,
                field = metric_config.field,
                rename = metric_config.rename,
                protocol = protocol,
                base_pipeline = base_pipeline
            }

            table.insert(metrics, metric_inst)
        end
    end
    return metrics, publish_period, merged_cloud_config
end

return {
    merge_config = merge_config,
    standardise_config = standardise_config,
    validate_http_config = validate_http_config,
    validate_config = validate_config,
    apply_config = apply_config,
    build_metric_pipeline = build_metric_pipeline
}
