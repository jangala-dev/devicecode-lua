local fibers = require "fibers"
local exec = require "fibers.io.exec"
local sleep = require "fibers.sleep"
local scope = require "fibers.scope"
local op = require "fibers.op"

local modem_types = require "services.hal.types.modem"

-- ---@param status string?
-- ---@return string card_status
-- ---@return string error
-- local function parse_slot_status(status)
--     if not status or status == "" then
--         return "", "Command closed"
--     end

--     local card_state = status:match("Card state:%s*'([^']+)'")
--     if not card_state then
--         return "", "could not parse card state"
--     end

--     if card_state == "present" then
--         return "present", ""
--     end

--     return "absent", ""
-- end

--- Parses the output of a sim slot status entry
---@param status string?
---@return string card_status
---@return string error
local function parse_slot_status(status)
    if not status or status == "" then
        return "", "Command closed"
    end
    for card_status, slot_status in status:gmatch("Card status:%s*(%S+).-Slot status:%s*(%S+)") do
        if slot_status == "active" then
            return card_status, ""
        end
    end

    return "", 'could not parse (no active slot or invalid string format)'
end

---@param identity ModemIdentity
---@return string?
---@return string?
---@return string error
local function read_home_network_info(identity)
    local st, _, result_or_err = fibers.run_scope(function()
        local cmd = exec.command {
            "qmicli", "-p", "-d", identity.mode_port, "--nas-get-home-network",
            stdin = "null",
            stdout = "pipe",
            stderr = "stdout"
        }
        local out, status, code, _, err = fibers.perform(cmd:combined_output_op())
        if status ~= "exited" or code ~= 0 then
            error("Failed to execute qmicli command: --nas-get-home-network, reason: " .. tostring(err))
        end

        local mcc = out:match("MCC:%s+'(%d+)'")
        local mnc = out:match("MNC:%s+'(%d+)'")
        if not mcc or not mnc then
            error("Failed to parse qmicli output: " .. tostring(out))
        end

        return { mcc = mcc, mnc = mnc }
    end)

    if st == "ok" then
        return result_or_err.mcc, result_or_err.mnc, ""
    end
    return nil, nil, result_or_err or "Unknown error"
end

---@param identity ModemIdentity
---@return string?
---@return string error
local function read_gid1(identity)
    local st, _, gid1_or_err = fibers.run_scope(function()
        local cmd = exec.command {
            "qmicli", "-p", "-d", identity.mode_port, "--uim-read-transparent=0x3F00,0x7FFF,0x6F3E",
            stdin = "null",
            stdout = "pipe",
            stderr = "stdout"
        }
        local out, status, code, _, err = fibers.perform(cmd:combined_output_op())
        if status ~= "exited" or code ~= 0 then
            error("Failed to execute qmicli command: --uim-read-transparent, reason: " .. tostring(err))
        end

        local gid1 = out:match("%s+(%S+)%s*$")
        if not gid1 then
            error("Failed to parse qmicli output: " .. tostring(out))
        end

        return gid1:gsub(":", "")
    end)

    if st == "ok" then
        return gid1_or_err, ""
    end
    return nil, gid1_or_err or "Unknown error"
end

---@param identity ModemIdentity
---@return string?
---@return string error
local function read_rf_band_info(identity)
    local st, _, band_or_err = fibers.run_scope(function()
        local cmd = exec.command {
            "qmicli", "-p", "-d", identity.mode_port, "--nas-get-rf-band-info",
            stdin = "null",
            stdout = "pipe",
            stderr = "stdout"
        }
        local out, status, code, _, err = fibers.perform(cmd:combined_output_op())
        if status ~= "exited" or code ~= 0 then
            error("Failed to execute qmicli command: --nas-get-rf-band-info, reason: " .. tostring(err))
        end

        local active_band_class = out:match("Active Band Class:%s*'([^']+)'")
        if not active_band_class then
            error("Failed to parse qmicli output: " .. tostring(out))
        end

        return active_band_class
    end)

    if st == "ok" then
        return band_or_err, ""
    end
    return nil, band_or_err or "Unknown error"
end

