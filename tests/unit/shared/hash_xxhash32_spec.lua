-- tests/unit/shared/hash_xxhash32_spec.lua

local xxhash32 = require 'shared.hash.xxhash32'

local tests = {}

local function fail(msg)
	error(msg or 'assertion failed', 2)
end

local function assert_eq(a, b, msg)
	if a ~= b then
		fail(msg or ('expected ' .. tostring(b) .. ', got ' .. tostring(a)))
	end
end

function tests.test_known_vectors_seed_zero()
	assert_eq(xxhash32.digest_hex(''), '02cc5d05')
	assert_eq(xxhash32.digest_hex('a'), '550d7456')
	assert_eq(xxhash32.digest_hex('abc'), '32d153ff')
	assert_eq(xxhash32.digest_hex('hello'), 'fb0077f9')
	assert_eq(xxhash32.digest_hex('Hello, world!'), '31b7405d')
	assert_eq(xxhash32.digest_hex('abcdefghijklmnopqrstuvwxyz'), '63a14d5f')
	assert_eq(xxhash32.digest_hex('0123456789abcdef'), 'c2c45b69')
	assert_eq(xxhash32.digest_hex('0123456789abcdefg'), 'cc79b217')
	assert_eq(xxhash32.digest_hex('The quick brown fox jumps over the lazy dog'), 'e85ea4de')
end

function tests.test_known_vectors_non_zero_seed()
	local st = xxhash32.new(1)
	xxhash32.update(st, '')
	assert_eq(xxhash32.digest_hex_state(st), '0b2cb792')

	st = xxhash32.new(1)
	xxhash32.update(st, 'The quick brown fox jumps over the lazy dog')
	assert_eq(xxhash32.digest_hex_state(st), '234f8471')
end

function tests.test_incremental_update_matches_one_shot_vector()
	local st = xxhash32.new(0)
	xxhash32.update(st, 'abc')
	xxhash32.update(st, 'def')
	assert_eq(xxhash32.digest_hex_state(st), '8b7cd587')
	assert_eq(xxhash32.digest_hex('abcdef'), '8b7cd587')
end

function tests.test_binary_input_known_vector()
	assert_eq(xxhash32.digest_hex('abc\0def'), '7955e6e5')
end

return tests
