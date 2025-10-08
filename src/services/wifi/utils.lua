local json = require "cjson.safe"

local BUS_TIMEOUT = 2

local mainflux_to_ssid_keys = {
    name = "network",
    ssid = "name"
}

local function parse_mainflux_ssids(ctx, conn, mainflux_path, base_ssid_cfg)
    local mainflux_topic = {}
    for token in string.gmatch(mainflux_path, "[^/]+") do
        table.insert(mainflux_topic, token)
    end
    local mainflux_sub = conn:subscribe(mainflux_topic)
    local mainflux_msg, err = mainflux_sub:next_msg_with_context(ctx, BUS_TIMEOUT)
    if err then return nil, err end
    local content = mainflux_msg.payload and mainflux_msg.payload.content or nil
    if not content then
        return nil, "no content field found"
    end
    local content_parsed, err = json.decode(content)
    if err then return nil, err end
    local ssid_cfgs = content_parsed.networks and content_parsed.networks.networks or nil
    if (not ssid_cfgs) then
        return nil, "No ssid configs found"
    end

    local ssids = {}
    for _, ssid_cfg in ipairs(ssid_cfgs) do
        local ssid = {}
        for k, v in pairs(base_ssid_cfg) do
            ssid[k] = v
        end
        for k, v in pairs(ssid_cfg) do
            local key = mainflux_to_ssid_keys[k] or k
            -- This is a temporary workaround until we fix our mainflux naming
            if key == "network" and v == "jng" then
                v = "adm"
            end
            ssid[key] = v
        end
        table.insert(ssids, ssid)
    end
    return ssids
end

return {
    parse_mainflux_ssids = parse_mainflux_ssids
}
