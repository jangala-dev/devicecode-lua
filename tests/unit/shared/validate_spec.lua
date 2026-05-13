local validate = require 'shared.validate'

local tests = {}
local function assert_eq(a, b, msg) if a ~= b then error(msg or (tostring(a) .. ' ~= ' .. tostring(b)), 2) end end
local function assert_raises(fn)
	local ok = pcall(fn)
	if ok then error('expected error', 2) end
end

function tests.test_scalar_validation()
	assert_eq(validate.non_empty_string('x', 'name'), 'x')
	assert_eq(validate.positive_integer(2, 'n'), 2)
	assert_raises(function () validate.positive_integer(0, 'n') end)
end

function tests.test_only_fields()
	validate.only_fields({ a = 1 }, { 'a' }, 'opts')
	assert_raises(function () validate.only_fields({ b = 1 }, { 'a' }, 'opts') end)
end

return tests
