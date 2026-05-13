local tablex = require 'shared.table'

local tests = {}

local function assert_eq(a, b, msg) if a ~= b then error(msg or (tostring(a) .. ' ~= ' .. tostring(b)), 2) end end
local function assert_true(v, msg) if v ~= true then error(msg or 'expected true', 2) end end
local function assert_false(v, msg) if v ~= false then error(msg or 'expected false', 2) end end

function tests.test_deep_copy_and_equal()
	local src = { a = { b = 1 }, list = { 'x', 'y' } }
	local cp = tablex.deep_copy(src)
	assert_true(tablex.deep_equal(src, cp))
	cp.a.b = 2
	assert_false(tablex.deep_equal(src, cp))
	assert_eq(src.a.b, 1)
end

function tests.test_array_copy_and_is_array()
	local cp = tablex.array_copy({ 'a', 'b' })
	assert_eq(cp[1], 'a')
	assert_true(tablex.is_array(cp))
	assert_false(tablex.is_array({ a = 1 }))
end

function tests.test_first_non_nil()
	assert_eq(tablex.first_non_nil(nil, false, 'x'), false)
	assert_eq(tablex.first_non_nil(nil, nil, 'x'), 'x')
end

return tests
