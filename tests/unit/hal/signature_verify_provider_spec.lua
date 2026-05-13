local fibers     = require 'fibers'
local op         = require 'fibers.op'
local sleep      = require 'fibers.sleep'
local channel    = require 'fibers.channel'

local runfibers  = require 'tests.support.run_fibers'
local core_types = require 'services.hal.types.core'
local cap_args   = require 'services.hal.types.capability_args'

local provider_mod = require 'services.hal.drivers.signature_verify_provider'

local T = {}

local function recv_or_fail(ch)
	local v, err = fibers.perform(ch:get_op())
	assert(v, tostring(err))
	return v
end

local function fake_backend(result_ok, result_value, extra)
	extra = extra or {}

	return {
		backend_name = extra.backend_name or 'fake-backend',

		verify_ed25519_op = function(_self, pubkey_pem, message, signature)
			if extra.observe then
				extra.observe[#extra.observe + 1] = {
					pubkey_pem = pubkey_pem,
					message    = message,
					signature  = signature,
				}
			end
			return op.always(result_ok, result_value)
		end,
	}
end

local function request(driver, verb, opts)
	local reply_ch = channel.new(1)
	local req, err = core_types.new.ControlRequest(verb, opts or {}, reply_ch)
	assert(req, tostring(err))

	local sent, send_err = fibers.perform(driver.control_ch:put_op(req))
	assert(sent ~= false, tostring(send_err))

	local reply, recv_err = fibers.perform(reply_ch:get_op())
	assert(reply, tostring(recv_err))
	return reply
end

