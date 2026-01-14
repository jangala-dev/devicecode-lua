local commands = {}

local function set_command(name, cmd)
    commands[name] = cmd
end

local function uim_get_card_status(ctx, port)
    if not commands.uim_get_card_status then error("uim_get_card_status command not set up") end
    return commands.uim_get_card_status
end

local function uim_sim_power_off(ctx, port)
    if not commands.uim_sim_power_off then error("uim_sim_power_off command not set up") end
    return commands.uim_sim_power_off
end

local function uim_sim_power_on(ctx, port)
    if not commands.uim_sim_power_on then error("uim_sim_power_on command not set up") end
    return commands.uim_sim_power_on
end

local function uim_monitor_slot_status(port)
    if not commands.uim_monitor_slot_status then error("uim_monitor_slot_status command not set up") end
    return commands.uim_monitor_slot_status
end

local function uim_read_transparent(ctx, port, address_string)
    if not commands.uim_read_transparent then error("uim_read_transparent command not set up") end
    return commands.uim_read_transparent
end

local function nas_get_rf_band_info(ctx, port)
    if not commands.nas_get_rf_band_info then error("nas_get_rf_band_info command not set up") end
    return commands.nas_get_rf_band_info
end

local function nas_get_home_network(ctx, port)
    if not commands.nas_get_home_network then error("nas_get_home_network command not set up") end
    return commands.nas_get_home_network
end

local function nas_get_serving_system(ctx, port)
    if not commands.nas_get_serving_system then error("nas_get_serving_system command not set up") end
    return commands.nas_get_serving_system
end

local function nas_get_signal_info(ctx, port)
    if not commands.nas_get_signal_info then error("nas_get_signal_info command not set up") end
    return commands.nas_get_signal_info
end

return {
    uim_get_card_status = uim_get_card_status,
    uim_sim_power_off = uim_sim_power_off,
    uim_sim_power_on = uim_sim_power_on,
    uim_monitor_slot_status = uim_monitor_slot_status,
    uim_read_transparent = uim_read_transparent,

    nas_get_rf_band_info = nas_get_rf_band_info,
    nas_get_home_network = nas_get_home_network,
    nas_get_serving_system = nas_get_serving_system,
    nas_get_signal_info = nas_get_signal_info,

    -- Test harness only
    set_command = set_command,
}
