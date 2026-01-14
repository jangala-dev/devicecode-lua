local path = package.path

local function update_shim_path(shim_base_dir, shim_name)
    package.path = shim_base_dir .. shim_name .. "/?.lua;" .. path
end

-- Old implementation of loading packages after shim switching, used for driver tests
local function uncached_require(module)
    package.loaded[module] = nil
    package.loaded['services.hal.mmcli'] = nil
    package.loaded['services.hal.qmicli'] = nil
    package.loaded['services.hal.at'] = nil
    package.loaded['services.hal.modem_driver'] = nil
    return require(module)
end

-- new implemeentation of loading packages after shim switching
-- build up a list of modules to be purged every time a package is loaded
-- makes sure packages stay up to date
local ModuleLoader = {}
ModuleLoader.__index = ModuleLoader

local function new_module_loader()
    return setmetatable({ uncached_modules = {} }, ModuleLoader)
end

function ModuleLoader:add_uncacheable(module)
    table.insert(self.uncached_modules, module)
end

function ModuleLoader:require(module)
    for _, uncache_module in ipairs(self.uncached_modules) do
        package.loaded[uncache_module] = nil
    end
    package.loaded[module] = nil
    return require(module)
end
return {
    update_shim_path = update_shim_path,
    uncached_require = uncached_require,
    new_module_loader = new_module_loader
}
