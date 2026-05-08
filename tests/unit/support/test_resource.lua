-- tests/unit/support/test_resource.lua
--
-- Unit tests for services.support.resource.

local resource = require 'services.support.resource'

local tests = {}

local function fail(msg)
	error(msg or 'assertion failed', 2)
end

local function assert_true(v, msg)
	if v ~= true then
		fail(msg or ('expected true, got ' .. tostring(v)))
	end
end

local function assert_nil(v, msg)
	if v ~= nil then
		fail(msg or ('expected nil, got ' .. tostring(v)))
	end
end

local function assert_false(v, msg)
	if v ~= false then
		fail(msg or ('expected false, got ' .. tostring(v)))
	end
end

local function assert_eq(a, b, msg)
	if a ~= b then
		fail(msg or ('expected ' .. tostring(b) .. ', got ' .. tostring(a)))
	end
end

local function assert_match(s, pat, msg)
	if type(s) ~= 'string' or not s:match(pat) then
		fail(msg or ('expected "' .. tostring(s) .. '" to match ' .. tostring(pat)))
	end
end

function tests.test_terminate_nil_succeeds()
	local ok, err = resource.terminate(nil, 'shutdown')

	assert_true(ok)
	assert_nil(err)
end

function tests.test_terminate_rejects_function_resource()
	local ok, err = resource.terminate(function ()
		error('function cleanup must not be called')
	end, 'shutdown')

	assert_nil(ok)
	assert_match(err, 'no terminate')
end

function tests.test_terminate_passes_self_and_reason_to_table_method()
	local obj = {}

	function obj:terminate(reason)
		self.seen_self = self
		self.seen_reason = reason
		return true
	end

	local ok, err = resource.terminate(obj, 'closing')

	assert_true(ok)
	assert_nil(err)
	assert_eq(obj.seen_self, obj)
	assert_eq(obj.seen_reason, 'closing')
end

function tests.test_terminate_rejects_close_only_resource()
	local obj = {
		close = function ()
			error('close must not be called')
		end,
	}

	local ok, err = resource.terminate(obj, 'closing')

	assert_nil(ok)
	assert_match(err, 'no terminate')
end

function tests.test_terminate_rejects_close_op_only_resource()
	local obj = {
		close_op = function ()
			error('close_op must not be called')
		end,
	}

	local ok, err = resource.terminate(obj, 'closing')

	assert_nil(ok)
	assert_match(err, 'no terminate')
end

function tests.test_terminate_reports_false_return_failure()
	local obj = {
		terminate = function ()
			return false, 'terminate rejected'
		end,
	}

	local ok, err = resource.terminate(obj, 'closing')

	assert_nil(ok)
	assert_eq(err, 'terminate rejected')
end

function tests.test_terminate_reports_nil_error_failure()
	local obj = {
		terminate = function ()
			return nil, 'terminate unavailable'
		end,
	}

	local ok, err = resource.terminate(obj, 'closing')

	assert_nil(ok)
	assert_eq(err, 'terminate unavailable')
end

function tests.test_terminate_reports_failure_fallback_when_error_missing()
	local obj = {
		terminate = function ()
			return false
		end,
	}

	local ok, err = resource.terminate(obj, 'closing')

	assert_nil(ok)
	assert_match(err, 'termination failed')
end

function tests.test_terminate_catches_raised_cleanup_error()
	local obj = {
		terminate = function ()
			error('boom', 0)
		end,
	}

	local ok, err = resource.terminate(obj, 'closing')

	assert_nil(ok)
	assert_match(err, 'boom')
end

function tests.test_terminate_accepts_truthy_non_boolean_success()
	local obj = {
		terminate = function ()
			return 'terminated'
		end,
	}

	local ok, err = resource.terminate(obj, 'closing')

	assert_true(ok)
	assert_nil(err)
end

function tests.test_terminate_checked_succeeds_when_cleanup_succeeds()
	local obj = {
		terminate = function () return true end,
	}

	local ok, ret = pcall(function ()
		return resource.terminate_checked(obj, 'closing', 'source cleanup')
	end)

	assert_true(ok)
	assert_true(ret)
end

function tests.test_terminate_checked_raises_labelled_failure()
	local obj = {
		terminate = function ()
			return nil, 'device refused terminate'
		end,
	}

	local ok, err = pcall(function ()
		resource.terminate_checked(obj, 'closing', 'source cleanup')
	end)

	assert_false(ok)
	assert_match(err, 'source cleanup')
	assert_match(err, 'device refused terminate')
end

function tests.test_owned_resource_terminates_when_not_handed_off()
	local terminated = 0
	local seen_reason
	local obj = {
		terminate = function (_, reason)
			terminated = terminated + 1
			seen_reason = reason
			return true
		end,
	}

	local lease = resource.owned(obj)
	assert_true(lease:is_owned())
	assert_eq(lease:value(), obj)

	local ok, err = lease:terminate('scope closed')
	assert_true(ok)
	assert_nil(err)
	assert_eq(terminated, 1)
	assert_eq(seen_reason, 'scope closed')
	assert_true(lease:terminate('again'))
	assert_eq(terminated, 1, 'owned lease terminate must be idempotent')
end

function tests.test_owned_resource_terminate_checked_raises_labelled_failure()
	local lease = resource.owned({
		terminate = function () return nil, 'nope' end,
	})

	local ok, err = pcall(function ()
		lease:terminate_checked('closed', 'lease cleanup')
	end)

	assert_false(ok)
	assert_match(err, 'lease cleanup')
	assert_match(err, 'nope')
end

function tests.test_handoff_installs_receiver_before_releasing_owner_cleanup()
	local owner_terminated = 0
	local receiver_installed = false
	local obj = {
		terminate = function ()
			owner_terminated = owner_terminated + 1
			return true
		end,
	}

	local lease = resource.owned(obj)
	local handed, err = lease:handoff(function (v)
		assert_eq(v, obj)
		receiver_installed = true
		return true
	end)

	assert_eq(handed, obj)
	assert_nil(err)
	assert_true(receiver_installed)
	assert_false(lease:is_owned())
	assert_true(lease:terminate('child finalised'))
	assert_eq(owner_terminated, 0, 'handoff must disable child cleanup')
end

function tests.test_handoff_receiver_failure_keeps_child_cleanup_ownership()
	local terminated = 0
	local obj = {
		terminate = function ()
			terminated = terminated + 1
			return true
		end,
	}

	local lease = resource.owned(obj)
	local handed, err = lease:handoff(function ()
		return nil, 'receiver refused'
	end)

	assert_nil(handed)
	assert_match(err, 'receiver refused')
	assert_true(lease:is_owned(), 'failed handoff must keep original cleanup owner')
	assert_true(lease:terminate('cleanup'))
	assert_eq(terminated, 1)
end

function tests.test_detach_releases_cleanup_ownership()
	local terminated = 0
	local obj = {
		terminate = function ()
			terminated = terminated + 1
			return true
		end,
	}

	local lease = resource.owned(obj)
	local detached, err = lease:detach()

	assert_eq(detached, obj)
	assert_nil(err)
	assert_false(lease:is_owned())
	assert_true(lease:terminate('later'))
	assert_eq(terminated, 0)
end

return tests