local function add_mode_funcs(ModemBackend)
    ---@cast ModemBackend ModemBackend
    local base_read_network_info = ModemBackend.read_network_info
    local base_read_sim_info = ModemBackend.read_sim_info

    ---@return boolean ok
    ---@return string error
    function ModemBackend:start_sim_presence_monitor()
        if self.sim_present then
            return false, "Already monitoring sim presence"
        end

        local cmd = exec.command {
            "qmicli", "-p", "-d", self.identity.mode_port, "--uim-monitor-slot-status",
            stdin = "null",
            stdout = "pipe",
            stderr = "stdout"
        }

        local stdout, err = cmd:stdout_stream()
        if not stdout then
            return false, "Failed to start QMI monitor: " .. tostring(err)
        end
        self.sim_present = {
            cmd = cmd,
            stdout = stdout
        }
        return true, ""
    end

    ---@return Op
    function ModemBackend:wait_for_sim_present_op()
        return op.guard(function()
            return scope.run_op(function(s)
                    if not self.sim_present then
                        return false, "Sim presence monitor not started"
                    end
                    while true do
                        local chunk = s:perform(self.sim_present.stdout:read_line_op({
                            terminator = "Slot status: active",
                            keep_terminator = true,
                        }))

                        if not chunk then
                            return false, "Stream closed"
                        end

                        local card_status, parse_err = parse_slot_status(chunk)
                        if parse_err == "" and card_status ~= "" then
                            return card_status == "present", ""
                        end
                    end
                end)
                :wrap(function(st, _, ...)
                    if st == 'ok' then
                        return ...
                    elseif st == 'cancelled' then
                        return false, "cancelled"
                    else
                        return false, (... or "QMI monitor failed")
                    end
                end)
        end)
    end

    ---@return boolean sim_present
    function ModemBackend:wait_for_sim_present()
        return fibers.perform(self:wait_for_sim_present_op())
    end

    ---@return boolean sim_present
    ---@return string error
    function ModemBackend:is_sim_present()
        local st, _, present_or_err = fibers.run_scope(function()
            local cmd = exec.command {
                "qmicli", "-p", "-d", self.identity.mode_port, "--uim-get-slot-status",
                stdin = "null",
                stdout = "pipe",
                stderr = "stdout"
            }
            local out, status, code, _, err = fibers.perform(cmd:combined_output_op())
            if status ~= "exited" or code ~= 0 then
                error("Failed to execute qmicli command: " .. tostring(err))
            end

            local state, parse_err = parse_slot_status(out)
            if parse_err ~= "" then
                error("Failed to parse qmicli output: " .. tostring(parse_err))
            end
            return state == 'present'
        end)

        if st == "ok" then
            return present_or_err, ""
        end
        return false, present_or_err or "Unknown error"
    end

    ---@param cooldown number?
    ---@return boolean ok
    ---@return string error
    function ModemBackend:trigger_sim_presence_check(cooldown)
        local st, _, err = fibers.run_scope(function()
            local errors = {}
            cooldown = cooldown or 1
            local cmd = exec.command {
                "qmicli", "-p", "-d", self.identity.mode_port, "--uim-sim-power-off=1",
                stdin = "null",
                stdout = "pipe",
                stderr = "stdout"
            }
            local _, status, code, _, power_err = fibers.perform(cmd:combined_output_op())
            if status ~= "exited" or code ~= 0 then
                table.insert(errors, "Failed to execute qmicli power off command: " .. tostring(power_err))
            end

            sleep.sleep(cooldown)

            local cmd_on = exec.command {
                "qmicli", "-p", "-d", self.identity.mode_port, "--uim-sim-power-on=1",
                stdin = "null",
                stdout = "pipe",
                stderr = "stdout"
            }
            local _, status_on, code_on, _, err_on = fibers.perform(cmd_on:combined_output_op())
            if status_on ~= "exited" or code_on ~= 0 then
                table.insert(errors, "Failed to execute qmicli power on command: " .. tostring(err_on))
            end

            if #errors > 0 then
                error(table.concat(errors, ";\n"))
            end
        end)

        return st == "ok", err or ""
    end

    ---@return ModemNetworkInfo?
    ---@return string error
    function ModemBackend:read_network_info()
        local info, err = base_read_network_info(self)
        if not info then
            return nil, err
        end

        local mcc, mnc, network_err = read_home_network_info(self.identity)
        if network_err ~= "" then
            return nil, network_err
        end

        local active_band_class, band_err = read_rf_band_info(self.identity)
        if band_err ~= "" then
            return nil, band_err
        end

        return modem_types.new.ModemNetworkInfo(
            info.operator,
            info.access_techs,
            mcc,
            mnc,
            active_band_class
        )
    end

    ---@return ModemSimInfo?
    ---@return string error
    function ModemBackend:read_sim_info()
        local info, err = base_read_sim_info(self)
        if not info then
            return nil, err
        end

        local gid1, gid_err = read_gid1(self.identity)
        if gid_err ~= "" then
            return nil, gid_err
        end

        return modem_types.new.ModemSimInfo(
            info.sim,
            info.iccid,
            info.imsi,
            gid1
        )
    end
end

return {
    add_mode_funcs = add_mode_funcs
}
