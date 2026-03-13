-- services/metrics/config.lua
--
-- Configuration validation and application for the metrics service.
--
-- validate_config(config)
--   Returns (ok, warnings, error).  Validates structure, protocols, process
--   blocks, templates and pipelines.  Invalid templates and any pipelines that
--   reference them are collected as warnings rather than hard failures so that
--   the service can continue with the valid subset.
--
-- apply_config(config)
--   Returns (pipelines_map, publish_period).
--   pipelines_map[metric_name] = { pipeline, protocol }
--   The pipeline object contains only logic; per-endpoint state is created
--   externally with pipeline:new_state().

local log                   = require 'services.log'
local processing            = require 'services.metrics.processing'
local _types                = require 'services.metrics.types' -- luacheck: ignore (imported for annotations)

local VALID_PROTOCOLS       = { http = true, log = true, bus = true }
local VALID_PROCESS_TYPES   = { DiffTrigger = true, TimeTrigger = true, DeltaValue = true }

local VALID_TEMPLATE_FIELDS = {
    protocol = true,
    process  = true,
}
local VALID_METRIC_FIELDS   = {
    protocol = true,
    process  = true,
    template = true,
}

-------------------------------------------------------------------------------
-- Helpers
-------------------------------------------------------------------------------

---@param t any
---@return boolean
local function is_array(t)
    if type(t) ~= 'table' then return false end
    local i = 1
    for k in pairs(t) do
        if k ~= i then return false end
        i = i + 1
    end
    return true
end

---@param base table?
---@param override table?
---@return table
local function merge_config(base, override)
    if not base then return override or {} end
    if not override then return base end
    local result = {}
    for k, v in pairs(base) do result[k] = v end
    for k, v in pairs(override) do
        if type(v) == 'table' and type(result[k]) == 'table' then
            result[k] = merge_config(result[k], v)
        else
            result[k] = v
        end
    end
    return result
end

--- Normalise a raw mainflux config table to a consistent field set.
--- Accepts both legacy (`mainflux_*`) and current (`thing_*`) naming.
---@param config table
---@return table
local function standardise_config(config)
    local out     = {}
    out.thing_key = config.mainflux_key or config.thing_key
    out.channels  = config.mainflux_channels or config.channels
    for _, channel in ipairs(out.channels or {}) do
        channel.metadata = channel.metadata or {}
        if type(channel.metadata) == 'userdata' then channel.metadata = {} end
        if string.find(channel.name, 'data') then
            channel.metadata.channel_type = 'data'
        elseif string.find(channel.name, 'control') then
            channel.metadata.channel_type = 'events'
        end
    end
    out.content = config.content
    return out
end

--- Basic sanity-check for the cloud (Mainflux) config used for HTTP publish.
---@param config CloudConfig?
---@return boolean ok
---@return string? error
local function validate_http_config(config)
    if not config then
        return false, 'No cloud config set'
    end
    if not config.url then
        return false, 'No cloud url set'
    end
    if type(config.url) ~= 'string' then
        return false, 'Cloud url is not a string'
    end
    if not config.thing_key or not config.channels then
        return false, 'Cloud thing_key / channels missing'
    end
    return true, nil
end

-------------------------------------------------------------------------------
-- Internal validation helpers
-------------------------------------------------------------------------------

---@param process_block any
---@param endpoint string
---@param index number
---@return string? error
local function validate_process_block(process_block, endpoint, index)
    if type(process_block) ~= 'table' then
        return string.format('Metric config [%s] process block %d is not a table',
            tostring(endpoint), index)
    end
    if process_block.type == nil then
        return string.format('Metric config [%s] process block %d has no type field',
            tostring(endpoint), index)
    end
    if not VALID_PROCESS_TYPES[process_block.type] then
        return string.format(
            "Metric config [%s] process block %d has invalid type '%s' (valid: %s)",
            tostring(endpoint), index, tostring(process_block.type),
            table.concat({ 'DiffTrigger', 'TimeTrigger', 'DeltaValue' }, ', '))
    end
    return nil
end

