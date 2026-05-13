local topic = require 'shared.topic'

local tests = {}
local function assert_eq(a, b, msg) if a ~= b then error(msg or (tostring(a) .. ' ~= ' .. tostring(b)), 2) end end
local function assert_true(v, msg) if v ~= true then error(msg or 'expected true', 2) end end
local function assert_false(v, msg) if v ~= false then error(msg or 'expected false', 2) end end

function tests.test_append_flattens_topic_segments()
	local out = topic.append({ 'a' }, 'b', { 'c', 'd' })
	assert_eq(table.concat(out, '/'), 'a/b/c/d')
end

function tests.test_prefix_and_replace()
	assert_true(topic.starts_with({ 'a', 'b', 'c' }, { 'a', 'b' }))
	assert_false(topic.starts_with({ 'a' }, { 'a', 'b' }))
	local out = assert(topic.replace_prefix({ 'a', 'b', 'c' }, { 'a' }, { 'x' }))
	assert_eq(table.concat(out, '/'), 'x/b/c')
end

function tests.test_validate_dense()
	assert_true((topic.validate_dense({ 'a', 1 })))
	local ok = topic.validate_dense({ '', 'b' })
	assert_eq(ok, nil)
end

return tests
