local fibers = require "fibers"
local exec = require "fibers.io.exec"
local sleep = require "fibers.sleep"
local scope = require "fibers.scope"
local op = require "fibers.op"

--- Parses the output of a sim slot status line
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


local function add_mode_funcs(ModemBackend)
    --- Make an op to listen for sim prescence
    ---@return Op
    function ModemBackend:wait_for_sim_present_op()
        return op.guard(function()
            return scope.run_op(function(s)
                -- Start QMI monitor command
                local cmd = exec.command {
                    "qmicli", "-p", "-d", self.identity.primary_port, "--uim-monitor-slot-status",
                    stdin = "null",
                    stdout = "pipe",
                    stderr = "stdout"
                }

                -- Get stdout stream (starts command automatically)
                local stdout, err = cmd:stdout_stream()
                if not stdout then
                    -- Return error result from scope - won't propagate to caller
                    return false, "Failed to start QMI monitor: " .. tostring(err)
                end

                -- Command handles stream cleanup automatically via scope finalizer

                -- Read chunks until we find "Slot status: active"
                while true do
                    local chunk = s:perform(stdout:read_line_op({
                        terminator = "Slot status: active",
                        keep_terminator = true,
                    }))

                    if not chunk then
                        -- EOF - return error result from scope
                        return false, "QMI monitor stream closed"
                    end

                    -- Parse the chunk (includes Card status + Slot status lines)
                    local card_status, parse_err = parse_slot_status(chunk)

                    if parse_err == "" and card_status ~= "" then
                        -- Valid parse - return true if present, false if absent
                        return card_status == "present"
                    end

                    -- If parse failed, continue reading next chunk
                end
            end)
            :wrap(function(st, _, ...)
                if st == 'ok' then
                    return ...  -- Returns the boolean (and optional error string)
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
        local cmd = exec.command {
            "qmicli", "-p", "-d", self.identity.primary_port, "--uim-get-card-status",
            stdin = "null",
            stdout = "pipe",
            stderr = "stdout"
        }
        local out, status, code, _, err = fibers.perform(cmd:combined_output_op())
        if status ~= "exited" or code ~= 0 then
            return false, "Failed to execute qmicli command: " .. tostring(err)
        end

        local state, parse_err = parse_slot_status(out)
        if parse_err ~= "" then
            return false, "Failed to parse qmicli output: " .. tostring(parse_err)
        end
        return state == 'present', ""
    end

    --- Check for sim presence, will cause a sim_present_op to emit if present
    ---@param cooldown number? time to wait between power off and on commands, default 1 second
    ---@return boolean ok
    ---@return string error
    function ModemBackend:trigger_sim_presence_check(cooldown)
        cooldown = cooldown or 1
        --- Set power low
        local cmd = exec.command {
            "qmicli", "-p", "-d", self.identity.primary_port, "--uim-sim-power-off=1",
            stdin = "null",
            stdout = "pipe",
            stderr = "stdout"
        }
        local _, status, code, _, err = fibers.perform(cmd:combined_output_op())
        if status ~= "exited" or code ~= 0 then
            return false, "Failed to execute qmicli power off command: " .. tostring(err)
        end

        sleep.sleep(cooldown)

        --- Set power high
        local cmd_on = exec.command {
            "qmicli", "-p", "-d", self.identity.primary_port, "--uim-sim-power-on=1",
            stdin = "null",
            stdout = "pipe",
            stderr = "stdout"
        }
        local _, status_on, code_on, _, err_on = fibers.perform(cmd_on:combined_output_op())
        if status_on ~= "exited" or code_on ~= 0 then
            return false, "Failed to execute qmicli power on command: " .. tostring(err_on)
        end

        return true, ""
    end
end

return {
    add_mode_funcs = add_mode_funcs
}
