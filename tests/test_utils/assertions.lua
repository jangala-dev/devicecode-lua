local json = require 'dkjson'

local function to_str(value)
    if type(value) == 'nil' then return "nil" end
    return value
end
-- Traverses a table, excludes function attributes
local function assert_table(expected, recieved, root_key)
    assert(type(expected) == 'table')
    assert(type(recieved) == 'table', string.format(
        '%s: expected a table but recieved %s',
        root_key,
        type(recieved)
    ))

    for k, v in pairs(expected) do
        local key = string.format("%s.%s", root_key, k)
        if type(v) == 'table' then
            assert_table(v, recieved[k], key)
        else
            if type(v) ~= 'function' then
                assert(v == recieved[k], string.format("%s: expected %s but got %s", key, v, to_str(recieved[k])))
            end
        end
    end
end

local function expect_assert(expected, result, name)
    assert(expected == result, string.format('%s expected %s but got %s', name, to_str(expected), to_str(result)))
end
return {
    assert_table = assert_table,
    to_str = to_str,
    expect_assert = expect_assert
}
