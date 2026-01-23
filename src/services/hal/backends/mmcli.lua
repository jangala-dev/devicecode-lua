local exec = require "fibers.exec"

local backend = {}

function backend.monitor_modems()
    return exec.command('mmcli', '-M')
end

function backend.inhibit(device)
    return exec.command('mmcli', '-m', device, '--inhibit')
end

function backend.connect(ctx, device, connection_string)
    connection_string = string.format("--simple-connect=%s", connection_string)
    return exec.command_context(ctx, 'mmcli', '-m', device, connection_string)
end

function backend.disconnect(ctx, device)
    return exec.command_context(ctx, 'mmcli', '-m', device, '--simple-disconnect')
end

function backend.reset(ctx, device)
    return exec.command_context(ctx, 'mmcli', '-m', device, '-r')
end

function backend.enable(ctx, device)
    return exec.command_context(ctx, 'mmcli', '-m', device, '-e')
end

function backend.disable(ctx, device)
    return exec.command_context(ctx, 'mmcli', '-m', device, '-d')
end

function backend.monitor_state(device)
    return exec.command('mmcli', '-m', device, '-w')
end

function backend.information(ctx, device)
    return exec.command_context(ctx, 'mmcli', '-J', '-m', device)
end

function backend.sim_information(ctx, device)
    return exec.command_context(ctx, 'mmcli', '-J', '-i', device)
end
function backend.location_status(ctx, device)
    return exec.command_context(ctx, 'mmcli', '-J', '-m', device, '--location-status')
end

function backend.signal_setup(ctx, device, rate)
    return exec.command_context(ctx, 'mmcli', '-m', device, '--signal-setup=' .. tostring(rate))
end

function backend.signal_get(ctx, device)
    return exec.command_context(ctx, 'mmcli', '-J', '-m', device, '--signal-get')
end

function backend.three_gpp_set_initial_eps_bearer_settings(ctx, device, settings)
    local settings_string = string.format("--3gpp-set-initial-eps-bearer-settings=%s", settings)
    return exec.command_context(ctx, 'mmcli', '-m', device, settings_string)
end

local function monitor_modems()
    return backend.monitor_modems()
end

local function inhibit(ctx, device)
    return backend.inhibit(device)
end

local function connect(ctx, device, connection_string)
    return backend.connect(ctx, device, connection_string)
end

local function disconnect(ctx, device)
    return backend.disconnect(ctx, device)
end

local function reset(ctx, device)
    return backend.reset(ctx, device)
end

local function enable(ctx, device)
    return backend.enable(ctx, device)
end

local function disable(ctx, device)
    return backend.disable(ctx, device)
end

local function monitor_state(device)
    return backend.monitor_state(device)
end

local function information(ctx, device)
    return backend.information(ctx, device)
end

local function sim_information(ctx, device)
    return backend.sim_information(ctx, device)
end

local function location_status(ctx, device)
    return backend.location_status(ctx, device)
end

local function signal_setup(ctx, device, rate)
    return backend.signal_setup(ctx, device, rate)
end

local function signal_get(ctx, device)
    return backend.signal_get(ctx, device)
end

local function three_gpp_set_initial_eps_bearer_settings(ctx, device, settings)
    return backend.three_gpp_set_initial_eps_bearer_settings(ctx, device, settings)
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

local mmcli_package = {
    monitor_modems = monitor_modems,
    inhibit = inhibit,
    connect = connect,
    disconnect = disconnect,
    reset = reset,
    enable = enable,
    disable = disable,
    monitor_state = monitor_state,
    information = information,
    sim_information = sim_information,
    location_status = location_status,
    signal_setup = signal_setup,
    signal_get = signal_get,
    three_gpp_set_initial_eps_bearer_settings = three_gpp_set_initial_eps_bearer_settings,
    use_backend = use_backend -- function to swap out backend implementations
}

package.loaded['services.hal.drivers.modem.mmcli'] = mmcli_package -- singleton

return mmcli_package
