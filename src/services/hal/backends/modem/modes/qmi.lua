local fibers = require "fibers"
local exec = require "fibers.io.exec"
local sleep = require "fibers.sleep"
local scope = require "fibers.scope"
local op = require "fibers.op"

local fetch = require "services.hal.backends.fetch"

--- Parses the output of a sim slot status line
---@param status string?
---@return string card_status
---@return string error
local function parse_slot_status(status)
    if not status or status == "" then
        return "", "Command closed"
    end

    local card_state = status:match("Card state:%s*'([^']+)'")
    if not card_state then
        return "", "could not parse card state"
    end

    if card_state == "present" then
        return "present", ""
    end

    return "absent", ""
end

--- Gets the home network info (MCC/MNC) for a modem, with caching
---@param identity ModemIdentity
---@param cache Cache
---@return string error
local function fetch_home_network_info(identity, cache)
    local st, _, err = fibers.run_scope(function()
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

        cache:set("mcc", mcc)
        cache:set("mnc", mnc)
    end)
    return st ~= "ok" and err or ""
end

--- Gets gid1 for a sim card and caches it
---@param identity ModemIdentity
---@param cache Cache
---@return string error
local function fetch_gid1(identity, cache)
    local st, _, err = fibers.run_scope(function()
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

        -- Parse the hex string after "Read result:"
        local gid1 = out:match("%s+(%S+)%s*$"):gsub(":", "")
        if not gid1 then
            error("Failed to parse qmicli output: " .. tostring(out))
        end

        cache:set("gid1", gid1)
    end)
    return st ~= "ok" and err or ""
end

--- Gets the RF band info for a modem and caches active_band_class
---@param identity ModemIdentity
---@param cache Cache
---@return string error
local function fetch_rf_band_info(identity, cache)
    local st, _, err = fibers.run_scope(function()
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

        cache:set("active_band_class", active_band_class)
    end)
    return st ~= "ok" and err or ""
end


local function add_mode_funcs(ModemBackend)
    --- Start command to read sim presence
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

    --- Make an op that completes when the UIM slot status changes to reflect a new SIM state.
    --- Behaviour varies by modem and firmware — on some models the slot monitor cannot be relied
    --- upon to fire on removal or insertion. See models/quectel.lua for the polling override.
    ---@return Op
    function ModemBackend:wait_for_sim_present_op()
        return op.guard(function()
            return scope.run_op(function(s)
                    if not self.sim_present then
                        return false, "Sim presence monitor not started"
                    end
                    -- Read chunks until we find "Slot status: active"
                    while true do
                        local chunk = s:perform(self.sim_present.stdout:read_line_op({
                            terminator = "Slot status: active",
                            keep_terminator = true,
                        }))

                        if not chunk then
                            -- EOF - return error result from scope
                            return false, "Stream closed"
                        end

                        -- Parse the chunk (includes Card status + Slot status lines)
                        local card_status, parse_err = parse_slot_status(chunk)

                        if parse_err == "" and card_status ~= "" then
                            -- Valid parse - return true if present, false if absent
                            return card_status == "present", ""
                        end

                        -- If parse failed, continue reading next chunk
                    end
                end)
                :wrap(function(st, _, ...)
                    if st == 'ok' then
                        return ... -- Returns the boolean (and optional error string)
                    elseif st == 'cancelled' then
                        return false, "cancelled"
                    else
                        -- Scope failed - return the error from scope body
                        return false, (... or "QMI monitor failed")
                    end
                end)
        end)
    end

    --- Wait for sim to become present
    ---@return boolean sim_present
    function ModemBackend:wait_for_sim_present()
        return fibers.perform(self:wait_for_sim_present_op())
    end

    --- Poll for sim presence, returns true if sim is present, false if not, or error if an error occurs
    ---@return boolean sim_present
    ---@return string error
    function ModemBackend:is_sim_present()
        local st, _, present_or_err = fibers.run_scope(function()
            local cmd = exec.command {
                "qmicli", "-p", "-d", self.identity.mode_port, "--uim-get-card-status",
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
        else
            return false, present_or_err or "Unknown error"
        end
    end

    --- Check for sim presence, will cause a sim_present_op to emit if present
    ---@param cooldown number? time to wait between power off and on commands, default 1 second
    ---@return boolean ok
    ---@return string error
    function ModemBackend:trigger_sim_presence_check(cooldown)
        local st, _, err = fibers.run_scope(function()
            local errors = {}
            cooldown = cooldown or 1
            --- Set power low
            local cmd = exec.command {
                "qmicli", "-p", "-d", self.identity.mode_port, "--uim-sim-power-off=1",
                stdin = "null",
                stdout = "pipe",
                stderr = "stdout"
            }
            local _, status, code, _, err = fibers.perform(cmd:combined_output_op())
            if status ~= "exited" or code ~= 0 then
                table.insert(errors, "Failed to execute qmicli power off command: " .. tostring(err))
            end

            sleep.sleep(cooldown)

            --- Set power high
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

    --- Gets a simcards MCC
    ---@param timeout number? Cache timeout in seconds (optional)
    ---@return string mcc
    ---@return string error
    function ModemBackend:mcc(timeout)
        return fetch.get_cached_value(self.identity, "mcc", self.cache, "string", timeout, fetch_home_network_info)
    end

    --- Gets a simcards MNC
    ---@param timeout number? Cache timeout in seconds (optional)
    ---@return string mnc
    ---@return string error
    function ModemBackend:mnc(timeout)
        return fetch.get_cached_value(self.identity, "mnc", self.cache, "string", timeout, fetch_home_network_info)
    end

    --- Gets a simcards GID1 value
    ---@param timeout number? Cache timeout in seconds (optional)
    ---@return string gid1
    ---@return string error
    function ModemBackend:gid1(timeout)
        return fetch.get_cached_value(self.identity, "gid1", self.cache, "string", timeout, fetch_gid1)
    end

    --- Gets the active band class for the modem
    ---@param timeout number? Cache timeout in seconds (optional)
    ---@return string active_band_class
    ---@return string error
    function ModemBackend:active_band_class(timeout)
        return fetch.get_cached_value(self.identity, "active_band_class", self.cache, "string", timeout,
            fetch_rf_band_info)
    end
end

return {
    add_mode_funcs = add_mode_funcs
}