function T.capabilities_op_returns_signature_verify_capability()
	runfibers.run(function()
		local emit_ch = channel.new(8)
		local driver = provider_mod.new('main', {
			backend = fake_backend(true, nil),
		}, nil)

		local ok, caps_or_err = fibers.perform(driver:capabilities_op(emit_ch))
		assert(ok == true, tostring(caps_or_err))
		assert(type(caps_or_err) == 'table')
		assert(#caps_or_err == 1)

		local cap = caps_or_err[1]
		assert(cap.class == 'signature_verify')
		assert(cap.id == 'main')
		assert(cap.offerings.verify_ed25519 == true)
	end)
end

function T.start_op_emits_initial_meta_and_available_state()
	runfibers.run(function(scope)
		local emit_ch = channel.new(8)
		local driver = provider_mod.new('main', {
			backend = fake_backend(true, nil, { backend_name = 'fake-sig' }),
			max_in_flight = 2,
		}, nil)

		local ok_caps, caps_err = fibers.perform(driver:capabilities_op(emit_ch))
		assert(ok_caps == true, tostring(caps_err))

		local ok_start, start_err = fibers.perform(driver:start_op(scope))
		assert(ok_start == true, tostring(start_err))

		local e1 = recv_or_fail(emit_ch)
		local e2 = recv_or_fail(emit_ch)

		local by_mode = {
			[e1.mode] = e1,
			[e2.mode] = e2,
		}

		assert(by_mode.meta ~= nil)
		assert(by_mode.state ~= nil)

		assert(by_mode.meta.class == 'signature_verify')
		assert(by_mode.meta.id == 'main')
		assert(by_mode.meta.key == 'info')
		assert(by_mode.meta.data.backend == 'fake-sig')
		assert(by_mode.meta.data.max_in_flight == 2)

		assert(by_mode.state.key == 'status')
		assert(by_mode.state.data.state == 'available')

		local ok_stop, stop_err = fibers.perform(driver:shutdown_op())
		assert(ok_stop == true, tostring(stop_err))
	end)
end

function T.verify_ed25519_request_round_trips_success()
	runfibers.run(function(scope)
		local seen = {}
		local emit_ch = channel.new(8)
		local driver = provider_mod.new('main', {
			backend = fake_backend(true, { verified = true }, { observe = seen }),
		}, nil)

		local ok_caps, caps_err = fibers.perform(driver:capabilities_op(emit_ch))
		assert(ok_caps == true, tostring(caps_err))

		local ok_start, start_err = fibers.perform(driver:start_op(scope))
		assert(ok_start == true, tostring(start_err))

		local opts, opts_err = cap_args.new.SignatureVerifyEd25519Opts(
			'PUBKEY',
			'MESSAGE',
			'SIGNATURE'
		)
		assert(opts, tostring(opts_err))

		local reply = request(driver, 'verify_ed25519', opts)
		assert(reply.ok == true)
		assert(type(reply.reason) == 'table')
		assert(reply.reason.verified == true)

		assert(#seen == 1)
		assert(seen[1].pubkey_pem == 'PUBKEY')
		assert(seen[1].message == 'MESSAGE')
		assert(seen[1].signature == 'SIGNATURE')

		local ok_stop, stop_err = fibers.perform(driver:shutdown_op())
		assert(ok_stop == true, tostring(stop_err))
	end)
end

function T.busy_is_returned_when_max_in_flight_reached()
	runfibers.run(function(scope)
		local gate = channel.new(1)

		local backend = {
			backend_name = 'gated',

			verify_ed25519_op = function()
				return gate:get_op():wrap(function(token)
					return true, token
				end)
			end,
		}

		local emit_ch = channel.new(8)
		local driver = provider_mod.new('main', {
			backend = backend,
			max_in_flight = 1,
		}, nil)

		local ok_caps, caps_err = fibers.perform(driver:capabilities_op(emit_ch))
		assert(ok_caps == true, tostring(caps_err))

		local ok_start, start_err = fibers.perform(driver:start_op(scope))
		assert(ok_start == true, tostring(start_err))

		local opts, opts_err = cap_args.new.SignatureVerifyEd25519Opts(
			'PUBKEY',
			'MESSAGE',
			'SIGNATURE'
		)
		assert(opts, tostring(opts_err))

		local first_reply_ch = channel.new(1)
		local req1, req1_err = core_types.new.ControlRequest('verify_ed25519', opts, first_reply_ch)
		assert(req1, tostring(req1_err))

		local sent1, send1_err = fibers.perform(driver.control_ch:put_op(req1))
		assert(sent1 ~= false, tostring(send1_err))

		fibers.perform(sleep.sleep_op(0.01))

		local reply2 = request(driver, 'verify_ed25519', opts)
		assert(reply2.ok == false)
		assert(reply2.reason == 'busy')

		local gate_sent, gate_err = fibers.perform(gate:put_op('done'))
		assert(gate_sent ~= false, tostring(gate_err))

		local reply1, recv1_err = fibers.perform(first_reply_ch:get_op())
		assert(reply1, tostring(recv1_err))
		assert(reply1.ok == true)
		assert(reply1.reason == 'done')

		local ok_stop, stop_err = fibers.perform(driver:shutdown_op())
		assert(ok_stop == true, tostring(stop_err))
	end)
end

function T.unsupported_verb_returns_negative_reply()
	runfibers.run(function(scope)
		local emit_ch = channel.new(8)
		local driver = provider_mod.new('main', {
			backend = fake_backend(true, nil),
		}, nil)

		local ok_caps, caps_err = fibers.perform(driver:capabilities_op(emit_ch))
		assert(ok_caps == true, tostring(caps_err))

		local ok_start, start_err = fibers.perform(driver:start_op(scope))
		assert(ok_start == true, tostring(start_err))

		local reply = request(driver, 'nope', {})
		assert(reply.ok == false)
		assert(tostring(reply.reason):match('unsupported verb'))

		local ok_stop, stop_err = fibers.perform(driver:shutdown_op())
		assert(ok_stop == true, tostring(stop_err))
	end)
end

function T.shutdown_op_before_start_is_ok_and_fault_op_is_inert()
	runfibers.run(function()
		local driver = provider_mod.new('main', {
			backend = fake_backend(true, nil),
		}, nil)

		local ok_stop, stop_err = fibers.perform(driver:shutdown_op())
		assert(ok_stop == true, tostring(stop_err))

		local which = fibers.perform(fibers.named_choice{
			fault   = driver:fault_op():wrap(function(...) return 'fault', ... end),
			timeout = sleep.sleep_op(0.05):wrap(function() return 'timeout' end),
		})
		assert(which == 'timeout')
	end)
end

return T
