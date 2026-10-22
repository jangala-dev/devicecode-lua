local InitAttempts = {}
InitAttempts.__index = InitAttempts

---@param max_attempts integer
---@return InitAttempts
local function new(max_attempts)
    assert(type(max_attempts) == "number" and max_attempts > 0 and max_attempts % 1 == 0,
        "max_attempts must be a positive integer")
    return setmetatable({
        max_attempts = max_attempts,
        remaining_by_device = {},
    }, InitAttempts)
end

---Record a failed initialization attempt.
---A device at zero is treated as a new physical appearance and starts a fresh cycle.
---@param device string
---@return boolean should_reset
---@return integer remaining_attempts
function InitAttempts:record_failure(device)
    local remaining = self.remaining_by_device[device]
    if remaining == nil or remaining == 0 then
        remaining = self.max_attempts
    end

    remaining = remaining - 1
    self.remaining_by_device[device] = remaining
    return remaining > 0, remaining
end

---@param device string
function InitAttempts:record_success(device)
    self.remaining_by_device[device] = self.max_attempts
end

---@param device string
---@return integer remaining_attempts
function InitAttempts:remaining(device)
    return self.remaining_by_device[device] or self.max_attempts
end

return {
    new = new,
}
