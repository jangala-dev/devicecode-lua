-- driver/mode.lua

local function add_mode_funcs(modem)
    local mode = modem.mode:lower()
    local status, mode_funcs = pcall(require, "services.hal.drivers.modem.mode." .. mode)
    if not status then
        return false, "Mode driver not found for mode: " .. modem.mode .. "\n\t" .. mode_funcs
    end
    return mode_funcs(modem)
end

return {
    add_mode_funcs = add_mode_funcs
}