---@param name any
---@param template_config any
---@return table warnings
local function validate_template(name, template_config)
    local warnings = {}

    if type(name) ~= 'string' then
        table.insert(warnings, {
            msg      = 'Template name is not a string',
            endpoint = name,
            type     = 'template',
        })
    end
    if type(template_config) ~= 'table' then
        table.insert(warnings, {
            msg      = string.format('Template config [%s] is not a table', tostring(name)),
            endpoint = name,
            type     = 'template',
        })
        return warnings
    end

    for field in pairs(template_config) do
        if not VALID_TEMPLATE_FIELDS[field] then
            table.insert(warnings, {
                msg      = string.format("Template config [%s] has invalid field '%s'",
                    tostring(name), tostring(field)),
                endpoint = name,
                type     = 'template',
            })
        end
    end

    if template_config.protocol and not VALID_PROTOCOLS[template_config.protocol] then
        table.insert(warnings, {
            msg      = string.format(
                "Template config [%s] has invalid protocol '%s' (valid: http, log, bus)",
                tostring(name), tostring(template_config.protocol)),
            endpoint = name,
            type     = 'template',
        })
    end

    if template_config.process ~= nil then
        if not is_array(template_config.process) then
            table.insert(warnings, {
                msg      = string.format('Template config [%s] process must be an array', tostring(name)),
                endpoint = name,
                type     = 'template',
            })
        else
            for i, blk in ipairs(template_config.process) do
                local err = validate_process_block(blk, name, i)
                if err then
                    table.insert(warnings, { msg = err, endpoint = name, type = 'template' })
                end
            end
        end
    end

    return warnings
end

---@param endpoint any
---@param metric_config any
---@return table warnings
local function validate_metric(endpoint, metric_config)
    local warnings = {}

    if type(endpoint) ~= 'string' then
        table.insert(warnings, {
            msg      = 'Metric endpoint is not a string',
            endpoint = endpoint,
            type     = 'metric',
        })
    end
    if type(metric_config) ~= 'table' then
        table.insert(warnings, {
            msg      = string.format('Metric config [%s] is not a table', tostring(endpoint)),
            endpoint = endpoint,
            type     = 'metric',
        })
        return warnings
    end

    for field in pairs(metric_config) do
        if not VALID_METRIC_FIELDS[field] then
            table.insert(warnings, {
                msg      = string.format("Metric config [%s] has invalid field '%s'",
                    tostring(endpoint), tostring(field)),
                endpoint = endpoint,
                type     = 'metric',
            })
        end
    end

    if metric_config.protocol == nil then
        table.insert(warnings, {
            msg      = string.format('Metric config [%s] has no defined protocol', tostring(endpoint)),
            endpoint = endpoint,
            type     = 'metric',
        })
    elseif not VALID_PROTOCOLS[metric_config.protocol] then
        table.insert(warnings, {
            msg      = string.format(
                "Metric config [%s] has invalid protocol '%s' (valid: http, log, bus)",
                tostring(endpoint), tostring(metric_config.protocol)),
            endpoint = endpoint,
            type     = 'metric',
        })
    end

    if metric_config.process ~= nil then
        if not is_array(metric_config.process) then
            table.insert(warnings, {
                msg      = string.format('Metric config [%s] process must be an array', tostring(endpoint)),
                endpoint = endpoint,
                type     = 'metric',
            })
        else
            for i, blk in ipairs(metric_config.process) do
                local err = validate_process_block(blk, endpoint, i)
                if err then
                    table.insert(warnings, { msg = err, endpoint = endpoint, type = 'metric' })
                end
            end
        end
    end

    return warnings
end

-------------------------------------------------------------------------------
-- Pipeline builder
-------------------------------------------------------------------------------

--- Build a ProcessPipeline from a process_config array.
---@param endpoint string
---@param process_config table
---@return ProcessPipeline?
---@return string? error
local function build_metric_pipeline(endpoint, process_config)
    local pipeline, pipeline_err = processing.new_process_pipeline()
    if not pipeline then
        return nil, string.format('Metric config [%s] failed to create pipeline: %s', endpoint, tostring(pipeline_err))
    end

    if process_config == nil then
        -- An empty pipeline (pass-through) is valid.
        return pipeline, nil
    end

    for _, blk_cfg in ipairs(process_config) do
        local ptype = blk_cfg.type
        if ptype == nil then
            return nil, string.format('Metric config [%s] has process block with no type', endpoint)
        end

        local proc_class = processing[ptype]
        if proc_class == nil then
            return nil, string.format('Metric config [%s] has invalid process block type [%s]',
                endpoint, tostring(ptype))
        end

        local proc, proc_err = proc_class.new(blk_cfg)
        if not proc or proc_err then
            return nil, string.format(
                'Metric config [%s] failed to create process block [%s]: %s',
                endpoint, tostring(ptype), tostring(proc_err))
        end

        local add_err = pipeline:add(proc)
        if add_err then
            return nil, add_err
        end
    end

    return pipeline, nil
