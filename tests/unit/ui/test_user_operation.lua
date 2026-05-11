-- tests/unit/ui/test_user_operation.lua

local fibers = require 'fibers'
local sleep = require 'fibers.sleep'
local user_operation = require 'services.ui.user_operation'

local tests = {}

local function fail(msg) error(msg or 'assertion failed', 2) end
local function assert_eq(a, b, msg) if a ~= b then fail(msg or ('expected '..tostring(b)..', got '..tostring(a))) end end
local function assert_nil(v, msg) if v ~= nil then fail(msg or ('expected nil, got '..tostring(v))) end end
local function assert_not_nil(v, msg) if v == nil then fail(msg or 'expected non-nil') end end

function tests.test_user_operation_success_disconnects_owned_connection()
	fibers.run(function ()
		local disconnected = false
		local conn = { disconnect = function () disconnected = true; return true end }
		local result, err = user_operation.run {
			principal = 'alice',
			connect = function () return conn, nil end,
			run = function (_, c)
				assert_eq(c, conn)
				return { ok = true }
			end,
		}
		assert_not_nil(result, err)
		assert_eq(result.ok, true)
		assert_eq(disconnected, true)
	end)
end

function tests.test_user_operation_timeout_returns_cancelled_shape_and_disconnects()
	fibers.run(function ()
		local disconnected = false
		local conn = { disconnect = function () disconnected = true; return true end }
		local result, err, rep = user_operation.run {
			principal = 'alice',
			connect = function () return conn, nil end,
			timeout = 0.01,
			run = function ()
				fibers.perform(sleep.sleep_op(1))
				return { late = true }
			end,
		}
		assert_nil(result)
		assert_eq(err, 'timeout')
		assert_not_nil(rep)
		assert_eq(disconnected, true)
	end)
end

function tests.test_user_operation_borrowed_connection_is_not_disconnected_by_default()
	fibers.run(function ()
		local disconnected = false
		local conn = { disconnect = function () disconnected = true; return true end }
		local result, err = user_operation.run {
			conn = conn,
			run = function () return { ok = true } end,
		}
		assert_not_nil(result, err)
		assert_eq(disconnected, false)
	end)
end

return tests
