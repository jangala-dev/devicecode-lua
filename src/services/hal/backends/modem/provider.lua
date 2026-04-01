local contract = require "services.hal.backends.modem.contract"

local MODEL_INFO = {
    quectel = {
        -- these are ordered, as eg25gl should match before eg25g
        { mod_string = "UNKNOWN",   rev_string = "eg25gl",   model = "eg25",   model_variant = "gl" },
        { mod_string = "UNKNOWN",   rev_string = "eg25g",    model = "eg25",   model_variant = "g" },
        { mod_string = "UNKNOWN",   rev_string = "ec25e",    model = "ec25",   model_variant = "e" },
        { mod_string = "em06-e",    rev_string = "em06e",    model = "em06",   model_variant = "e" },
        { mod_string = "rm520n-gl", rev_string = "rm520ngl", model = "rm520n", model_variant = "gl" },
        { mod_string = "em12-g", rev_string = "em12g", model = "em12", model_variant = "g" },
        -- more quectel models here
    },
    fibocom = {}
}

local BACKENDS = {
    "linux_mm"
}

--- Utility function to check if a string starts with a given prefix (case-insensitive)
---@param str string
---@param start string
---@return boolean
local function starts_with(str, start)
    if str == nil or start == nil then return false end
    str, start = str:lower(), start:lower()
    -- Use string.sub to get the prefix of mainString that is equal in length to startString
    return string.sub(str, 1, string.len(start)) == start
end

--- Select the first supported provider for the current environment.
---@return table provider
local function get_provider()
    for _, backend_name in ipairs(BACKENDS) do
        local ok, mod = pcall(require, "services.hal.backends.modem.providers." .. backend_name .. ".init")
        if ok and type(mod) == "table" and mod.is_supported and mod.is_supported() then
            return mod
        end
    end
    error("No supported modem provider found")
end

local function new(address)
    local provider = get_provider()
    local impl = provider.backend
    local backend = impl.new(address)
    ---@cast backend ModemBackend
    local drivers, dr_err = backend:drivers()
    if dr_err ~= "" then
        error("Failed to get modem drivers: " .. tostring(dr_err))
    end

    local drivers_str = table.concat(drivers, ",")
    local mode
    if drivers_str:match("qmi_wwan") then
        mode = "qmi"
    elseif drivers_str:match("cdc_mbim") then
        mode = "mbim"
    end

    if mode then
        local ok, driver_mod = pcall(require, "services.hal.backends.modem.modes." .. mode)
        if ok and type(driver_mod) == "table" and driver_mod.add_mode_funcs then
            driver_mod.add_mode_funcs(backend)
        end
    end

    local plugin, pl_err = backend:plugin()
    if pl_err ~= "" then
        error("Failed to get modem plugin status: " .. tostring(pl_err))
    end

    local model, model_err = backend:model()
    if model_err ~= "" then
        error("Failed to get modem model: " .. tostring(model_err))
    end

    local revision, rev_err = backend:revision()
    if rev_err ~= "" then
        error("Failed to get modem revision: " .. tostring(rev_err))
    end

    local model_funcs_loaded = false
    for manufacturer, models in pairs(MODEL_INFO) do
        if string.match(plugin:lower(), manufacturer) then
            for _, details in ipairs(models) do
                if details.mod_string == model:lower()
                    or starts_with(revision, details.rev_string) then
                    model = details.model
                    local model_variant = details.model_variant
                    local ok, model_mod = pcall(require, "services.hal.backends.modem.models." .. manufacturer)
                    if ok and type(model_mod) == "table" and model_mod.add_model_funcs then
                        model_mod.add_model_funcs(backend, model, model_variant)
                        model_funcs_loaded = true
                    end
                    break
                end
            end
        end
        if model_funcs_loaded then break end
    end

    local iface_err = contract.validate(backend)
    if iface_err ~= "" then
        error("Modem backend does not implement required interface: " .. tostring(iface_err))
    end

    return backend
end

--- Create a new ModemMonitor using the selected provider.
---@return ModemMonitor monitor
local function new_monitor()
    local provider = get_provider()
    if not provider.new_monitor then
        error("Selected modem provider does not support modem monitoring")
    end
    local monitor, err = provider.new_monitor()
    if not monitor then
        error("Failed to create modem monitor: " .. tostring(err))
    end
    local validate_err = contract.validate_monitor(monitor)
    if validate_err ~= "" then
        error("Modem monitor does not satisfy required interface: " .. validate_err)
    end
    return monitor
end

return {
    new = new,
    new_monitor = new_monitor,
}
