local exec = require "fibers.exec"

local function uim_get_card_status(ctx, port)
    return exec.command_context(ctx, "qmicli", "-p", "-d", port, "--uim-get-card-status")
end

local function uim_sim_power_off(ctx, port)
    return exec.command_context(ctx, "qmicli", "-p", "-d", port, "--uim-sim-power-off=1")
end

local function uim_sim_power_on(ctx, port)
    return exec.command_context(ctx, "qmicli", "-p", "-d", port, "--uim-sim-power-on=1")
end

local function uim_monitor_slot_status(port)
    return exec.command('qmicli', '-p', '-d', port, '--uim-monitor-slot-status')
end

local function uim_read_transparent(ctx, port, address_string)
    local addresses = string.format('--uim-read-transparent=%s', address_string)
    return exec.command_context(ctx, 'qmicli', '-p', '-d', port, addresses)
end

local function nas_get_rf_band_info(ctx, port)
    return exec.command_context(ctx, 'qmicli', '-p', '-d', port)
end
local function nas_get_home_network(ctx, port)
    return exec.command_context(ctx, 'qmicli', '-p', '-d', port, '--nas-get-home-network')
end

local function nas_get_serving_system(ctx, port)
    return exec.command_context(ctx, 'qmicli', '-p', '-d', port, '--nas-get-serving-system')
end
local function nas_get_signal_info(ctx, port)
    return exec.command_context(ctx, 'qmicli', '-p', '-d', port, '--nas-get-signal-info')
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
    nas_get_signal_info = nas_get_signal_info
}
