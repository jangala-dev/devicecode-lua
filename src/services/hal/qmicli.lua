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

local function nas_get_home_network(ctx, port)
    return exec.command_context(ctx, 'qmicli', '-p', '-d', port, '--nas-get-home-network')
end

local function uim_read_transparent(ctx, port, address_string)
    local addresses = string.format('--uim-read-transparent=%s', address_string)
    return exec.command_context(ctx, 'qmicli', '-p', '-d', port, addresses)
end
return {
    uim_get_card_status = uim_get_card_status,
    uim_sim_power_off = uim_sim_power_off,
    uim_sim_power_on = uim_sim_power_on,
    uim_monitor_slot_status = uim_monitor_slot_status,
    nas_get_home_network = nas_get_home_network,
    uim_read_transparent = uim_read_transparent
}
