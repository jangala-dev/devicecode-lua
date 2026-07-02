local exec = require "fibers.io.exec"

local M = {}

---Flags for long-running modem helper commands owned by devicecode.
---process_group is always requested so shutdown reaches simple child trees.
---parent_death_signal is added when the selected lua-fibers backend advertises it.
---It may be native on pidfd/FFI backends or reaper-backed on OpenWrt plain Lua.
---@return table flags
function M.owned_monitor_flags()
    local flags = {
        process_group = true,
    }

    if type(exec.supports) == "function" and exec.supports("parent_death_signal") then
        flags.parent_death_signal = "TERM"
    end

    return flags
end

return M
