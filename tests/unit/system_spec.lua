-- tests/unit/system_spec.lua

local fibers = require 'fibers'
local op = require 'fibers.op'

local sleep = require 'fibers.sleep'
local runtime = require 'fibers.runtime'
local virtual_time = require 'tests.support.virtual_time'

local system = require 'services.system'

local T = {}

local function assert_true(v, msg)
	if not v then error(msg or 'assertion failed', 2) end
end

local function assert_eq(a, b, msg)
	if a ~= b then
		error((msg or 'assertion failed') .. ': expected ' .. tostring(b) .. ', got ' .. tostring(a), 2)
	end
end

function T.publish_platform_identity_publishes_state_and_legacy_metrics()
	fibers.run(function()
		local metrics = {}
		local retained = {}
		local svc = {
			wall = function() return '2026-07-06 12:00:00' end,
			_retain = function(_, topic, payload)
				retained[table.concat(topic, '/')] = payload
			end,
			obs_metric = function(_, key, payload)
				metrics[key] = payload
			end,
			obs_log = function() end,
		}
		local cap = {
			call_control_op = function(_, method, opts)
				assert_eq(method, 'get')
				assert_eq(opts.field, 'identity')
				return op.always({
					ok = true,
					reason = {
						hw_revision = 'bigbox-v1-cm-2',
						fw_version = 'bigbox-v1-cm-2-v0.11.0',
						serial = 'BB7YJWANBEA6GE',
						board_revision = '0xC04180',
					},
				})
			end,
		}

		assert_true(system._test.publish_platform_identity_metrics(svc, cap, 0.1))
		assert_eq(metrics.hw_id.value, 'bigbox-v1-cm-2')
		assert_eq(metrics.fw_id.value, 'bigbox-v1-cm-2-v0.11.0')
		assert_eq(metrics.serial.value, 'BB7YJWANBEA6GE')
		assert_eq(metrics.board_revision.value, '0xC04180')
		assert_eq(metrics.hw_id.namespace[1], 'system')
		assert_eq(metrics.hw_id.namespace[2], 'hw_id')
		assert_eq(retained['state/system/identity'].schema, 'devicecode.system.identity/1')
		assert_eq(retained['state/system/identity'].hw_revision, 'bigbox-v1-cm-2')
	end)
end

function T.usb3_control_is_gated_to_bigbox_ss_and_follows_config()
	assert_eq(system._test.usb_verb_for_config('bigbox-ss', { usb3_enabled = false }), 'disable')
	assert_eq(system._test.usb_verb_for_config('bigbox-ss', { usb3_enabled = true }), 'enable')
	assert_eq(system._test.usb_verb_for_config('bigbox-v1-cm-2', { usb3_enabled = false }), nil)
end

-- The Pi firmware power flags go out under their v0.10.6 names (system.power_*).
-- A platform without them (value nil) sends nothing.
function T.publish_sysinfo_metrics_sends_pi_power_flags_under_v0_10_names()
	fibers.run(function()
		local function run(flags)
			local metrics = {}
			local svc = {
				obs_metric = function(_, key, payload) metrics[key] = payload end,
				obs_log = function() end,
			}
			local platform = {
				call_control_op = function(_, method, opts)
					assert_eq(method, 'get')
					return op.always({ ok = true, reason = flags[opts.field] })
				end,
			}
			system._test.publish_sysinfo_metrics(svc, { ['platform:1'] = platform }, 60)
			return metrics
		end

		local metrics = run({
			under_voltage_detected = true,
			arm_frequency_capped = false,
			currently_throttled = true,
			under_voltage_occurred = true,
		})
		assert_eq(metrics.power_undervoltage.value, true)
		assert_eq(metrics.power_arm_frequency_capped.value, false)
		assert_eq(metrics.power_currently_throttled.value, true)
		assert_eq(metrics.power_under_voltage_occurred.value, true)
		assert_eq(table.concat(metrics.power_undervoltage.namespace, '.'), 'system.power_undervoltage')

		metrics = run({})
		assert_eq(metrics.power_undervoltage, nil, 'no value, no metric')
	end)
end

