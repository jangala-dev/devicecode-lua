--- Default try to get value from cache, if not present fetch modem info and try again
---@param identity ModemIdentity
---@param key string
---@param cache Cache
---@param ret_type string
---@param timeout number?
---@return any value
---@return string error
local function get_cached_value(identity, key, cache, ret_type, timeout, fetch_fn)
    local cached = cache:get(key, timeout)
    if cached then
        return cached, ""
    end

    local err = fetch_fn(identity, cache)
    if err ~= "" then
        return nil, "Failed to fetch info: " .. tostring(err)
    end

    local value = cache:get(key, timeout)
    if not value then
        return nil, "Value not found in cache after refresh: " .. tostring(key)
    end

    if type(value) == ret_type then
        return value, ""
    else
        return nil, "Cached value has wrong type: expected " .. ret_type .. ", got " .. type(value)
    end
end

return {
    get_cached_value = get_cached_value,
}
