-- driver/model.lua

local function add_model_funcs(modem)
    local manufacturer = modem.manufacturer
    local status, model_funcs = pcall(require, "services.gsm.modem_driver.model." .. manufacturer)
    if not status then
        return false, "Model functions not found for manufacturer: " .. modem.manufacturer
    end
    return model_funcs(modem)
end

return {
    add_model_funcs = add_model_funcs
}
