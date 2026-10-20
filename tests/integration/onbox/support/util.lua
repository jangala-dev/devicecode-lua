local json = require 'cjson.safe'

local M = {}

---@param path string
---@return string
function M.read(path)
    local file = assert(io.open(path, 'rb'))
    local content = assert(file:read('*a'))
    assert(file:close())
    return content
end

---@param path string
---@param content string
---@return nil
function M.write(path, content)
    local file = assert(io.open(path, 'wb'))
    assert(file:write(content))
    assert(file:close())
end

---@param value string
---@return string
function M.trim(value)
    return (value:gsub('^%s+', ''):gsub('%s+$', ''))
end

---@param value string
---@return table
function M.decode(value)
    local data, err = json.decode(value)
    assert(type(data) == 'table', err or 'Expected JSON object')
    return data
end

---@param value table
---@return string
function M.encode(value)
    return assert(json.encode(value)) .. '\n'
end

---@param value table<string, any>
---@return string[]
function M.keys(value)
    local result = {}
    for key in pairs(value) do result[#result + 1] = key end
    table.sort(result)
    return result
end

return M
