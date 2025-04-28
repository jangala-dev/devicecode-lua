local ShimShifter = {}
ShimShifter.__index = ShimShifter

local function new()
    local self = setmetatable({}, ShimShifter)
    self.uncached_modules = {}
    self.package_path_og = package.path
    return self
end

function ShimShifter:add_uncacheable(module)
    table.insert(self.uncached_modules, module)
end

function ShimShifter:set_shim(path)
    for _, uncache_module in ipairs(self.uncached_modules) do
        package.loaded[uncache_module] = nil
    end
    package.path = path .. "/?.lua;" .. self.package_path_og
end

function ShimShifter:require(module)
    return require(module)
end

function ShimShifter:reset()
    for _, uncache_module in ipairs(self.uncached_modules) do
        package.loaded[uncache_module] = nil
    end
    package.path = self.package_path_og
end

return {
    new = new
}
