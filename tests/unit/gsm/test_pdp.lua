local op = require 'fibers.op'
local fibers = require 'fibers'
local channel = require 'fibers.channel'
local pulse = require 'fibers.pulse'
local sleep = require 'fibers.sleep'
local safe = require 'coxpcall'
local runfibers = require 'tests.support.run_fibers'
local gsm = require 'services.gsm'
local apns = require 'services.gsm.apn'
local at = require 'services.hal.backends.modem.at'
local quectel = require 'services.hal.backends.modem.models.quectel'

local tests = {}
local prepare_autoconnect
local function eq(a, b) assert(a == b, 'expected ' .. tostring(b) .. ', got ' .. tostring(a)) end
local function reply(ok, reason) return op.always({ ok = ok, reason = reason or '' }) end
local function correction(outcome, dispatched, err)
	return reply(true, { outcome = outcome, dispatched = dispatched, err = err or '' })
end
local function context(cid, pdp_type, active) return { cid = cid, pdp_type = pdp_type, active = active } end
local function fixture(contexts, overrides)
	overrides = overrides or {}
	local calls, logs, subs = {}, {}, {}
	local values = { mcc = '234', mnc = '30', imsi = '234300000000000', gid1 = '',
		pdp_contexts = contexts or {}, modem_state = 'disabled' }
	local cap = {
		call_control_op = function(_, method, opts)
			calls[#calls + 1] = { method = method, opts = opts }
			if overrides.call then
				local response = overrides.call(method, opts, subs, values)
				if response then return response end
			end
			if method == 'get' then return reply(true, values[opts.field]) end
			if method == 'set_pdn_type' then return correction('applied', true) end
			if method == 'restart' then
				for _, sub in ipairs(subs) do
					if sub.field == 'card' and not sub.closed then
						sub.queue:put({ payload = { from = 'initializing', to = 'disabled' } })
					end
				end
				return reply(true)
			end
			if method == 'connect' then return reply(false, 'connection failed') end
			return reply(true)
		end,
		get_state_sub = function(_, field, opts)
			local queue = channel.new(opts and opts.queue_len or 16)
			if opts and opts.full == 'drop_oldest' then
				local put = queue.put
				queue.put = function(q, message)
					if not q:put_op(message).try_fn() then
						q:get_op().try_fn()
						put(q, message)
					end
				end
			end
			if field == 'card' then
				queue:put({ payload = { from = 'disabled', to = 'disabled' } })
			end
			local sub = {
				queue = queue, field = field,
				recv = function() return queue:get() end,
				recv_op = function() return queue:get_op() end,
				unsubscribe = function(self) self.closed = true end,
			}
			subs[#subs + 1] = sub
			return sub
		end,
	}
	local svc = overrides.svc or { obs_log = function(_, _, payload) logs[#logs + 1] = payload end }
	local m = setmetatable({
		id = overrides.id or 'modem-1', name = 'primary', cap = cap, cfg = {}, config_pulse = pulse.new(),
		svc = svc, inspection_enable_proceeded = false,
	}, gsm._test.GsmModem)
	return m, calls, logs, values, subs
end
local function count(calls, method)
	local n = 0
	for _, call in ipairs(calls) do if call.method == method then n = n + 1 end end
	return n
end

local function config(default, known)
	return { schema = 'devicecode.config/gsm/1', modems = { default = default or {}, known = known } }
end

function tests.test_pdp_config_accepts_supported_types_and_rejects_other_values()
	for _, pdp_type in ipairs({ 'IP', 'IPV4V6', 'IPV6' }) do
		local _, err = gsm._test.normalize_config(config({ pdp_type = pdp_type }, { { pdp_type = pdp_type } }))
		eq(err, '')
	end
	for _, pdp_type in ipairs({ '', 'ip', 'PPP', false, 1, {} }) do
		local _, err = gsm._test.normalize_config(config({ pdp_type = pdp_type }))
		eq(err, 'config.modems.default.pdp_type must be IP, IPV4V6 or IPV6')
		_, err = gsm._test.normalize_config(config({}, { { pdp_type = pdp_type } }))
		eq(err, 'config.modems.known[1].pdp_type must be IP, IPV4V6 or IPV6')
	end
end

function tests.test_pdp_config_inherits_default_and_supports_imei_and_device_overrides()
	local input = config({ pdp_type = 'IPV4V6', signal_freq = 10 }, {
		{ imei = 'inherited', name = 'primary' },
		{ imei = 'override', pdp_type = 'IPV6' },
		{ id_field = 'device', device = '/dev/modem', pdp_type = 'IP' },
	})
	local cfg, err = gsm._test.normalize_config(input)
	eq(err, '')
	local inherited, name = gsm._test.get_modem_config(cfg, 'inherited', '')
	eq(inherited.pdp_type, 'IPV4V6')
	eq(inherited.signal_freq, 10)
	eq(name, 'primary')
	eq(gsm._test.get_modem_config(cfg, 'override', '').pdp_type, 'IPV6')
	eq(gsm._test.get_modem_config(cfg, 'other', '/dev/modem').pdp_type, 'IP')
	eq(gsm._test.get_modem_config(cfg, 'unknown', '').pdp_type, 'IPV4V6')
	eq(input.modems.known[1].pdp_type, nil)
end

function tests.test_pdp_config_without_type_defaults_to_ip_without_mutating_input()
	local input = config({}, { { imei = 'known' } })
	local cfg, err = gsm._test.normalize_config(input)
	eq(err, '')
	eq(gsm._test.get_modem_config(cfg, 'unknown', '').pdp_type, 'IP')
	eq(gsm._test.get_modem_config(cfg, 'known', '').pdp_type, 'IP')
	eq(input.modems.default.pdp_type, nil)
	eq(input.modems.known[1].pdp_type, nil)
end

function tests.test_pdp_recovery_uses_configured_type_and_skips_matching_contexts()
	runfibers.run(function()
		for _, pdp_type in ipairs({ 'IP', 'IPV4V6', 'IPV6' }) do
			local m, calls = fixture({
				context(1, 'IP', true), context(2, 'IPV4V6', true), context(3, 'IPV6', true),
				context(4, 'OTHER', false),
			})
			local cfg = gsm._test.normalize_config(config({ pdp_type = pdp_type }))
			m:apply_config(gsm._test.get_modem_config(cfg, 'unknown', ''))
			eq(m:_configure_pdp(), true)
			eq(count(calls, 'set_pdn_type'), 2)
			eq(count(calls, 'restart'), 1)
			for _, call in ipairs(calls) do
				if call.method == 'set_pdn_type' then
					eq(call.opts.pdp_type, pdp_type)
					assert(({ 'IP', 'IPV4V6', 'IPV6' })[call.opts.cid] ~= pdp_type)
				end
			end
		end
	end)
end

function tests.test_pdp_recovery_does_not_restart_when_configured_type_already_matches()
	runfibers.run(function()
		for _, pdp_type in ipairs({ 'IP', 'IPV4V6', 'IPV6' }) do
			local m, calls = fixture({ context(1, pdp_type, true) })
			m.cfg.pdp_type = pdp_type
			local restarted, err = m:_configure_pdp()
			eq(restarted, false)
			eq(err, '')
			eq(count(calls, 'set_pdn_type'), 0)
			eq(count(calls, 'restart'), 0)
		end
	end)
end

function tests.test_pdp_configuration_changes_active_mismatched_contexts_and_restarts_once()
	runfibers.run(function()
		local m, calls, _, _, subs = fixture({
			context(3, 'IPV6', true), context(2, 'IP', true),
			context(1, 'IPV4V6', true), context(4, 'IPV6', false),
		})
		local restarted, err, state = m:_configure_pdp()
		eq(restarted, true)
		eq(err, '')
		eq(state, 'disabled')
		eq(count(calls, 'set_pdn_type'), 2)
		eq(calls[2].opts.cid, 1)
		eq(calls[3].opts.cid, 3)
		eq(calls[2].opts.pdp_type, 'IP')
		eq(count(calls, 'restart'), 1)
		eq(m.pdp_restart_waiting, false)
		eq(subs[1].closed, true)
	end)
end

function tests.test_pdp_configuration_skips_empty_inactive_and_matching_contexts()
	runfibers.run(function()
		for _, contexts in ipairs({ {}, { context(1, 'IP', true), context(2, 'IPV6', false) } }) do
			local m, calls = fixture(contexts)
			local restarted, err = m:_configure_pdp()
			eq(restarted, false)
			eq(err, '')
			eq(count(calls, 'set_pdn_type'), 0)
			eq(count(calls, 'restart'), 0)
		end
	end)
end

function tests.test_pdp_recovery_read_and_verification_failures_do_not_restart()
	runfibers.run(function()
		for _, failure_method in ipairs({ 'get', 'set_pdn_type' }) do
			local m, calls = fixture({ context(1, 'IPV6', true) }, {
				call = function(method)
					if method == failure_method then
						if method == 'set_pdn_type' then
							return correction('rejected', true, 'AT failed')
						end
						return reply(false, 'AT failed')
					end
				end,
			})
			eq(m:_configure_pdp(), false)
			eq(count(calls, 'restart'), 0)
		end
	end)
end

function tests.test_pdp_recovery_restarts_when_change_verification_is_unavailable()
	runfibers.run(function()
		local m, calls = fixture({ context(1, 'IPV6', true) }, {
			call = function(method)
				if method == 'set_pdn_type' then
					return correction('uncertain', true, 'pdp_type_change_unverified:read failed')
				end
			end,
		})
		local restarted, err = m:_configure_pdp()
		eq(restarted, true)
		eq(err, '')
		eq(count(calls, 'set_pdn_type'), 1)
		eq(count(calls, 'restart'), 1)
	end)
end

function tests.test_pdp_recovery_restarts_once_after_partial_verified_changes()
	runfibers.run(function()
		local m, calls = fixture({ context(1, 'IPV6', true), context(2, 'IPV6', true) }, {
			call = function(method, opts)
				if method == 'set_pdn_type' and opts.cid == 1 then
					return correction('rejected', true, 'verification failed')
				end
			end,
		})
		eq(m:_configure_pdp(), true)
		eq(count(calls, 'set_pdn_type'), 2)
		eq(count(calls, 'restart'), 1)
	end)
end

---@return nil
function tests.test_pdp_recovery_stops_commands_on_state_error_and_restarts_verified_changes()
	runfibers.run(function()
		local m, calls = fixture({
			context(1, 'IPV6', true), context(2, 'IPV6', true), context(3, 'IPV6', true),
		}, {
			call = function(method, opts)
				if method == 'set_pdn_type' and opts.cid == 2 then
					return correction('rejected', false, 'modem_invalid_pdp_state:connecting')
				end
			end,
		})
		local restarted, err, state = m:_configure_pdp()
		eq(restarted, true)
		eq(err, '')
		eq(state, 'disabled')
		eq(count(calls, 'set_pdn_type'), 3)
		eq(count(calls, 'restart'), 1)
	end)
end

---@return nil
function tests.test_pdp_recovery_restarts_after_verified_change_without_querying_modem_state()
	runfibers.run(function()
		for _, state in ipairs({ 'connected', 'disabled', 'connecting', 'failed', 'unknown' }) do
			local m, calls = fixture({ context(1, 'IPV6', true) }, {
				call = function(method, opts, _, values)
					if method == 'set_pdn_type' then values.modem_state = state end
					if method == 'get' and opts.field == 'modem_state' then
						error('a verified change must not require a state check before restart')
					end
				end,
			})
			eq(m:_configure_pdp(), true)
			eq(count(calls, 'set_pdn_type'), 1)
			eq(count(calls, 'restart'), 1)
		end
	end)
end

---@return nil
function tests.test_pdp_recovery_retries_required_restart_even_when_inspection_is_state_rejected()
	runfibers.run(function()
		local restart_failed = false
		local m, calls = fixture({ context(1, 'IPV6', true) }, {
			call = function(method, opts)
				if method == 'restart' and not restart_failed then
					restart_failed = true
					return reply(false, 'reset failed')
				end
				if restart_failed and method == 'get' and opts.field == 'pdp_contexts' then
					return reply(false, 'modem_invalid_pdp_state:connecting')
				end
			end,
		})
		eq(m:_configure_pdp(), false)
		eq(m:_configure_pdp(), true)
		eq(count(calls, 'set_pdn_type'), 1)
		eq(count(calls, 'restart'), 2)
	end)
end

---@return nil
function tests.test_pdp_recovery_does_not_restart_after_state_rejection_without_verified_change()
	runfibers.run(function()
		local m, calls = fixture({ context(1, 'IPV6', true), context(2, 'IPV6', true) }, {
			call = function(method)
				if method == 'set_pdn_type' then
					return correction('rejected', false, 'modem_invalid_pdp_state:connecting')
				end
			end,
		})
		local restarted, err, state = m:_configure_pdp()
		eq(restarted, false)
		eq(err, 'modem_invalid_pdp_state:connecting')
		eq(state, 'connecting')
		eq(count(calls, 'set_pdn_type'), 2)
		eq(count(calls, 'restart'), 0)
	end)
end

function tests.test_pdp_recovery_late_connection_and_state_errors_do_not_restart()
	runfibers.run(function()
		for _, state in ipairs({ 'connected', 'enabling', 'connecting' }) do
			local m, calls = fixture({}, {
				call = function(method, opts)
					if method == 'get' and opts.field == 'pdp_contexts' then
						return reply(false, 'error getting field pdp_contexts: modem_invalid_pdp_state:' .. state)
					end
				end,
			})
			local restarted, _, observed_state = m:_configure_pdp()
			eq(restarted, false)
			eq(observed_state, state)
			eq(count(calls, 'restart'), 0)
		end
	end)
end

function tests.test_pdp_restart_failure_preserves_verified_change_and_closes_subscription()
	runfibers.run(function()
		local m, _, _, _, subs = fixture({ context(1, 'IPV6', true) }, {
			call = function(method) if method == 'restart' then return reply(false, 'reset failed') end end,
		})
		local restarted, err = m:_configure_pdp()
		eq(restarted, false)
		eq(err, 'pdp_operation_failed')
		assert(m.svc.pdp_enforcement.modems['modem-1'].types.IP.fallback.active_episode)
		eq(subs[1].closed, true)
	end)
end

function tests.test_pdp_restart_unobserved_transition_restores_retry_state()
	runfibers.run(function()
		local contexts = { context(1, 'IPV6', true) }
		local m, calls, _, _, subs = fixture(contexts, {
			call = function(method, opts, active_subs)
				if method == 'set_pdn_type' then contexts[1].pdp_type = opts.pdp_type end
				if method == 'restart' then
					for _, sub in ipairs(active_subs) do
						if not sub.closed then sub.recv_op = function() return op.always(nil) end end
					end
					return reply(true)
				end
			end,
		})
		local restarted, err = m:_configure_pdp()
		eq(restarted, false)
		eq(err, 'state subscription interrupted')
		eq(m.pdp_restart_waiting, false)
		assert(m.svc.pdp_enforcement.modems['modem-1'].types.IP.fallback.active_episode)
		eq(subs[1].closed, true)

		-- Without replacement there is no evidence that the modem actually reset,
		-- so the existing transition-timeout retry remains in force.
		restarted, err = m:_configure_pdp()
		eq(restarted, false)
		eq(err, '')
		eq(count(calls, 'restart'), 2)
		eq(count(calls, 'get'), 1)
	end)
end

function tests.test_pdp_scope_merge_preserves_a_correction_whose_reset_failed_after_an_older_reset()
	runfibers.run(function()
		local m, calls = fixture({ context(1, 'IP', true), context(2, 'IP', true) })
		m:_claim_pdp_owner()
		local modem_state = m.svc.pdp_enforcement.modems['modem-1']
		modem_state.types.IP = {
			iccids = {
				sim = {
					inspection_failures = 0, inspection_exhausted = false, next_episode = 1,
					cids = { ['1'] = { corrections = 1, exhausted = false, blocked = false } },
					active_episode = {
						id = 1, cids = { ['1'] = true }, unreset_cids = {}, restart_count = 1,
						state = 'awaiting_reinspection',
					},
					history = {},
				},
			},
			fallback = {
				inspection_failures = 0, inspection_exhausted = false, next_episode = 1,
				cids = { ['2'] = { corrections = 1, exhausted = false, blocked = false } },
				active_episode = {
					id = 1, cids = { ['2'] = true }, unreset_cids = { ['2'] = true },
					restart_count = 1, state = 'pending',
				},
				history = {},
			},
		}
		m.pdp_iccid = 'sim'

		local merged = m:_pdp_scope('IP')
		eq(merged.active_episode.state, 'pending')
		eq(merged.active_episode.unreset_cids['2'], true)
		eq(m:_configure_pdp(), true)
		eq(count(calls, 'restart'), 1)
		eq(count(calls, 'get'), 0)
		eq(next(merged.history[#merged.history].unreset_cids), nil)
	end)
end

function tests.test_pdp_unobserved_restart_exhaustion_is_accepted_by_log_checker()
	local original_sleep_op = sleep.sleep_op
	local ok, err = safe.pcall(function()
		runfibers.run(function()
			local contexts = { context(1, 'IPV6', true) }
			local m, calls, logs
			sleep.sleep_op = function(seconds)
				if seconds >= 19 and seconds <= 20 then return op.always() end
				return original_sleep_op(seconds)
			end
			m, calls, logs = fixture(contexts, { call = function(method, opts, subs)
				if method == 'set_pdn_type' then contexts[1].pdp_type = opts.pdp_type end
				if method == 'restart' then
					-- Only reset subscriptions are interrupted; preserve the main loop's
					-- card subscription so it can proceed to enable on exhaustion.
					for index, sub in ipairs(subs) do
						if index > 2 and not sub.closed then
							sub.recv_op = function() return op.always(nil) end
						end
					end
					return reply(true)
				elseif method == 'enable' then
					m.config_pulse:close()
					return reply(true)
				end
			end })
			prepare_autoconnect(m)
			m:_autoconnect_loop()
			eq(count(calls, 'restart'), 2)
			eq(count(calls, 'enable'), 1)
			local lines = {}
			for _, payload in ipairs(logs) do
				if type(payload) == 'table' then
					local fields = {}
					for key, value in pairs(payload) do
						if key ~= 'what' and value ~= '' then
							fields[#fields + 1] = key .. '=' .. tostring(value)
						end
					end
					lines[#lines + 1] = '2026-11-12 14:30:00 (mono=100) LOG gsm info '
						.. payload.what .. ' ' .. payload.what .. ' ' .. table.concat(fields, ' ')
				end
			end
			require('onbox.modem_pdp.runner').check_restart_order(table.concat(lines, '\n'))
		end)
	end)
	sleep.sleep_op = original_sleep_op
	assert(ok, err)
end

function tests.test_pdp_recovered_correction_reset_is_retried_after_iccid_merge()
	runfibers.run(function()
		local contexts = { context(2, 'IPV6', true) }
		local svc = { obs_log = function() end }
		local replacement, replacement_calls
		local reset_attempts = 0
		local old, old_calls = fixture(contexts, {
			svc = svc,
			call = function(method, opts)
				if method == 'set_pdn_type' then
					contexts[1].pdp_type = opts.pdp_type
					replacement, replacement_calls = fixture(contexts, {
						svc = svc,
						call = function(replacement_method)
							if replacement_method == 'restart' then
								reset_attempts = reset_attempts + 1
								if reset_attempts == 1 then return reply(false, 'reset failed') end
							end
						end,
					})
					replacement:_claim_pdp_owner()
					return correction('applied', true)
				end
			end,
		})
		old:_claim_pdp_owner()
		-- Existing SIM bookkeeping from an earlier correction/reset. The new
		-- owner starts without that SIM identity and uses the fallback scope.
		old.pdp_iccid = 'sim'
		local previous = old:_pdp_scope('IP')
		previous.cids['1'] = { corrections = 1, exhausted = false, blocked = false }
		previous.active_episode = {
			id = 1, cids = { ['1'] = true }, unreset_cids = {},
			restart_count = 1, state = 'awaiting_reinspection',
		}
		old.pdp_iccid = nil

		eq(select(2, old:_configure_pdp()), 'pdp_owner_stale')
		eq(count(old_calls, 'set_pdn_type'), 1)
		eq(count(old_calls, 'restart'), 0)
		local fallback = svc.pdp_enforcement.modems['modem-1'].types.IP.fallback
		eq(fallback.cids['2'].last_result.outcome, 'uncertain')
		eq(fallback.active_episode.unreset_cids['2'], true)
		eq(select(2, replacement:_configure_pdp()), 'pdp_operation_failed')
		eq(count(replacement_calls, 'restart'), 1)

		replacement:_queue_pdp_iccid('sim')
		local restarted, err = replacement:_configure_pdp()
		eq(err, '')
		eq(count(replacement_calls, 'restart'), 2)
		eq(restarted, true)
		eq(count(replacement_calls, 'get'), 0)
	end)
end

function tests.test_pdp_restart_cancellation_cleans_wait_and_consumes_reservation()
	runfibers.run(function(scope)
		local m, calls = fixture({ context(1, 'IPV6', true) }, {
			call = function(method)
				if method == 'restart' then return reply(true) end
			end,
		})
		local invocation = assert(scope:child())
		assert(invocation:spawn(function() m:_configure_pdp() end))
		while not m.pdp_restart_waiting do sleep.sleep(0.001) end

		invocation:cancel('test cancellation')
		eq(select(1, fibers.perform(invocation:join_op())), 'cancelled')
		eq(m.pdp_restart_waiting, false)
		eq(m._pdp_restart_wait_owner, nil)
		eq(count(calls, 'restart'), 1)
		local episode = m.svc.pdp_enforcement.modems['modem-1'].types.IP.fallback.active_episode
		eq(episode.restart_count, 1)
		eq(episode.restart_inflight, nil)
	end)
end

function tests.test_pdp_correction_limit_survives_modem_recreation()
	runfibers.run(function()
		local svc = { obs_log = function() end }
		local contexts = { context(1, 'IPV6', true) }
		local function correction_fixture()
			return fixture(contexts, {
				svc = svc,
				call = function(method, opts)
					if method == 'set_pdn_type' then contexts[1].pdp_type = opts.pdp_type end
				end,
			})
		end
		local first, first_calls = correction_fixture()
		eq(first:_configure_pdp(), true)
		eq(count(first_calls, 'set_pdn_type'), 1)
		eq(count(first_calls, 'restart'), 1)

		contexts[1].pdp_type = 'IPV6' -- Carrier profile reverted the context after reset.
		local replacement, replacement_calls = correction_fixture()
		eq(replacement:_configure_pdp(), true)
		eq(count(replacement_calls, 'set_pdn_type'), 1)
		eq(count(replacement_calls, 'restart'), 1)

		contexts[1].pdp_type = 'IPV6'
		local third, third_calls = correction_fixture()
		local restarted, err = third:_configure_pdp()
		eq(restarted, false)
		eq(err, '')
		eq(count(third_calls, 'set_pdn_type'), 0)
		eq(count(third_calls, 'restart'), 0)
	end)
end

function tests.test_pdp_restart_discards_stale_disabled_events()
	runfibers.run(function()
		local m = fixture({ context(1, 'IPV6', true) }, {
			call = function(method, _, subs)
				if method == 'restart' then
					subs[1].queue:put({ payload = { from = 'disabled', to = 'disabled' } })
					subs[1].queue:put({ payload = { from = 'initializing', to = 'disabled' } })
					return reply(true)
				end
			end,
		})
		local restarted, err, state = m:_configure_pdp()
		eq(restarted, true)
		eq(err, '')
		eq(state, 'disabled')
		eq(m.pdp_restart_waiting, false)
	end)
end

local function with_rankings(body)
	local saved = apns.get_ranked_apns
	apns.get_ranked_apns = function()
		return { first = { apn = 'first' }, second = { apn = 'second' } },
			{ { name = 'first', rank = 0 }, { name = 'second', rank = 1 } }
	end
	local ok, err = safe.pcall(function() runfibers.run(body) end)
	apns.get_ranked_apns = saved
	assert(ok, err)
end

function tests.test_pdp_configuration_does_not_run_after_apn_exhaustion()
	with_rankings(function()
		local m, calls = fixture({}, {
			call = function(method, _, subs)
				if method == 'connect' then
					local queue = subs[#subs].queue
					queue:put({ payload = { to = 'connecting' } })
					queue:put({ payload = { to = 'registered' } })
				end
			end,
		})
		local _, err = m:_apn_connect()
		eq(err, 'no apn connected')
		eq(count(calls, 'connect'), 2)
		for _, call in ipairs(calls) do
			assert(not (call.method == 'get' and call.opts.field == 'pdp_contexts'))
		end
	end)
end

function tests.test_pdp_recovery_does_not_run_for_success_throttling_or_unsettled_state()
	with_rankings(function()
		for _, reason in ipairs({ 'success', 'pdn-ipv4-call-throttled', 'unsettled', 'late connected' }) do
			local m, calls = fixture({}, {
				call = function(method, _, subs)
					if method == 'connect' then
						if reason == 'success' then return reply(true) end
						if reason == 'pdn-ipv4-call-throttled' then return reply(false, reason) end
						local queue = subs[#subs].queue
						queue:put({ payload = { to = 'connecting' } })
						queue:put({ payload = { to = 'connected' } })
					end
				end,
			})
			if reason == 'unsettled' then
				m.cap.get_state_sub = function()
					return { recv = function() end, recv_op = function() return op.always(nil) end,
						unsubscribe = function() end }
				end
				m.cap.call_control_op = function(_, method, opts)
					calls[#calls + 1] = { method = method, opts = opts }
					if method == 'get' then return reply(true, '234') end
					return reply(false, 'connection failed')
				end
			end
			m:_apn_connect()
			eq(count(calls, 'connect'), 1)
			for _, call in ipairs(calls) do
				assert(not (call.method == 'get' and call.opts.field == 'pdp_contexts'))
			end
		end
	end)
end

function tests.test_pdp_recovery_skips_zero_attempts_and_missing_identifiers()
	with_rankings(function()
		for _, missing_identifier in ipairs({ false, true }) do
			local m, calls = fixture({}, {
				call = function(method, opts)
					if missing_identifier and method == 'get' and opts.field == 'mcc' then
						return reply(false, 'missing mcc')
					end
				end,
			})
			m.cfg.apn_rank_cutoff = -1
			m:_apn_connect()
			eq(count(calls, 'connect'), 0)
			for _, call in ipairs(calls) do
				assert(not (call.method == 'get' and call.opts.field == 'pdp_contexts'))
			end
		end
	end)
end

---@param modem GsmModem
---@return nil
prepare_autoconnect = function(modem)
	modem.cfg.autoconnect = true
	modem.domain = { retain = function() end }
	modem._publish_uplink_state = function() end
	modem._emit_metric = function() end
	modem.svc.obs_event = function(_, event, payload)
		if event == 'connection_changed' and payload.connected then modem.config_pulse:close() end
	end
end

---@return nil
function tests.test_pdp_disabled_check_corrects_restarts_rereads_then_connects_successfully()
	with_rankings(function()
		for _, target in ipairs({ 'IP', 'IPV4V6', 'IPV6' }) do
			local wrong_type = target == 'IP' and 'IPV6' or 'IP'
			local contexts = { context(1, wrong_type, true) }
			local reads = 0
			local m, calls = fixture(contexts, {
				call = function(method, opts, subs)
					if method == 'get' and opts.field == 'pdp_contexts' then reads = reads + 1 end
					if method == 'set_pdn_type' then contexts[1].pdp_type = opts.pdp_type end
					if method == 'enable' then
						assert(reads >= 2, 'enable ran before post-restart PDP check')
						eq(contexts[1].pdp_type, target)
						subs[1].queue:put({ payload = { from = 'enabling', to = 'registered' } })
					end
					if method == 'connect' then
						subs[1].queue:put({ payload = { from = 'connecting', to = 'connected' } })
						return reply(true)
					end
				end,
			})
			prepare_autoconnect(m)
			m.cfg.pdp_type = target
			m:_autoconnect_loop()
			assert(count(calls, 'set_pdn_type') == 1, 'expected one PDP write for ' .. target)
			assert(count(calls, 'restart') == 1, 'expected one restart for ' .. target)
			assert(count(calls, 'enable') == 1, 'expected one enable for ' .. target)
			assert(count(calls, 'connect') == 1, 'expected one connection for ' .. target)
			assert(reads >= 2, 'expected PDP read before and after restart')
		end
	end)
end

---@return nil
function tests.test_pdp_disabled_check_enables_without_restarting_when_already_correct()
	with_rankings(function()
		local m, calls = fixture({ context(1, 'IPV6', true) }, {
			call = function(method, _, subs)
				if method == 'enable' then
					subs[1].queue:put({ payload = { from = 'enabling', to = 'registered' } })
				elseif method == 'connect' then
					subs[1].queue:put({ payload = { from = 'connecting', to = 'connected' } })
					return reply(true)
				end
			end,
		})
		prepare_autoconnect(m)
		m.cfg.pdp_type = 'IPV6'
		m:_autoconnect_loop()
		eq(calls[1].method, 'get')
		eq(calls[1].opts.field, 'pdp_contexts')
		eq(calls[2].method, 'enable')
		eq(count(calls, 'set_pdn_type'), 0)
		eq(count(calls, 'restart'), 0)
		eq(count(calls, 'connect'), 1)
	end)
end

---@return nil
function tests.test_pdp_disabled_check_prevents_enable_on_read_or_write_failure()
	runfibers.run(function()
		for _, fail_method in ipairs({ 'get', 'set_pdn_type' }) do
			local m, calls
			m, calls = fixture({ context(1, 'IPV6', true) }, {
				call = function(method)
					if method == fail_method then
						m.config_pulse:close()
						if method == 'set_pdn_type' then
							return correction('rejected', true, 'AT failed')
						end
						return reply(false, 'AT failed')
					end
				end,
			})
			prepare_autoconnect(m)
			m:_autoconnect_loop()
			eq(count(calls, 'enable'), 0)
			eq(count(calls, 'connect'), 0)
			eq(count(calls, 'restart'), 0)
		end
	end)
end

---@return nil
function tests.test_pdp_disabled_gate_rejects_shifted_backend_replies_before_enabling()
	local saved_send = at.send_op
	local ok, err = safe.pcall(function()
		runfibers.run(function()
			for _, activation_reply in ipairs({
				{ '+CGDCONT: 1,"IP","","0.0.0.0",0,0,0,0' },
				{ '+CGACT: 1,1' },
			}) do
				at.send_op = function(_, command)
					if command == 'AT+CGDCONT?' then return op.always({}) end
					eq(command, 'AT+CGACT?')
					return op.always(activation_reply)
				end
				local backend = { identity = { at_port = '/test' } }
				quectel.add_model_funcs(backend, { model = 'unknown-quectel' })
				local m, calls, logs
				m, calls, logs = fixture({}, { call = function(method, opts)
					if method == 'get' and opts.field == 'pdp_contexts' then
						local info, read_err = backend:read_pdp_info()
						m.config_pulse:close()
						return reply(info ~= nil, info and info.pdp_contexts or read_err)
					end
				end })
				prepare_autoconnect(m)
				m:_autoconnect_loop()
				eq(count(calls, 'enable'), 0)
				eq(count(calls, 'connect'), 0)
				eq(count(calls, 'restart'), 0)
				local failed = false
				for _, record in ipairs(logs) do
					if record.what == 'pdp_inspect_failed' then failed = true end
					assert(record.what ~= 'pdp_contexts_checked', 'Invalid data logged as checked')
				end
				assert(failed, 'Expected a failed PDP inspection')
			end
		end)
	end)
	at.send_op = saved_send
	assert(ok, err)
end

---@return nil
function tests.test_pdp_inspection_logs_requested_type_and_context_activity()
	runfibers.run(function()
		local m, _, logs = fixture({ context(2, 'IPV6', false), context(1, 'IP', true) })
		m.cfg.pdp_type = 'IP'
		local _, err = m:_configure_pdp()
		eq(err, '')
		local checked
		for _, record in ipairs(logs) do
			if record.what == 'pdp_contexts_checked' then checked = record end
		end
		assert(checked, 'Expected a PDP inspection record')
		eq(checked.pdp_type, 'IP')
		eq(checked.contexts, '1:IP:active,2:IPV6:inactive')
	end)
end

---@return nil
function tests.test_pdp_disabled_check_retries_read_write_and_restart_failures_before_enabling()
	local saved_sleep_op = sleep.sleep_op
	local ok, err = safe.pcall(function()
		with_rankings(function()
			for _, fail_method in ipairs({ 'get', 'set_pdn_type', 'restart' }) do
				local contexts = { context(1, 'IPV6', true) }
				local failed, retry_pending, retries = false, false, 0
				local m, calls = fixture(contexts, {
					call = function(method, opts, subs)
						if method == fail_method and not failed
							and (method ~= 'get' or opts.field == 'pdp_contexts') then
							failed, retry_pending = true, true
							if method == 'set_pdn_type' then
								return correction('rejected', false, 'temporary failure')
							end
							return reply(false, 'temporary failure')
						end
						if method == 'set_pdn_type' then contexts[1].pdp_type = opts.pdp_type end
						if method == 'enable' then
							eq(retries, 1)
							eq(contexts[1].pdp_type, 'IP')
							subs[1].queue:put({ payload = { from = 'enabling', to = 'registered' } })
						elseif method == 'connect' then
							subs[1].queue:put({ payload = { from = 'connecting', to = 'connected' } })
							return reply(true)
						end
					end,
				})
				sleep.sleep_op = function(seconds)
					if retry_pending and seconds == 20 then
						retry_pending = false
						retries = retries + 1
						eq(count(calls, 'enable'), 0)
						eq(count(calls, 'connect'), 0)
						return op.always()
					end
					return saved_sleep_op(seconds)
				end
				prepare_autoconnect(m)
				m:_autoconnect_loop()
				eq(failed, true)
				eq(retries, 1)
				eq(count(calls, 'enable'), 1)
				eq(count(calls, 'connect'), 1)
				eq(count(calls, 'set_pdn_type'), fail_method == 'set_pdn_type' and 2 or 1)
				eq(count(calls, 'restart'), fail_method == 'restart' and 2 or 1)
			end
		end)
	end)
	sleep.sleep_op = saved_sleep_op
	assert(ok, err)
end

---@return nil
function tests.test_pdp_disabled_check_does_not_run_when_autoconnect_is_off()
	runfibers.run(function()
		local contexts = { context(1, 'IPV6', true) }
		local m, calls = fixture(contexts)
		prepare_autoconnect(m)
		m.cfg.autoconnect = false
		m.config_pulse:close()
		m:_autoconnect_loop()
		for _, call in ipairs(calls) do
			assert(not (call.method == 'get' and call.opts.field == 'pdp_contexts'))
		end
		eq(count(calls, 'set_pdn_type'), 0)
		eq(count(calls, 'restart'), 0)
		eq(count(calls, 'enable'), 0)
		eq(count(calls, 'connect'), 0)
	end)
end

---@return nil
function tests.test_pdp_disabled_check_allows_unsupported_modems_to_enable()
	with_rankings(function()
		local m, calls = fixture({}, {
			call = function(method, opts, subs)
				if method == 'get' and opts.field == 'pdp_contexts' then
					return reply(false, 'error getting field pdp_contexts: pdp_not_supported')
				elseif method == 'enable' then
					subs[1].queue:put({ payload = { from = 'enabling', to = 'registered' } })
				elseif method == 'connect' then
					subs[1].queue:put({ payload = { from = 'connecting', to = 'connected' } })
					return reply(true)
				end
			end,
		})
		prepare_autoconnect(m)
		m:_autoconnect_loop()
		eq(count(calls, 'enable'), 1)
		eq(count(calls, 'connect'), 1)
		eq(count(calls, 'restart'), 0)
	end)
end

local function find_log(logs, what, budget_kind)
	for _, record in ipairs(logs) do
		if record.what == what and (not budget_kind or record.budget_kind == budget_kind) then
			return record
		end
	end
end

local function count_logs(logs, what, budget_kind)
	local total = 0
	for _, record in ipairs(logs) do
		if record.what == what and (not budget_kind or record.budget_kind == budget_kind) then
			total = total + 1
		end
	end
	return total
end

local function assert_logs_private(logs, secrets)
	local function visit(value)
		if type(value) == 'table' then
			for key, child in pairs(value) do visit(key); visit(child) end
		else
			local text = tostring(value)
			for _, secret in ipairs(secrets) do
				assert(not text:find(secret, 1, true), 'private PDP value reached logs')
			end
		end
	end
	visit(logs)
end

function tests.test_pdp_inspection_failures_are_scope_wide_monotonic_and_fail_open_at_two()
	runfibers.run(function()
		local reads = 0
		local m, calls, logs = fixture({}, { call = function(method, opts)
			if method == 'get' and opts.field == 'pdp_contexts' then
				reads = reads + 1
				if reads ~= 2 then
					return reply(false, 'malformed_pdp_context:+CGDCONT: 1,"IP","private.apn","secret-iccid"')
				end
				return reply(true, {})
			end
		end })
		eq(select(2, m:_configure_pdp()), 'pdp_operation_failed')
		eq(select(2, m:_configure_pdp()), '') -- Success does not reset the failed-inspection count.
		local restarted, err = m:_configure_pdp()
		eq(restarted, false)
		eq(err, '')
		for _ = 1, 3 do
			local repeated, repeated_err, _, decision = m:_configure_pdp()
			eq(repeated, false)
			eq(repeated_err, '')
			eq(decision.proceed, true)
		end
		eq(count(calls, 'set_pdn_type'), 0)
		eq(reads, 3)
		local scope_state = m.svc.pdp_enforcement.modems['modem-1'].types.IP.fallback
		eq(scope_state.inspection_failures, 2)
		eq(scope_state.inspection_exhausted, true)
		eq(count_logs(logs, 'pdp_enforcement_exhausted', 'inspection'), 1)
		eq(count_logs(logs, 'pdp_inspect_failed'), 2)
		local terminal = assert(find_log(logs, 'pdp_enforcement_exhausted', 'inspection'))
		eq(terminal.absorption, 'scope')
		eq(terminal.count, 2)
		eq(terminal.limit, 2)
		eq(terminal.effective_type, 'IP')
		eq(terminal.enable_proceeding, true)
		assert_logs_private(logs, { 'private.apn', 'secret-iccid' })
	end)
end

function tests.test_pdp_scope_persists_across_sim_absence_and_config_apply_but_types_are_independent()
	runfibers.run(function()
		local m, _, logs = fixture({}, { call = function(method, opts)
			if method == 'get' and opts.field == 'pdp_contexts' then return reply(false, 'read failed') end
		end })
		eq(select(2, m:_configure_pdp()), 'pdp_operation_failed')
		m:_accept_sim_state(false)
		m:apply_config({ pdp_type = 'IP', autoconnect = true })
		eq(select(2, m:_configure_pdp()), '')
		assert(find_log(logs, 'pdp_enforcement_exhausted', 'inspection'))

		m:apply_config({ pdp_type = 'IPV6', autoconnect = true })
		eq(select(2, m:_configure_pdp()), 'pdp_operation_failed')
		local type_state = m.svc.pdp_enforcement.modems['modem-1'].types
		eq(type_state.IP.fallback.inspection_failures, 2)
		eq(type_state.IPV6.fallback.inspection_failures, 1)
	end)
end

function tests.test_pdp_inspection_exhaustion_enables_in_the_same_disabled_pass()
	local saved_sleep_op = sleep.sleep_op
	local ok, err = safe.pcall(function()
		runfibers.run(function(scope)
			local reads, passes = 0, 0
			local m, calls, logs, unused_values, subs
			m, calls, logs, unused_values, subs = fixture({}, { call = function(method, opts, active_subs)
				if method == 'get' and opts.field == 'pdp_contexts' then
					reads = reads + 1
					return reply(false, 'read failed')
				elseif method == 'enable' then
					assert(find_log(logs, 'pdp_enforcement_exhausted', 'inspection'))
				elseif method == 'connect' then
					active_subs[1].queue:put({ payload = { from = 'connecting', to = 'connected' } })
					return reply(true)
				end
			end })
			local original_configure = m._configure_pdp
			m._configure_pdp = function(self)
				passes = passes + 1
				return original_configure(self)
			end
			sleep.sleep_op = function(seconds)
				if seconds == 20 and reads == 1 then return op.always() end
				return saved_sleep_op(seconds)
			end
			prepare_autoconnect(m)
			assert(scope:spawn(function()
				while count(calls, 'enable') < 1 do sleep.sleep(0.001) end
				eq(m.inspection_enable_proceeded, true)
				for expected_pass = 3, 5 do
					subs[1].queue:put({ payload = { from = 'disabled', to = 'disabled' } })
					while passes < expected_pass do sleep.sleep(0.001) end
				end
				subs[1].queue:put({ payload = { from = 'enabling', to = 'registered' } })
			end))
			m:_autoconnect_loop()
			eq(reads, 2)
			eq(passes, 5)
			eq(count(calls, 'enable'), 1)
			eq(count(calls, 'connect'), 1)
			eq(count_logs(logs, 'pdp_enforcement_exhausted', 'inspection'), 1)
			eq(count_logs(logs, 'pdp_inspect_failed'), 2)
			local scope_state = m.svc.pdp_enforcement.modems['modem-1'].types.IP.fallback
			eq(scope_state.inspection_failures, 2)
			eq(scope_state.inspection_enable_proceeded, nil)
			eq(m.inspection_enable_proceeded, false)
		end)
	end)
	sleep.sleep_op = saved_sleep_op
	assert(ok, err)
end

function tests.test_pdp_late_iccid_merge_does_not_persist_instance_enable_latch()
	runfibers.run(function()
		local private_iccid = '8901000000000000001'
		local reads = 0
		local old
		local svc = { obs_log = function() end }
		old = fixture({}, {
			svc = svc,
			call = function(method, opts)
				if method == 'get' and opts.field == 'pdp_contexts' then
					reads = reads + 1
					if reads == 2 then old:_queue_pdp_iccid(private_iccid) end
					return reply(false, 'read failed for ' .. private_iccid)
				end
			end,
		})
		eq(select(2, old:_configure_pdp()), 'pdp_operation_failed')
		local _, err, _, decision = old:_configure_pdp()
		eq(err, '')
		eq(decision.proceed, true)
		old.inspection_enable_proceeded = true
		eq((select(4, old:_configure_pdp())).proceed, false)

		local type_state = svc.pdp_enforcement.modems['modem-1'].types.IP
		eq(type_state.fallback.tombstone, true)
		eq(type_state.iccids[private_iccid].inspection_enable_proceeded, nil)

		local replacement = fixture({}, { svc = svc })
		replacement:_queue_pdp_iccid(private_iccid)
		local _, replacement_err, _, replacement_decision = replacement:_configure_pdp()
		eq(replacement_err, '')
		eq(replacement_decision.proceed, true)
		eq(replacement.inspection_enable_proceeded, false)
	end)
end

function tests.test_pdp_result_precedence_continues_rejections_and_applied_but_stops_on_uncertain()
	runfibers.run(function()
		local contexts = {
			context(1, 'IPV6', true), context(2, 'IPV6', true), context(3, 'IPV6', true),
			context(4, 'IPV6', true), context(5, 'IPV6', true),
		}
		local m, calls = fixture(contexts, { call = function(method, opts)
			if method ~= 'set_pdn_type' then return end
			if opts.cid == 1 then return correction('rejected', false, 'pre-dispatch') end
			if opts.cid == 2 then return correction('rejected', true, 'modem rejected') end
			if opts.cid == 3 then return correction('applied', true) end
			if opts.cid == 4 then return correction('uncertain', true, 'reply lost') end
			error('uncertain result must stop later siblings')
		end })
		eq(m:_configure_pdp(), true)
		eq(count(calls, 'set_pdn_type'), 4)
		eq(count(calls, 'restart'), 1)
		local scope_state = m.svc.pdp_enforcement.modems['modem-1'].types.IP.fallback
		local episode = scope_state.history[#scope_state.history]
		assert(episode.cids['3'] and episode.cids['4'])
		assert(not episode.cids['1'] and not episode.cids['2'])
	end)
end

function tests.test_pdp_second_rejection_services_prior_episode_then_fails_open()
	runfibers.run(function()
		local m, calls, logs, values = fixture({ context(2, 'IPV6', true) }, {
			call = function(method, opts)
				if method == 'set_pdn_type' and opts.cid == 2 then
					return correction('rejected', opts.cid == 2, 'persistent mismatch')
				end
				if method == 'set_pdn_type' then return correction('applied', true) end
			end,
		})
		eq(select(2, m:_configure_pdp()), 'pdp_operation_failed')
		values.pdp_contexts = {
			context(1, 'IPV6', true), context(2, 'IPV6', true), context(3, 'IPV6', true),
		}
		local restarted, err = m:_configure_pdp()
		eq(restarted, false)
		eq(err, '')
		eq(count(calls, 'set_pdn_type'), 3)
		eq(count(calls, 'restart'), 1)
		local terminal = assert(find_log(logs, 'pdp_enforcement_exhausted', 'correction'))
		eq(terminal.cid, 2)
		eq(terminal.absorption, 'cid')
		eq(terminal.outcome, 'rejected')
		eq(terminal.dispatched, true)
		local scope_state = m.svc.pdp_enforcement.modems['modem-1'].types.IP.fallback
		eq(scope_state.history[#scope_state.history].state, 'completed_unverified_fail_open')
	end)
end

function tests.test_pdp_preexhausted_later_cid_services_earlier_sibling_episode_first()
	runfibers.run(function()
		local m, calls, logs = fixture({
			context(1, 'IPV6', true), context(2, 'IPV6', true),
		})
		local scope_state = assert(m:_begin_pdp_operation('IP'))
		scope_state.cids['2'] = {
			corrections = 2,
			exhausted = false,
			blocked = false,
			last_result = { outcome = 'rejected', dispatched = true, err = 'pdp_correction_rejected' },
		}
		m:_finish_pdp_operation(m.pdp_owner_generation, 'IP')

		local restarted, err = m:_configure_pdp()
		eq(restarted, false)
		eq(err, '')
		eq(count(calls, 'set_pdn_type'), 1)
		eq(calls[2].opts.cid, 1)
		eq(count(calls, 'restart'), 1)
		eq(count_logs(logs, 'pdp_enforcement_exhausted', 'correction'), 1)
		local terminal = assert(find_log(logs, 'pdp_enforcement_exhausted', 'correction'))
		eq(terminal.cid, 2)
		eq(scope_state.history[#scope_state.history].state, 'completed_unverified_fail_open')
		eq(scope_state.history[#scope_state.history].cids['1'], true)
	end)
end

function tests.test_pdp_exhausted_cid_is_skipped_while_new_cid_is_corrected()
	runfibers.run(function()
		local m, calls, _, values = fixture({ context(1, 'IPV6', true) }, {
			call = function(method, opts)
				if method == 'set_pdn_type' and opts.cid == 1 then
					return correction('rejected', true, 'persistent mismatch')
				end
			end,
		})
		eq(select(2, m:_configure_pdp()), 'pdp_operation_failed')
		eq(select(2, m:_configure_pdp()), '')
		values.pdp_contexts = { context(1, 'IPV6', true), context(2, 'IPV6', true) }
		eq(m:_configure_pdp(), true)
		eq(count(calls, 'set_pdn_type'), 3)
		eq(calls[#calls - 1].opts.cid, 2)
		eq(count(calls, 'restart'), 1)
	end)
end

function tests.test_pdp_restart_reservations_exhaust_episode_only_and_allow_new_cids()
	runfibers.run(function()
		local restart_calls = 0
		local m, calls, logs, values = fixture({ context(1, 'IPV6', true) }, {
			call = function(method)
				if method == 'restart' then
					restart_calls = restart_calls + 1
					if restart_calls <= 2 then return reply(false, 'reset failed') end
				end
			end,
		})
		eq(select(2, m:_configure_pdp()), 'pdp_operation_failed')
		local restarted, err = m:_configure_pdp()
		eq(restarted, false)
		eq(err, '')
		local terminal = assert(find_log(logs, 'pdp_enforcement_exhausted', 'restart'))
		eq(terminal.absorption, 'episode_cids')
		eq(terminal.cids, '1')
		eq(terminal.count, 2)
		values.pdp_contexts = { context(1, 'IPV6', true), context(2, 'IPV6', true) }
		eq(m:_configure_pdp(), true)
		eq(count(calls, 'set_pdn_type'), 2)
		eq(count(calls, 'restart'), 3)
	end)
end

function tests.test_pdp_fallback_scope_merges_atomically_into_iccid_without_logging_it()
	runfibers.run(function()
		local reads = 0
		local private_iccid = '8901000000000000001'
		local next_iccid = '8901000000000000002'
		local m
		local logs
		m, _, logs = fixture({}, { call = function(method, opts)
			if method == 'get' and opts.field == 'pdp_contexts' then
				reads = reads + 1
				if reads == 1 then m:_queue_pdp_iccid(private_iccid) end
				return reply(false, 'read failed for ' .. private_iccid)
			end
		end })
		eq(select(2, m:_configure_pdp()), 'pdp_operation_failed')
		local type_state = m.svc.pdp_enforcement.modems['modem-1'].types.IP
		eq(type_state.fallback.tombstone, true)
		eq(type_state.iccids[private_iccid].inspection_failures, 1)
		eq(select(2, m:_configure_pdp()), '')
		m:_queue_pdp_iccid(next_iccid)
		eq(select(2, m:_configure_pdp()), 'pdp_operation_failed')
		eq(type_state.iccids[next_iccid].inspection_failures, 1)
		assert_logs_private(logs, { private_iccid, next_iccid })
	end)
end

function tests.test_pdp_owner_replacement_reconciles_rpc_started_once_and_blocks_stale_logs()
	runfibers.run(function()
		local logs, replacement, replacement_calls = {}, nil, nil
		local svc = { obs_log = function(_, _, payload) logs[#logs + 1] = payload end }
		local old, old_calls = fixture({ context(1, 'IPV6', true) }, {
			svc = svc,
			call = function(method)
				if method == 'set_pdn_type' then
					replacement, replacement_calls = fixture({ context(1, 'IPV6', true) }, { svc = svc })
					replacement:_claim_pdp_owner()
					return correction('applied', true)
				end
			end,
		})
		local restarted, err = old:_configure_pdp()
		eq(restarted, false)
		eq(err, 'pdp_owner_stale')
		eq(count(old_calls, 'restart'), 0)
		assert(not find_log(logs, 'pdp_type_changed'))
		local scope_state = svc.pdp_enforcement.modems['modem-1'].types.IP.fallback
		eq(scope_state.cids['1'].last_result.outcome, 'uncertain')
		local generation = replacement.pdp_owner_generation
		replacement:_claim_pdp_owner()
		eq(replacement.pdp_owner_generation, generation)
		eq(replacement:_configure_pdp(), true)
		eq(count(replacement_calls, 'set_pdn_type'), 0)
		eq(count(replacement_calls, 'restart'), 1)
	end)
end

function tests.test_pdp_owner_replacement_reconciles_reserved_correction_as_not_dispatched()
	runfibers.run(function()
		local svc = { obs_log = function() end }
		local old = fixture({}, { svc = svc })
		local scope_state = assert(old:_begin_pdp_operation('IP'))
		scope_state.cids['7'] = {
			corrections = 1,
			inflight = { owner_generation = old.pdp_owner_generation, stage = 'reserved' },
		}
		local replacement = fixture({}, { svc = svc })
		replacement:_claim_pdp_owner()
		local record = scope_state.cids['7']
		eq(record.last_result.outcome, 'rejected')
		eq(record.last_result.dispatched, false)
		eq(scope_state.active_episode, nil)
	end)
end

function tests.test_pdp_owner_replacement_at_restart_return_completes_without_false_stale_error()
	runfibers.run(function()
		local logs, replacement, replacement_calls = {}, nil, nil
		local contexts = { context(1, 'IPV6', true) }
		local svc = { obs_log = function(_, _, payload) logs[#logs + 1] = payload end }
		local old, old_calls = fixture(contexts, {
			svc = svc,
			call = function(method, opts)
				if method == 'set_pdn_type' then
					contexts[1].pdp_type = opts.pdp_type
				elseif method == 'restart' then
					replacement, replacement_calls = fixture(contexts, {
						svc = svc,
						call = function(replacement_method, _, subs)
							local function put_card(payload)
								for index = 1, #subs do
									if subs[index].field == 'card' and not subs[index].closed then
										subs[index].queue:put({ payload = payload })
										return
									end
								end
								error('missing active card subscription')
							end
							if replacement_method == 'enable' then
								put_card({ from = 'enabling', to = 'registered' })
							elseif replacement_method == 'connect' then
								put_card({ from = 'connecting', to = 'connected' })
								return reply(true)
							end
						end,
					})
					replacement:_claim_pdp_owner()
					return reply(true)
				end
			end,
		})
		local old_restarted, old_err = old:_configure_pdp()
		eq(old_restarted, false)
		eq(old_err, 'pdp_owner_stale')
		eq(count(old_calls, 'restart'), 1)

		local restarted, err = replacement:_configure_pdp()
		eq(restarted, false)
		eq(err, '')
		eq(count(replacement_calls, 'restart'), 0)

		prepare_autoconnect(replacement)
		replacement:_autoconnect_loop()
		eq(count(replacement_calls, 'restart'), 0)
		eq(count(replacement_calls, 'enable'), 1)
		eq(count(replacement_calls, 'connect'), 1)
		local inspect_index, enable_index, connect_index
		for index, call in ipairs(replacement_calls) do
			if call.method == 'get' and call.opts.field == 'pdp_contexts' then inspect_index = inspect_index or index end
			if call.method == 'enable' then enable_index = enable_index or index end
			if call.method == 'connect' then connect_index = connect_index or index end
		end
		assert(inspect_index < enable_index and enable_index < connect_index)
		eq(count_logs(logs, 'autoconnect_failed'), 0)
	end)
end

function tests.test_pdp_owner_replacement_after_successful_reset_reinspects_before_another_reset()
	runfibers.run(function()
		local contexts = { context(1, 'IPV6', true) }
		local svc = { obs_log = function() end }
		local replacement, replacement_calls
		local old, old_calls = fixture(contexts, {
			svc = svc,
			call = function(method, opts)
				if method == 'set_pdn_type' then
					contexts[1].pdp_type = opts.pdp_type
				elseif method == 'restart' then
					replacement, replacement_calls = fixture(contexts, { svc = svc })
					replacement:_claim_pdp_owner()
					return reply(true)
				end
			end,
		})

		local restarted, err = old:_configure_pdp()
		eq(restarted, false)
		eq(err, 'pdp_owner_stale')
		eq(count(old_calls, 'set_pdn_type'), 1)
		eq(count(old_calls, 'restart'), 1)

		-- The successful write survived the reset.  A replacement owner must inspect
		-- that fact before deciding whether another correction or reset is necessary.
		restarted, err = replacement:_configure_pdp()
		eq(restarted, false)
		eq(err, '')
		eq(count(replacement_calls, 'get'), 1)
		eq(replacement_calls[1].opts.field, 'pdp_contexts')
		eq(count(replacement_calls, 'set_pdn_type'), 0)
		eq(count(replacement_calls, 'restart'), 0)
	end)
end

function tests.test_pdp_owner_replacement_while_waiting_for_reset_transition_reinspects()
	runfibers.run(function(scope)
		local contexts = { context(1, 'IPV6', true) }
		local svc = { obs_log = function() end }
		local old, old_calls = fixture(contexts, {
			svc = svc,
			call = function(method, opts)
				if method == 'set_pdn_type' then
					contexts[1].pdp_type = opts.pdp_type
				elseif method == 'restart' then
					-- The RPC succeeds, but this owner never observes a card-state
					-- transition because ModemManager replaces it.
					return reply(true)
				end
			end,
		})
		local invocation = assert(scope:child())
		assert(invocation:spawn(function() old:_configure_pdp() end))
		while not old.pdp_restart_waiting do sleep.sleep(0.001) end
		eq(count(old_calls, 'restart'), 1)

		local replacement, replacement_calls = fixture(contexts, { svc = svc })
		replacement:_claim_pdp_owner()
		local restarted, err = replacement:_configure_pdp()
		eq(restarted, false)
		eq(err, '')
		eq(count(replacement_calls, 'get'), 1)
		eq(replacement_calls[1].opts.field, 'pdp_contexts')
		eq(count(replacement_calls, 'restart'), 0)

		invocation:cancel('owner replaced')
		eq(select(1, fibers.perform(invocation:join_op())), 'cancelled')
	end)
end

function tests.test_pdp_owner_replacement_recorrects_a_reverted_context_before_second_reset()
	runfibers.run(function()
		local contexts = { context(1, 'IPV6', true) }
		local svc = { obs_log = function() end }
		local replacement, replacement_calls
		local old, old_calls = fixture(contexts, {
			svc = svc,
			call = function(method, opts)
				if method == 'set_pdn_type' then
					contexts[1].pdp_type = opts.pdp_type
				elseif method == 'restart' then
					-- Model firmware/carrier state restoring the old definition while the
					-- ModemManager object is replaced by the reset.
					contexts[1].pdp_type = 'IPV6'
					replacement, replacement_calls = fixture(contexts, {
						svc = svc,
						call = function(replacement_method, replacement_opts)
							if replacement_method == 'set_pdn_type' then
								contexts[1].pdp_type = replacement_opts.pdp_type
							end
						end,
					})
					replacement:_claim_pdp_owner()
					return reply(true)
				end
			end,
		})

		eq(select(2, old:_configure_pdp()), 'pdp_owner_stale')
		eq(count(old_calls, 'restart'), 1)

		local restarted, err = replacement:_configure_pdp()
		eq(restarted, true)
		eq(err, '')
		eq(count(replacement_calls, 'get'), 1)
		eq(replacement_calls[1].opts.field, 'pdp_contexts')
		eq(count(replacement_calls, 'set_pdn_type'), 1)
		eq(count(replacement_calls, 'restart'), 1)

		-- A third reversion is bounded by the per-CID correction budget.
		contexts[1].pdp_type = 'IPV6'
		local third, third_calls = fixture(contexts, { svc = svc })
		third:_claim_pdp_owner()
		restarted, err = third:_configure_pdp()
		eq(restarted, false)
		eq(err, '')
		eq(count(third_calls, 'get'), 1)
		eq(count(third_calls, 'set_pdn_type'), 0)
		eq(count(third_calls, 'restart'), 0)
		local record = svc.pdp_enforcement.modems['modem-1'].types.IP.fallback.cids['1']
		eq(record.corrections, 2)
		eq(record.exhausted, true)
	end)
end

function tests.test_pdp_owner_replacement_suppresses_stale_unobserved_reset_log()
	runfibers.run(function(scope)
		local contexts, logs = { context(1, 'IPV6', true) }, {}
		local svc = { obs_log = function(_, _, payload) logs[#logs + 1] = payload end }
		local old, old_calls, _, _, old_subs = fixture(contexts, {
			svc = svc,
			call = function(method, opts)
				if method == 'set_pdn_type' then contexts[1].pdp_type = opts.pdp_type end
				if method == 'restart' then return reply(true) end
			end,
		})
		local invocation = assert(scope:child())
		local old_err
		assert(invocation:spawn(function()
			local _
			_, old_err = old:_configure_pdp()
		end))
		while not old.pdp_restart_waiting do sleep.sleep(0.001) end
		eq(count(old_calls, 'restart'), 1)

		local replacement, replacement_calls = fixture(contexts, { svc = svc })
		replacement:_claim_pdp_owner()
		contexts[1].pdp_type = 'IPV6'
		eq(replacement:_configure_pdp(), true)
		eq(count(replacement_calls, 'restart'), 1)

		-- A late subscription closure must not let the stale waiter report that
		-- the replacement owner's latest reset had an unobserved transition.
		old_subs[1].queue:put(nil)
		fibers.perform(invocation:join_op())
		eq(old_err, 'pdp_owner_stale')
		eq(count_logs(logs, 'pdp_restart_unobserved'), 0)
	end)
end

return tests
