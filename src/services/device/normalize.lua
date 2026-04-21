local model = require 'services.device.model'

local M = {}

local function copy(t)
    return model.copy_value(t)
end

function M.normalize_plain_status(raw)
    raw = type(raw) == 'table' and raw or {}
    local version = raw.version or raw.fw_version or nil
    local build = raw.build or nil
    local image_id = raw.image_id or nil
    local boot_id = raw.boot_id or nil
    local updater_state = raw.updater_state or raw.state or raw.status or raw.kind or nil
    local last_error = raw.last_error or raw.err or nil
    return {
        available = next(raw) ~= nil,
        ready = raw.ready ~= false,
        software = {
            version = version,
            build = build,
            image_id = image_id,
            boot_id = boot_id,
        },
        updater = {
            state = updater_state,
            last_error = last_error,
        },
        raw = copy(raw),
    }
end

function M.normalize_canonical(raw)
    local out = copy(raw)
    out.available = raw.available ~= false
    out.ready = raw.ready ~= false
    out.software = type(out.software) == 'table' and out.software or {}
    out.updater = type(out.updater) == 'table' and out.updater or {}
    out.capabilities = type(out.capabilities) == 'table' and out.capabilities or {}
    return out
end

function M.normalize_component_status(raw)
    if type(raw) == 'table' and (type(raw.software) == 'table' or type(raw.updater) == 'table') then
        return M.normalize_canonical(raw)
    end
    return M.normalize_plain_status(raw)
end

return M
