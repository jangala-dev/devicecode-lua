local unpack = table.unpack or unpack

local function build_mock_function(on_run)
    return function(...)
        if type(on_run) ~= "function" and type(on_run) ~= "table" then
            error("Invalid on_run type for mock function")
        end
        if type(on_run) == "function" then
            return on_run(...)
        end
        return unpack(on_run)
    end
end

local ModuleMock = {}
ModuleMock.__index = ModuleMock

function ModuleMock:apply()
    if not self.module_path then return end
    package.loaded[self.module_path] = self
end

function ModuleMock:clear()
    if not self.module_path then return end
    package.loaded[self.module_path] = nil
end

local ObjectMock = {}
ObjectMock.__index = ObjectMock

function ObjectMock:create_instance()
    local instance = setmetatable({ _calls = {} }, ObjectMock)
    for k, v in pairs(self.method_table) do
        if k ~= "_calls" then
            local fn = build_mock_function(v)
            instance[k] = function(...)
                instance._calls[k] = instance._calls[k] + 1
                return fn(...)
            end
            instance._calls[k] = 0
        end
    end
    return instance
end

local function new_module(module_path, method_table)
    local mock = setmetatable({ _calls = {}, module_path = module_path }, ModuleMock)
    for k, v in pairs(method_table) do
        local fn = build_mock_function(v)
        mock[k] = function(...)
            mock._calls[k] = mock._calls[k] + 1
            return fn(...)
        end
        mock._calls[k] = 0
    end
    return mock
end

local function new_object(method_table)
    local mock = setmetatable({ method_table = method_table }, ObjectMock)
    return mock
end

return {
    new_module = new_module,
    new_object = new_object
}
