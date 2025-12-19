local exec = require "fibers.exec"

-- Default backend implementation using qmicli commands
local backend = {}

function backend.uim_get_card_status(ctx, port)
    return exec.command_context(ctx, "qmicli", "-p", "-d", port, "--uim-get-card-status")
end

function backend.uim_sim_power_off(ctx, port)
    return exec.command_context(ctx, "qmicli", "-p", "-d", port, "--uim-sim-power-off=1")
end

function backend.uim_sim_power_on(ctx, port)
    return exec.command_context(ctx, "qmicli", "-p", "-d", port, "--uim-sim-power-on=1")
end

function backend.uim_monitor_slot_status(port)
    return exec.command('qmicli', '-p', '-d', port, '--uim-monitor-slot-status')
end

function backend.uim_read_transparent(ctx, port, address_string)
    local addresses = string.format('--uim-read-transparent=%s', address_string)
    return exec.command_context(ctx, 'qmicli', '-p', '-d', port, addresses)
end

function backend.nas_get_rf_band_info(ctx, port)
    return exec.command_context(ctx, 'qmicli', '-p', '-d', port, '--nas-get-rf-band-info')
end

function backend.nas_get_home_network(ctx, port)
    return exec.command_context(ctx, 'qmicli', '-p', '-d', port, '--nas-get-home-network')
end

function backend.nas_get_serving_system(ctx, port)
    return exec.command_context(ctx, 'qmicli', '-p', '-d', port, '--nas-get-serving-system')
end

function backend.nas_get_signal_info(ctx, port)
    return exec.command_context(ctx, 'qmicli', '-p', '-d', port, '--nas-get-signal-info')
end

local function uim_get_card_status(ctx, port)
    return backend.uim_get_card_status(ctx, port)
end

local function uim_sim_power_off(ctx, port)
    return backend.uim_sim_power_off(ctx, port)
end

local function uim_sim_power_on(ctx, port)
    return backend.uim_sim_power_on(ctx, port)
end

local function uim_monitor_slot_status(port)
    return backend.uim_monitor_slot_status(port)
end

local function uim_read_transparent(ctx, port, address_string)
    return backend.uim_read_transparent(ctx, port, address_string)
end

local function nas_get_rf_band_info(ctx, port)
    return backend.nas_get_rf_band_info(ctx, port)
end

local function nas_get_home_network(ctx, port)
    return backend.nas_get_home_network(ctx, port)
end

local function nas_get_serving_system(ctx, port)
    return backend.nas_get_serving_system(ctx, port)
end

local function nas_get_signal_info(ctx, port)
    return backend.nas_get_signal_info(ctx, port)
end

local function use_backend(new_backend)
    if not new_backend then
        return "No backend provided"
    end
    for name, _ in pairs(backend) do
        if not new_backend[name] then
            return "New backend does not implement function: " .. name
        end
    end
    backend = new_backend
end

local qmicli_package = {
    uim_get_card_status = uim_get_card_status,
    uim_sim_power_off = uim_sim_power_off,
    uim_sim_power_on = uim_sim_power_on,
    uim_monitor_slot_status = uim_monitor_slot_status,
    uim_read_transparent = uim_read_transparent,

    nas_get_rf_band_info = nas_get_rf_band_info,
    nas_get_home_network = nas_get_home_network,
    nas_get_serving_system = nas_get_serving_system,
    nas_get_signal_info = nas_get_signal_info,

    use_backend = use_backend -- function to swap out backend implementations
}

package.loaded['services.hal.drivers.modem.qmicli'] = qmicli_package -- singleton
return qmicli_package
