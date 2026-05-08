-- tests/unit/support/test_request_owner.lua

local request_owner = require 'services.support.request_owner'

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

function tests.test_reply_payload_only_uses_payload_field()
	local req = new_request()
	local owner = request_owner.new(req, { reply_payload_only = true })

	assert_true(owner:reply_once({ payload = 'answer', frame = 'ignored' }))
	assert_eq(req.value, 'answer')
end


function tests.test_terminate_fails_unresolved_request_once()
	local req = new_request()
	local owner = request_owner.new(req)

	assert_true(owner:terminate('terminated'))
	assert_false(owner:terminate('late'))

	assert_eq(req.fails, 1)
	assert_eq(req.reason, 'terminated')
	assert_eq(req.replies, nil)
end

return tests
