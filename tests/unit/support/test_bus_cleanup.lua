-- tests/unit/support/test_bus_cleanup.lua

local cleanup = require 'devicecode.support.bus_cleanup'

local tests = {}

local function fail(msg)
	error(msg or 'assertion failed', 2)
end

local function assert_true(v, msg)
	if v ~= true then fail(msg or ('expected true, got ' .. tostring(v))) end
end

local function assert_nil(v, msg)
	if v ~= nil then fail(msg or ('expected nil, got ' .. tostring(v))) end
end

local function assert_eq(a, b, msg)
	if a ~= b then fail(msg or ('expected ' .. tostring(b) .. ', got ' .. tostring(a))) end
end

local function assert_match(s, pat, msg)
	if type(s) ~= 'string' or not s:match(pat) then
		fail(msg or ('expected ' .. tostring(s) .. ' to match ' .. tostring(pat)))
	end
end

function tests.test_publish_retain_and_unretain_call_immediate_bus_methods()
	local calls = {}
	local conn = {
		publish = function (_, topic, payload, opts)
			calls[#calls + 1] = { 'publish', topic, payload, opts }
			return true, nil
		end,
		retain = function (_, topic, payload, opts)
			calls[#calls + 1] = { 'retain', topic, payload, opts }
			return true, nil
		end,
		unretain = function (_, topic, opts)
			calls[#calls + 1] = { 'unretain', topic, opts }
			return true, nil
		end,
	}

	assert_true(cleanup.publish(conn, { 'a' }, 1, { extra = true }))
	assert_true(cleanup.retain(conn, { 'b' }, 2))
	assert_true(cleanup.unretain(conn, { 'c' }))

	assert_eq(calls[1][1], 'publish')
	assert_eq(calls[1][2][1], 'a')
	assert_eq(calls[2][1], 'retain')
	assert_eq(calls[3][1], 'unretain')
end

function tests.test_wrapper_catches_raised_bus_cleanup_error()
	local conn = {
		disconnect = function ()
			error('boom', 0)
		end,
	}

	local ok, err = cleanup.disconnect(conn)
	assert_nil(ok)
	assert_match(err, 'boom')
end

function tests.test_feed_cleanup_can_use_handle_when_connection_is_absent()
	local closed
	local feed = {
		unsubscribe = function ()
			closed = true
			return true, nil
		end,
	}

	assert_true(cleanup.unsubscribe(nil, feed))
	assert_true(closed)
end

function tests.test_reply_and_fail_report_duplicate_completion_as_failure()
	local req = {
		reply = function () return false, 'already_done' end,
		fail = function () return false, 'already_done' end,
	}

	local ok, err = cleanup.reply(req, { ok = true })
	assert_nil(ok)
	assert_match(err, 'already_done')

	ok, err = cleanup.fail(req, 'bad')
	assert_nil(ok)
	assert_match(err, 'already_done')
end

function tests.test_checked_raises_labelled_failure()
	local conn = {
		disconnect = function () return nil, 'not now' end,
	}

	local ok, err = pcall(function ()
		cleanup.checked('disconnect_label', conn, 'disconnect')
	end)

	assert_eq(ok, false)
	assert_match(err, 'disconnect_label')
	assert_match(err, 'not now')
end

return tests
