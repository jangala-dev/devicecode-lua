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


function tests.test_network_state_watch_and_subscription_are_exposed()
	fibers.run(function ()
		local called = false
		local cap = {
			call_control_op = function (_, method, args, opts)
				called = true
				eq(method, 'watch')
				ok(type(args) == 'table')
				ok(type(opts) == 'table')
				return op.always({ ok = true, reason = { ok = true, watching = true } })
			end,
			get_event_sub = function (_, name, opts)
				eq(name, 'observed')
				return { name = name, opts = opts }
			end,
		}
		local client = hal_client.new({}, { network_state_cap = cap })
		local sub = client:open_observed_subscription({ queue_len = 7 })
		eq(sub.name, 'observed')
		eq(sub.opts.queue_len, 7)
		local result = fibers.perform(client:start_observation_op({ debounce_s = 0.01 }))
		eq(result.ok, true)
		eq(result.watching, true)
		ok(called, 'watch should have been called')
	end)
end


function tests.test_live_weight_shaping_and_speedtest_capabilities_are_exposed()
	fibers.run(function ()
		local config_calls = {}
		local diag_calls = {}
		local config_cap = {
			call_control_op = function (_, method, args, opts)
				config_calls[#config_calls + 1] = { method = method, args = args, opts = opts }
				return op.always({ ok = true, reason = { ok = true, method = method } })
			end,
		}
		local diag_cap = {
			call_control_op = function (_, method, args, opts)
				diag_calls[#diag_calls + 1] = { method = method, args = args, opts = opts }
				return op.always({ ok = true, reason = { ok = true, peak_mbps = 12.5 } })
			end,
		}
		local client = hal_client.new({}, { network_config_cap = config_cap, network_diagnostics_cap = diag_cap })
		local r1 = fibers.perform(client:apply_live_weights_op({ members = {} }, { timeout = 1 }))
		eq(r1.ok, true)
		eq(config_calls[1].method, 'apply_live_weights')
		local r2 = fibers.perform(client:apply_shaping_op({ links = {} }, { timeout = 1 }))
		eq(r2.ok, true)
		eq(config_calls[2].method, 'apply_shaping')
		local r3 = fibers.perform(client:speedtest_op({ interface = 'wan_a' }, { timeout = 1 }))
		eq(r3.ok, true)
		eq(r3.peak_mbps, 12.5)
		eq(diag_calls[1].method, 'speedtest')
		local r4 = fibers.perform(client:read_counters_op({ interfaces = { 'wan_a' } }, { timeout = 1 }))
		eq(r4.ok, true)
		eq(diag_calls[2].method, 'read_counters')
		eq(diag_calls[2].args.interfaces[1], 'wan_a')
	end)
end

return tests
