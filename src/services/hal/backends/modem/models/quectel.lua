local exec = require "fibers.io.exec"
local fibers = require "fibers"
local sleep = require "fibers.sleep"
local op = require "fibers.op"
local scope = require "fibers.scope"

local at = require "services.hal.backends.modem.at"

local DEFAULT_TIMEOUT = 5
local SIM_POLL_INTERVAL = 5

local function firmware_version_string(fwversion)
    if not fwversion then return nil end
    local version_string = string.match(fwversion, "^%w+_(%w+%.%w+)")
    return version_string
end

local function firmware_version_code(version_str)
    local major, minor = string.match(version_str or "", "^(%w+)%.(%w+)")
    local major_num = tonumber(major, 16)
    local minor_num = tonumber(minor)
    if major_num and minor_num then
        return major_num * 1000 + minor_num
    else
        return nil, "Invalid firmware version format"
    end
end

local funcs = {
    -- This is a special case for the RM520N, it has a initial bearer which will always cause a
    -- multiple PDN failure unless set to the APN we want to use OR set to empty.
    {
        name = 'connect',
        conditionals = {
            function(backend, model, _)
                return model == 'rm520n' and backend.base == "linux_mm"
            end
        },
        func = function(backend, connection_string)
            local st, _, result_or_err = fibers.run_scope(function()
                local cmd_clear = exec.command {
                    "mmcli", "-m", backend.identity.address, "--3gpp-set-initial-eps-bearer-settings=apn=",
                    stdin = "null",
                    stdout = "pipe",
                    stderr = "stdout"
                }
                local _, status, code, _, err = fibers.perform(cmd_clear:combined_output_op())
                if status ~= "exited" or code ~= 0 then
                    error(err or "Failed to clear initial bearer settings")
                end
                local connect_cmd = exec.command {
                    "mmcli", "-m", backend.identity.address, "--connect=" .. connection_string,
                    stdin = "null",
                    stdout = "pipe",
                    stderr = "stdout"
                }
                local out, conn_status, conn_code, _, conn_err = fibers.perform(connect_cmd:combined_output_op())
                if conn_status ~= "exited" or conn_code ~= 0 then
                    error(conn_err or "Failed to connect")
                end
                return out
            end)
            if st == "ok" then
                return result_or_err, ""
            else
                return false, result_or_err or "Command failed"
            end
        end
    },
    {
        name = 'firmware',
        conditionals = {
            function(_, model, _)
                return model == 'rm520n' or model == 'eg25' or model == 'ec25' or model == 'em12'
            end
        },
        func = function(backend)
            ---@cast backend ModemBackend
            local firmware = backend.cache:get("firmware")
            if firmware then return firmware, "" end
            local at_send_op = at.send_op(backend.identity.at_port, "AT+QGMR", {
                terminal_patterns = {
                    { pattern = "^%w+_%w+%.%w+%.%w+%.%w+$", is_error = false }
                }
            })
            local source, resp, err = fibers.perform(op.named_choice({
                at = at_send_op,
                timeout = sleep.sleep_op(DEFAULT_TIMEOUT)
            }))

            if err then
                return nil, "Failed to get firmware version: " .. err
            end

            if source == "timeout" then
                return nil, "Timed out while getting firmware version"
            elseif source == "at" then
                local firmware_version = string.match(resp[#resp], "([%w]+_[%w]+%.[%w]+%.[%w]+%.[%w]+)")
                if firmware_version then
                    backend.cache:set("firmware", firmware_version)
                    return firmware_version, ""
                else
                    return nil, "Firmware version not found in AT response"
                end
            end
        end
    },
    {
        -- On em06 (all firmware) and eg25-g (≤ 01.002) the UIM slot monitor cannot be relied upon
        -- to fire on SIM removal or insertion. Override with a polling implementation using
        -- is_sim_present(). listen_for_sim() drives trigger_sim_presence_check() for insertion.
        name = 'wait_for_sim_present_op',
        conditionals = {
            function(backend, model, _)
                if model == 'em06' then return true end
                if model ~= 'eg25' then return false end
                if type(backend.firmware) ~= "function" then return false end
                for _ = 0, 2 do
                    local firmware_version, err = backend:firmware()
                    if err == "" and firmware_version then
                        local version_code = firmware_version_code(firmware_version_string(firmware_version))
                        return version_code ~= nil and version_code <= firmware_version_code("01.002")
                    end
                    sleep.sleep(1)
                end
                return false
            end
        },
        func = function(backend)
            return op.guard(function()
                return scope.run_op(function(s)
                    while true do
                        local present, err = backend:is_sim_present()
                        if err ~= "" then
                            error("Failed to poll SIM presence: " .. err)
                        end
                        if present ~= backend.last_sim_state then
                            backend.last_sim_state = present
                            return present, ""
                        end
                        s:perform(sleep.sleep_op(SIM_POLL_INTERVAL))
                    end
                end)
                :wrap(function(st, _, ...)
                    if st == 'ok' then
                        return ...
                    elseif st == 'cancelled' then
                        return false, "cancelled"
                    else
                        return false, (... or "SIM poll failed")
                    end
                end)
            end)
        end
    }
    -- Other functions
}

--- Add model specific functions to the backend
---@param backend ModemBackend
---@param model string
---@param variant string
local function add_model_funcs(backend, model, variant)
    for _, f in ipairs(funcs) do
        for _, cond in ipairs(f.conditionals) do
            if cond(backend, model, variant) then
                backend[f.name] = f.func
                break
            end
        end
    end
end

return {
    add_model_funcs = add_model_funcs
}
