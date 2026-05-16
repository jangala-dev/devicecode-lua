-- tests/unit/net/test_hal_client.lua

local fibers = require 'fibers'
local op = require 'fibers.op'

local hal_client = require 'services.net.hal_client'

local tests = {}

local function fail(msg) error(msg or 'assertion failed', 2) end
local function ok(v, msg) if not v then fail(msg) end return v end
local function eq(a, b, msg) if a ~= b then fail((msg or 'assertion failed') .. ': expected ' .. tostring(b) .. ', got ' .. tostring(a)) end end
local function contains(s, needle, msg) if type(s) ~= 'string' or not s:find(needle, 1, true) then fail(msg or ('expected ' .. tostring(s) .. ' to contain ' .. tostring(needle))) end end

function tests.test_missing_hal_fails_by_default()
	fibers.run(function ()
		local client = hal_client.new(nil, {})
		local result = fibers.perform(client:apply_intent_op({ rev = 1 }, {}))
		eq(result.ok, false)
		contains(result.err, 'network-config HAL capability not configured')
		ok(result.reason and result.reason.code == 'missing_network_config_hal', 'structured missing-hal reason expected')
	end)
end

function tests.test_missing_hal_succeeds_only_when_explicit_dry_run()
	fibers.run(function ()
		local client = hal_client.new(nil, { dry_run = true })
		local result = fibers.perform(client:apply_intent_op({ rev = 1 }, {}))
		eq(result.ok, true)
		eq(result.dry_run, true)
		eq(result.applied, false)
	end)
end

function tests.test_structured_failure_reason_is_preserved()
	fibers.run(function ()
		local cap = {
			call_control_op = function ()
				return op.always({
					ok = false,
					code = 409,
					reason = {
						code = 'backend_failed',
						err = 'backend said no',
						detail = { field = 'segments.lan' },
					},
				})
			end,
		}
		local client = hal_client.new(nil, { network_config_cap = cap })
		local result = fibers.perform(client:apply_intent_op({ rev = 1 }, {}))
		eq(result.ok, false)
		eq(result.err, 'backend said no')
		eq(result.code, 409)
		eq(result.reason.code, 'backend_failed')
		eq(result.reason.detail.field, 'segments.lan')
	end)
end

return tests
