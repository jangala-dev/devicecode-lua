local exec = require "fibers.io.exec"
local fibers = require "fibers"
local sleep = require "fibers.sleep"
local scope = require "fibers.scope"
local op = require "fibers.op"
local at = require "services.hal.backends.modem.at"

local SIM_POLL_INTERVAL = 5

local function firmware_version_string(fwversion)
    if not fwversion then
        return nil
    end
    local version_string = string.match(fwversion, "^%w+_(%w+%.%w+)")
    return version_string or fwversion
end

local function firmware_version_code(version_str)
    local major, minor = string.match(version_str or "", "^(%w+)%.(%w+)")
    local major_num = tonumber(major, 16)
    local minor_num = tonumber(minor)
    if major_num and minor_num then
        return major_num * 1000 + minor_num
    end
    return nil, "Invalid firmware version format"
end

---@param out string
---@return boolean present
---@return string error
local function parse_card_status(out)
    if not out or out == "" then
        return false, "Empty output"
    end
    local card_state = out:match("Card state:%s*'([^']+)'")
    if not card_state then
        return false, "Could not parse card state from --uim-get-card-status output"
    end
    return card_state == "present", ""
end

--- Helper for checking if a modem runs "legacy" firmware
---@param model string
---@param firmware_fn function
---@return boolean
local function is_legacy_modem(model, firmware_fn)
    --- all em06 devices are legacy
    if model == 'em06' then
        return true
    end
    --- only em06 and eg25 devices have capability to be legacy
    if model ~= 'eg25' then
        return false
    end

    local firmware_version = firmware_fn()
    if not firmware_version or firmware_version == "" then
        return false
    end

    local version_code = firmware_version_code(firmware_version_string(firmware_version))
    return version_code ~= nil and version_code <= firmware_version_code("01.002")
end

local funcs = {
    {
        name = '_read_firmware',
        conditionals = {
            function(_, identity_info)
                return identity_info.model == 'rm520n'
            end
        },
        func = function(identity)
            local AT_TIMEOUT = 10
            local at_send_op = at.send_op(identity.at_port, "AT+QGMR", {
                terminal_patterns = {
                    { pattern = "^%w+_%w+%.%w+%.%w+%.%w+$", is_error = false }
                }
            })
            local source, resp, err = fibers.perform(op.named_choice({
                at = at_send_op,
                timeout = sleep.sleep_op(AT_TIMEOUT)
            }))

            if err then
                return nil, "Failed to get firmware version: " .. err
            end

            if source == "timeout" then
                return nil, "Timed out while getting firmware version"
            elseif source == "at" and resp[#resp] then
                local firmware_version = string.match(resp[#resp], "([%w]+_[%w]+%.[%w]+%.[%w]+%.[%w]+)")
                if firmware_version then
                    return firmware_version, ""
                else
                    return nil, "Firmware version not found in AT response"
                end
            end
        end
    },
    {
        name = 'connect',
        conditionals = {
            function(backend, identity_info)
                local model = identity_info and identity_info.model or nil
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
                    "mmcli", "-m", backend.identity.address, "--simple-connect=" .. connection_string,
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
            end
            return false, result_or_err or "Command failed"
        end
    },
    {
        name = 'wait_for_sim_present_op',
        -- NOTE: _read_firmware must be listed before this hook in funcs so that any
        -- model-specific override is already installed when this conditional runs.
        conditionals = {
            function(backend, identity_info)
                return is_legacy_modem(
                    identity_info.model,
                    function()
                        return backend._read_firmware(backend.identity)
                    end
                )
            end
        },
        func = function(backend)
            ---@cast backend ModemBackend
            return op.guard(function()
                return scope.run_op(function(s)
                        s:perform(sleep.sleep_op(SIM_POLL_INTERVAL))
                        local present, err = backend:is_sim_present()
                        if err ~= "" then
                            return false, "Failed to poll SIM presence: " .. err
                        end

                        return present, ""
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
    },
    {
        name = 'is_sim_present',
        conditionals = {
            function(backend, identity_info)
                ---@cast backend ModemBackend
                ---@cast identity_info ModemIdentityInfo
                local is_legacy = is_legacy_modem(
                    identity_info.model,
                    function()
                        local firmware, err = backend._read_firmware(backend.identity)
                        return firmware
                    end
                ) and identity_info.mode == "qmi"
                return is_legacy
            end
        },
        func = function(backend)
            ---@cast backend ModemBackend
            local st, _, present_or_err = fibers.run_scope(function()
                local cmd = exec.command {
                    "qmicli", "-p", "-d", backend.identity.mode_port, "--uim-get-card-status",
                    stdin = "null",
                    stdout = "pipe",
                    stderr = "stdout"
                }
                local out, status, code, _, err = fibers.perform(cmd:combined_output_op())
                if status ~= "exited" or code ~= 0 then
                    error("Failed to execute qmicli --uim-get-card-status: " .. tostring(err))
                end

                local present, parse_err = parse_card_status(out)
                if parse_err ~= "" then
                    error("Failed to parse qmicli output: " .. tostring(parse_err))
                end
                return present
            end)

            if st == "ok" then
                return present_or_err, ""
            end
            return false, present_or_err or "Unknown error"
        end
    },
}

---@param backend ModemBackend
---@param identity_info ModemIdentityInfo
local function add_model_funcs(backend, identity_info)
    for _, func_def in ipairs(funcs) do
        for _, cond in ipairs(func_def.conditionals) do
            if cond(backend, identity_info) then
                print("attaching method:", func_def.name, "to modem", identity_info.model)
                backend[func_def.name] = func_def.func
                break
            end
        end
    end
end

return {
    add_model_funcs = add_model_funcs
}