-- The stats payload carries the power flags the sysinfo pass already reads, so the UI
-- doesn't need a second reading of the same firmware state.
function T.collect_sysinfo_state_includes_pi_power_flags()
	fibers.run(function()
		local svc = { wall = function() return '2026-07-06 12:00:00' end }
		local function run(flags)
			local fields = {}
			local cap = {
				call_control_op = function(_, method, opts)
					assert_eq(method, 'get')
					fields[#fields + 1] = opts.field
					return op.always({ ok = true, reason = flags[opts.field] })
				end,
			}
			return system._test.collect_sysinfo_state(svc, { ['platform:1'] = cap }, 0.1), fields
		end

		local out, fields = run({
			currently_throttled = true, under_voltage_detected = true,
			arm_frequency_capped = false, under_voltage_occurred = true,
		})
		assert_eq(out.power.currently_throttled, true)
		assert_eq(out.power.under_voltage_detected, true)
		assert_eq(out.power.arm_frequency_capped, false)
		assert_eq(out.power.under_voltage_occurred, true)
		assert_eq(#fields, 4, 'one read per flag, and no other')

		out = run({})
		assert_eq(out.power, nil, 'no flags on this platform, no power block')
	end)
end

-- The UI reads a missing flag as false, so a partial block could show a throttled box
-- as fine. Only a complete set of flags is published.
function T.collect_sysinfo_state_leaves_out_a_partial_power_block()
	fibers.run(function()
		local svc = { wall = function() return '2026-07-06 12:00:00' end }
		local function run(replies)
			local cap = {
				call_control_op = function(_, _, opts)
					return op.always(replies[opts.field] or { ok = true, reason = nil })
				end,
			}
			return system._test.collect_sysinfo_state(svc, { ['platform:1'] = cap }, 0.1)
		end
		local good = { ok = true, reason = true }
		local bad = { ok = false, reason = 'read failed' }

		local out = run({ under_voltage_occurred = good })
		assert_eq(out.power, nil, 'one flag read, others unknown')

		out = run({
			currently_throttled = bad, under_voltage_detected = bad,
			arm_frequency_capped = bad, under_voltage_occurred = good,
		})
		assert_eq(out.power, nil, 'reads failed, then one succeeded')

		out = run({
			currently_throttled = good, under_voltage_detected = good,
			arm_frequency_capped = good, under_voltage_occurred = { ok = true, reason = false },
		})
		assert_eq(out.power.currently_throttled, true)
		assert_eq(out.power.under_voltage_occurred, false, 'false is a real value')
	end)
end

-- fibers.alarm takes one time source per load, so each test gets a fresh copy.
local function with_wall_clock(body)
	local saved_falarm, saved_alarms = package.loaded['fibers.alarm'], package.loaded['services.system.alarms']
	package.loaded['fibers.alarm'], package.loaded['services.system.alarms'] = nil, nil
	local falarm = require 'fibers.alarm'
	local alarms = require 'services.system.alarms'

	local start = os.time()
	start = start - start % 3600 + 3599 -- one second before the next hour
	local real_time = os.time
	fibers.run(function()
		local mono0 = fibers.now()
		local function wall() return start + (fibers.now() - mono0) end
		os.time = function(tbl)
			if tbl then return real_time(tbl) end
			return math.floor(wall())
		end
		falarm.set_time_source(wall)
		local ok, err = pcall(body, alarms, os.date('*t', start + 1))
		os.time = real_time
		package.loaded['fibers.alarm'], package.loaded['services.system.alarms'] = saved_falarm, saved_alarms
		if not ok then error(err, 0) end
	end)
end

local function alarm_at(trigger)
	return { time = string.format('%d:%02d', trigger.hour, trigger.min), repeats = 'daily', payload = { name = 'test' } }
end

local function fired_within(mgr, seconds)
	local which = fibers.perform(op.named_choice({ alarm = mgr:next_alarm_op(), timeout = sleep.sleep_op(seconds) }))
	return which == 'alarm'
end

-- A clock that has synced once keeps running when NTP is lost. The daily reboot is how
-- a box recovers from being offline, so it must not depend on still being in touch.
function T.alarm_still_fires_after_losing_sync()
	with_wall_clock(function(alarms, trigger)
		local mgr = alarms.AlarmManager.new()
		assert_eq(mgr:add(alarm_at(trigger)), '')
		mgr:sync()
		mgr:desync()
		assert_true(fired_within(mgr, 1.5), 'expected the alarm to fire despite losing sync')
	end)
end

function T.alarm_waits_for_the_first_sync()
	with_wall_clock(function(alarms, trigger)
		local mgr = alarms.AlarmManager.new()
		assert_eq(mgr:add(alarm_at(trigger)), '')
		assert_true(not fired_within(mgr, 1.5), 'a clock that never synced could be anything')
	end)
end

function T.regaining_sync_recalculates_from_the_new_clock()
	with_wall_clock(function(alarms, trigger)
		local mgr = alarms.AlarmManager.new()
		assert_eq(mgr:add(alarm_at(trigger)), '')
		mgr:sync()
		local head = mgr.alarms[1].wait_alarm
		mgr:desync()
		assert_true(mgr.alarms[1].wait_alarm == head, 'losing sync should leave the alarm armed')
		mgr:sync()
		assert_true(mgr.alarms[1].wait_alarm ~= head, 'regaining sync should rebuild the alarm')
	end)
end

function T.uptime_backstop_needs_a_configured_reboot()
	local has = system._test.has_reboot_alarm
	assert_eq(has({ { payload = { type = 'reboot' } } }), true)
	assert_eq(has({ { payload = { name = 'no type means reboot' } } }), true, 'handle_alarm defaults to reboot')
	assert_eq(has({ {} }), true, 'no payload also means reboot')
	assert_eq(has({ { payload = { type = 'shutdown' } } }), false)
	assert_eq(has({}), false)
end

function T.uptime_backstop_fires_at_48_hours_only_when_it_should()
	local backstop = system._test.uptime_backstop_op
	assert_true(backstop(false, {}) == nil, 'no reboot alarm, no backstop')
	assert_true(backstop(true, { power_pending = true }) == nil, 'already rebooting, no backstop')

	fibers.run(function()
		local clock = virtual_time.install({ monotonic = 47 * 3600, realtime = 1700000000 })
		fibers.current_scope():finally(function() clock:restore() end)

		local function fires()
			local which = fibers.perform(op.named_choice({
				backstop = backstop(true, {}),
				now = op.always(true),
			}))
			return which == 'backstop'
		end
		runtime.yield()
		assert_true(not fires(), 'should not fire before 48 hours')

		clock:set_monotonic(48 * 3600 + 1)
		runtime.yield()
		-- A timeout can't be used here, because this clock doesn't move by itself.
		local ready = backstop(true, {})
		local fired = false
		for _ = 1, 50 do
			local which = fibers.perform(op.named_choice({ backstop = ready, now = op.always(true) }))
			if which == 'backstop' then fired = true; break end
			runtime.yield()
		end
		assert_true(fired, 'should fire past 48 hours')
	end)
end

-- Runs handle_alarm with a stand-in capability, and records what happened.
local function run_handle_alarm(get_power_cap, attempts_wanted)
	local logs, retained = {}, {}
	local svc = {
		conn = { retain = function(_, topic, payload) retained[#retained + 1] = { topic = topic, payload = payload } end },
		now = function() return 0 end,
		obs_log = function(_, _, payload) logs[#logs + 1] = payload end,
		obs_event = function() end,
	}
	local result = { logs = logs, retained = retained }
	fibers.run(function(scope)
		local child = assert(scope:child())
		assert(child:spawn(function()
			system._test.handle_alarm(svc, get_power_cap, { payload = { name = 'daily reboot', type = 'reboot' } }, {
				grace_s = 0.01, retry_s = 0.01, recheck_s = 0.04,
			})
		end))
		sleep.sleep(attempts_wanted * 0.05)
		child:cancel('test done') -- the retries run for as long as the process does
		fibers.perform(child:join_op())
	end)
	return result
end

function T.reboot_looks_up_the_power_capability_when_it_fires()
	local lookups, calls = 0, 0
	local cap = {
		call_control_op = function()
			calls = calls + 1
			return op.always({ ok = true })
		end,
	}
	run_handle_alarm(function()
		lookups = lookups + 1
		if lookups < 3 then return nil end
		return cap
	end, 4)
	assert_true(calls >= 1, 'expected a reboot command once the capability appeared')
	assert_true(lookups >= 3, 'expected the capability to be looked up until it appeared')
end

-- The power driver acknowledges before it runs the OS command, so an accepted command
-- proves nothing. If the box is still here afterwards, it needs to try again.
function T.an_accepted_reboot_that_has_no_effect_is_tried_again()
	local calls = 0
	local cap = {
		call_control_op = function()
			calls = calls + 1
			return op.always({ ok = true })
		end,
	}
	local result = run_handle_alarm(function() return cap end, 4)
	assert_true(calls >= 2, 'expected another attempt while the box is still running, got ' .. calls)
	local no_effect = false
	for _, log in ipairs(result.logs) do
		if log.what == 'power_command_no_effect' then no_effect = true end
	end
	assert_true(no_effect, 'expected the lack of effect to be logged')
end

function T.a_failed_reboot_is_tried_again()
	local calls = 0
	local cap = {
		call_control_op = function()
			calls = calls + 1
			if calls < 3 then return op.always({ ok = false, reason = 'busy' }) end
			return op.always({ ok = true })
		end,
	}
	local result = run_handle_alarm(function() return cap end, 4)
	assert_true(calls >= 3, 'expected the command to be retried until it worked, got ' .. calls)
	local failures = 0
	for _, log in ipairs(result.logs) do
		if log.what == 'power_command_failed' then failures = failures + 1 end
	end
	assert_eq(failures, 2, 'expected each failure to be logged')
end

return T
