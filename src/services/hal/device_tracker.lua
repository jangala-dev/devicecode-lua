tracker = {}
tracker.__index = tracker

local function new()
    return setmetatable({current_idx = 1, devices = {}}, tracker)
end

function tracker:get(index)
    return self.devices[index]
end

function tracker:add(device)
    local dev_idx = self.current_idx
    self.devices[dev_idx] = device
    self.current_idx = self.current_idx + 1
    return dev_idx
end

function tracker:next_index()
    return self.current_idx
end
function tracker:remove(index)
    if self.devices[index] ~= nil then
        self.devices[index] = nil
        return true
    end
    return false
end

return {
    new = new
}
