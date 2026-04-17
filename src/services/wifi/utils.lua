local json = require "cjson.safe"
local cap_args = require "services.hal.types.capability_args"

local mainflux_to_ssid_keys = {
    name    = "network",
    ssid    = "name",
}

---Read mainflux SSID credentials from the configs filesystem capability
---and merge them with the base SSID config.
---@param fs_cap any        CapabilityReference for the configs filesystem cap
---@param mainflux_path string  Filename within the filesystem cap (e.g. "mainflux.json")
---@param base_ssid_cfg table   Base SSID fields to merge into each resulting SSID
---@return table?  ssids  Array of SSID config tables, or nil on any error
---@return string  err    Error message, or "" on success
local function parse_mainflux_ssids(fs_cap, mainflux_path, base_ssid_cfg)
    local opts, opts_err = cap_args.new.FilesystemReadOpts(mainflux_path)
    if not opts then
        return nil, tostring(opts_err)
    end

    local reply, call_err = fs_cap:call_control('read', opts)
    if not reply then
        return nil, tostring(call_err)
    end
    if reply.ok ~= true then
        return nil, tostring(reply.reason or "filesystem read failed")
    end

    local outer, derr = json.decode(reply.reason or '')
    if not outer then
        return nil, tostring(derr)
    end

    -- The mainflux file wraps the actual config as a JSON-encoded string in `content`
    local content_parsed
    if type(outer.content) == 'string' then
        local inner_err
        content_parsed, inner_err = json.decode(outer.content)
        if not content_parsed then
            return nil, "failed to decode mainflux content field: " .. tostring(inner_err)
        end
    else
        content_parsed = outer
    end

    local ssid_cfgs = content_parsed.networks
        and content_parsed.networks.networks
        or nil
    if not ssid_cfgs then
        return nil, "no ssid configs found in mainflux file"
    end

    local ssids = {}
    for _, ssid_cfg in ipairs(ssid_cfgs) do
        local ssid = {}
        for k, v in pairs(base_ssid_cfg) do
            ssid[k] = v
        end
        for k, v in pairs(ssid_cfg) do
            local key = mainflux_to_ssid_keys[k] or k
            -- Temporary workaround: mainflux uses "jng" for what we call "adm"
            if key == "network" and v == "jng" then
                v = "adm"
            end
            ssid[key] = v
        end
        table.insert(ssids, ssid)
    end
    return ssids, ""
end

return {
    parse_mainflux_ssids = parse_mainflux_ssids,
}