end

-------------------------------------------------------------------------------
-- Public: validate_config
-------------------------------------------------------------------------------

--- Validate a raw metrics config table.
---@param config table
---@return boolean ok
---@return table   warnings
---@return string? error
local function validate_config(config)
    local warnings = {}

    if type(config) ~= 'table' then
        return false, warnings, 'Invalid configuration message'
    end

    if type(config.publish_period) ~= 'number' then
        return false, warnings,
            'Publish period must be of number type, found ' .. type(config.publish_period)
    end
    if config.publish_period <= 0 then
        return false, warnings, 'Publish period must be greater than 0'
    end

    if type(config.pipelines) ~= 'table' then
        return false, warnings, 'No metric pipelines defined in config'
    end

    local dropped_templates = {}
    for name, tmpl in pairs(config.templates or {}) do
        local tmpl_warns = validate_template(name, tmpl)
        if #tmpl_warns > 0 then
            for _, w in ipairs(tmpl_warns) do
                table.insert(warnings, w)
            end
            dropped_templates[name] = true
        end
    end

    for endpoint, metric_config in pairs(config.pipelines) do
        -- Check template existence
        if metric_config.template then
            if (not config.templates) or (not config.templates[metric_config.template]) then
                table.insert(warnings, {
                    msg      = string.format(
                        'Metric config [%s] uses template [%s] that does not exist',
                        tostring(endpoint), tostring(metric_config.template)),
                    endpoint = endpoint,
                    type     = 'metric',
                })
            end
            if dropped_templates[metric_config.template] then
                table.insert(warnings, {
                    msg      = string.format(
                        'Metric config [%s] uses invalid template [%s]',
                        tostring(endpoint), tostring(metric_config.template)),
                    endpoint = endpoint,
                    type     = 'metric',
                })
            end
        end

        -- Merge template then validate the resulting config
        local full_cfg = merge_config(
            (config.templates and metric_config.template
                and config.templates[metric_config.template]) or {},
            metric_config
        )
        local metric_warns = validate_metric(endpoint, full_cfg)
        for _, w in ipairs(metric_warns) do
            table.insert(warnings, w)
        end
    end

    return true, warnings, nil
end

-------------------------------------------------------------------------------
-- Public: apply_config
-------------------------------------------------------------------------------

--- Apply a validated config and return a pipelines_map.
--- Does not create any bus subscriptions.
---
---@param config table
---@return PipelineMap pipelines_map  keyed by metric_name
---@return number      publish_period
local function apply_config(config)
    local publish_period = config.publish_period
    local pipelines_map  = {}

    for metric_name, metric_config in pairs(config.pipelines) do
        local resolved = metric_config
        if resolved.template and config.templates and config.templates[resolved.template] then
            resolved = merge_config(config.templates[resolved.template], resolved)
        end

        local protocol = resolved.protocol
        if not protocol or not VALID_PROTOCOLS[protocol] then
            log.warn(string.format(
                'metrics/config: skipping pipeline [%s] — invalid or missing protocol',
                tostring(metric_name)))
        else
            local pipeline, pipeline_err = build_metric_pipeline(
                metric_name, resolved.process or {})
            if pipeline_err then
                log.error(string.format(
                    'metrics/config: skipping pipeline [%s] — %s',
                    tostring(metric_name), pipeline_err))
            else
                pipelines_map[metric_name] = {
                    pipeline = pipeline,
                    protocol = protocol,
                }
            end
        end
    end

    return pipelines_map, publish_period
end

return {
    merge_config          = merge_config,
    standardise_config    = standardise_config,
    validate_http_config  = validate_http_config,
    validate_config       = validate_config,
    apply_config          = apply_config,
    build_metric_pipeline = build_metric_pipeline,
}
