local exec = require "fibers.exec"
local utils = require "services.hal.drivers.wireless.utils"

local function get_iw_dev_info(ctx, interface)
    local out, err = exec.command_context(ctx, "iw", "dev", interface, "info"):output()
    if err then
        return nil, err
    end

    return utils.format_iw_dev_info(out)
end

local function get_iw_event_stream(ctx)
    return exec.command_context(ctx, "iw", "event")
end

local function get_client_info(ctx, interface, mac)
    local out, err = exec.command_context(ctx, "iw", "dev", interface, "station", "get", mac):output()
    if err then
        return nil, err
    end

    return utils.format_iw_client_info(out)
end

local function get_dev_noise(ctx, interface)
    local out, err = exec.command_context(ctx, "iw", interface, "survey", "dump"):output()
    if err then
        return nil, err
    end

    return utils.parse_dev_noise(out)
end

return {
    get_iw_dev_info = get_iw_dev_info,
    get_iw_event_stream = get_iw_event_stream,
    get_client_info = get_client_info,
    get_dev_noise = get_dev_noise
}
