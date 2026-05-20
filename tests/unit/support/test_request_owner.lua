-- tests/unit/support/test_request_owner.lua

local request_owner = require 'devicecode.support.request_owner'
local fibers = require 'fibers'
local op = require 'fibers.op'

local tests = {}

local function fail(msg)
	error(msg or 'assertion failed', 2)
end

local function assert_true(v, msg)
	if v ~= true then fail(msg or ('expected true, got ' .. tostring(v))) end
end

local function assert_false(v, msg)
	if v ~= false then fail(msg or ('expected false, got ' .. tostring(v))) end
end

local function assert_eq(a, b, msg)
	if a ~= b then fail(msg or ('expected ' .. tostring(b) .. ', got ' .. tostring(a))) end
end

local Request = {}
Request.__index = Request

function Request:reply(value)
	self.replies = (self.replies or 0) + 1
	self.value = value
	return true
end

function Request:fail(reason)
	self.fails = (self.fails or 0) + 1
	self.reason = reason
	return true
end

local function new_request()
	return setmetatable({}, Request)
end

function tests.test_reply_once_prevents_later_finalise()
	local req = new_request()
	local owner = request_owner.new(req)

	assert_true(owner:reply_once('ok'))
	assert_false(owner:finalise_unresolved('closed'))

	assert_eq(req.replies, 1)
	assert_eq(req.value, 'ok')
	assert_eq(req.fails, nil)
end

function tests.test_fail_once_prevents_later_reply()
	local req = new_request()
	local owner = request_owner.new(req)

	assert_true(owner:fail_once('bad'))
	assert_false(owner:reply_once('late'))

	assert_eq(req.fails, 1)
	assert_eq(req.reason, 'bad')
	assert_eq(req.replies, nil)
end

function tests.test_finalise_unresolved_fails_unresolved_request_once()
	local req = new_request()
	local owner = request_owner.new(req)

	assert_true(owner:finalise_unresolved('terminated'))
	assert_false(owner:finalise_unresolved('late'))

	assert_eq(req.fails, 1)
	assert_eq(req.reason, 'terminated')
	assert_eq(req.replies, nil)
end

function tests.test_abandon_unresolved_resolves_without_reply_or_fail()
	local req = new_request()
	local owner = request_owner.new(req)

	assert_true(owner:abandon_unresolved('client_closed'))
	assert_false(owner:reply_once('late'))
	assert_false(owner:fail_once('late'))

	assert_eq(req.fails, nil)
	assert_eq(req.replies, nil)
end


function tests.test_caller_cancel_op_abandons_on_bus_request_abandoned()
	fibers.run(function ()
		local req = new_request()
		function req:done_op()
			return op.always('abandoned', nil, 'timeout')
		end

		local owner = request_owner.new(req)
		local reason = fibers.perform(owner:caller_cancel_op())

		assert_eq(reason, 'timeout')
		assert_true(owner:done())
		assert_false(owner:reply_once('late'))
		assert_eq(req.replies, nil)
		assert_eq(req.fails, nil)
	end)
end

function tests.test_caller_cancel_op_ignores_non_abandoned_done_status()
	fibers.run(function ()
		local req = new_request()
		function req:done_op()
			return op.always('replied', 'ok', nil)
		end

		local owner = request_owner.new(req)
		local reason = fibers.perform(owner:caller_cancel_op())

		assert_false(reason)
		assert_false(owner:done())
		assert_true(owner:reply_once('late'))
		assert_eq(req.replies, 1)
	end)
end

function tests.test_caller_cancel_op_requires_request_done_op()
	local owner = request_owner.new(new_request())
	local cancel_op, err = owner:caller_cancel_op()
	assert_eq(cancel_op, nil)
	assert_eq(err, 'request has no done_op')
end

return tests
