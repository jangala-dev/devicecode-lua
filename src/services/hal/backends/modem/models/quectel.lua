local exec = require "fibers.io.exec"
local fibers = require "fibers"
local sleep = require "fibers.sleep"
local scope = require "fibers.scope"
local op = require "fibers.op"

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

local funcs = {
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
            end
            return false, result_or_err or "Command failed"
        end
    },
    {
        name = 'wait_for_sim_present_op',
        conditionals = {
            function(_, identity_info)
                local model = identity_info and identity_info.model or nil
                if model == 'em06' then
                    return true
                end
                if model ~= 'eg25' then
                    return false
                end
                local firmware_version = identity_info and identity_info.firmware or nil
                if not firmware_version then
                    return false
                end
                local version_code = firmware_version_code(firmware_version_string(firmware_version))
                return version_code ~= nil and version_code <= firmware_version_code("01.002")
            end
        },
        func = function(backend)
            ---@cast backend ModemBackend
            return op.guard(function()
                return scope.run_op(function(s)
                        while true do
                            s:perform(sleep.sleep_op(SIM_POLL_INTERVAL))
                            local present, err = backend:is_sim_present()
                            if err ~= "" then
                                error("Failed to poll SIM presence: " .. err)
                            end

                            local state = backend.last_state_event
                            local state_to = state and state.to or nil

                            if present ~= backend.last_sim_state or (present == false and state_to ~= 'failed') then
                                local last_state = backend.last_sim_state
                                ---@diagnostic disable-next-line: inject-field
                                backend.last_sim_state = present
                                if last_state ~= nil then
                                    return present, ""
                                end
                            end
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
}

---@param backend ModemBackend
---@param identity_info ModemIdentityInfo
local function add_model_funcs(backend, identity_info)
    for _, func_def in ipairs(funcs) do
        for _, cond in ipairs(func_def.conditionals) do
            if cond(backend, identity_info) then
                backend[func_def.name] = func_def.func
                break
            end
        end
    end
end

return {
    add_model_funcs = add_model_funcs
}
