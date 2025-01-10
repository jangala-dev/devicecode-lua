local path = package.path

local function update_shim_path(shim_base_dir, shim_name)
    package.path = shim_base_dir .. shim_name .. "/?.lua;" .. path
end

-- make sure the old shims are not still around
local function uncached_require(module)
    package.loaded[module] = nil
    package.loaded['services.hal.mmcli'] = nil
    package.loaded['services.hal.qmicli'] = nil
    package.loaded['services.hal.at'] = nil
    return require(module)
end

return {
    update_shim_path = update_shim_path,
    uncached_require = uncached_require
}
