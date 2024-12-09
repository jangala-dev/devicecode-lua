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

return {
    uim_get_card_status = uim_get_card_status,
    uim_sim_power_off = uim_sim_power_off,
    uim_sim_power_on = uim_sim_power_on
}