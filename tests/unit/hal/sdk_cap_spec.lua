local busmod    = require 'bus'
local fibers    = require 'fibers'

local probe     = require 'tests.support.bus_probe'
local runfibers = require 'tests.support.run_fibers'

local cap_sdk = require 'services.hal.sdk.cap'

local T = {}

local function wait_payload(conn, topic, timeout)
	return probe.wait_payload(conn, topic, { timeout = timeout or 0.2 })
end

local function wait_until(fn, timeout, interval)
	return probe.wait_until(fn, {
		timeout = timeout or 1.0,
		interval = interval or 0.01,
	})
end

function T.cap_sdk_legacy_listener_accepts_added_on_public_state_topic()
	runfibers.run(function(scope)
		local bus      = busmod.new()
		local pub      = bus:connect()
		local client   = bus:connect()

		local listener = cap_sdk.new_cap_listener(client, 'demo', 'one')

		local got_cap, got_err
		local ok, err = scope:spawn(function()
			got_cap, got_err = listener:wait_for_cap({ timeout = 0.5 })
		end)
		assert(ok, tostring(err))

		pub:retain({ 'cap', 'demo', 'one', 'state' }, 'added')

		assert(wait_until(function()
			return got_cap ~= nil
		end, 1.0, 0.01))

		assert(got_err == '')
		assert(got_cap.class == 'demo')
		assert(got_cap.id == 'one')

		listener:close()
	end, { timeout = 2.0 })
end

function T.cap_sdk_curated_listener_accepts_available_status_payload()
	runfibers.run(function(scope)
		local bus      = busmod.new()
		local pub      = bus:connect()
		local client   = bus:connect()

		local listener = cap_sdk.new_curated_cap_listener(client, 'demo', 'one')

		local got_cap, got_err
		local ok, err = scope:spawn(function()
			got_cap, got_err = listener:wait_for_cap({ timeout = 0.5 })
		end)
		assert(ok, tostring(err))

		pub:retain({ 'cap', 'demo', 'one', 'status' }, { state = 'available', version = 1 })

		assert(wait_until(function()
			return got_cap ~= nil
		end, 1.0, 0.01))

		assert(got_err == '')
		assert(got_cap.class == 'demo')
		assert(got_cap.id == 'one')

		listener:close()
	end, { timeout = 2.0 })
end

function T.cap_sdk_curated_listener_accepts_available_true_payload()
	runfibers.run(function(scope)
		local bus      = busmod.new()
		local pub      = bus:connect()
		local client   = bus:connect()

		local listener = cap_sdk.new_curated_cap_listener(client, 'demo', 'one')

		local got_cap, got_err
		local ok, err = scope:spawn(function()
			got_cap, got_err = listener:wait_for_cap({ timeout = 0.5 })
		end)
		assert(ok, tostring(err))

		pub:retain({ 'cap', 'demo', 'one', 'status' }, { available = true })

		assert(wait_until(function()
			return got_cap ~= nil
		end, 1.0, 0.01))

		assert(got_err == '')
		assert(got_cap.class == 'demo')
		assert(got_cap.id == 'one')

		listener:close()
	end, { timeout = 2.0 })
end

function T.cap_sdk_raw_host_listener_and_ref_follow_raw_host_topics()
	runfibers.run(function(scope)
		local bus      = busmod.new()
		local pub      = bus:connect()
		local client   = bus:connect()

		local listener = cap_sdk.new_raw_host_cap_listener(client, 'platform', 'artifact-store', 'main')
		local ref      = cap_sdk.new_raw_host_cap_ref(client, 'platform', 'artifact-store', 'main')

		local got_cap, got_err
		local ok, err = scope:spawn(function()
			got_cap, got_err = listener:wait_for_cap({ timeout = 0.5 })
		end)
		assert(ok, tostring(err))

		-- Subscribe BEFORE publishing.
		local meta_sub   = ref:get_meta_sub()
		local status_sub = ref:get_status_sub()
		local state_sub  = ref:get_state_sub('mode')
		local event_sub  = ref:get_event_sub('changed')

		pub:retain(
			{ 'raw', 'host', 'platform', 'cap', 'artifact-store', 'main', 'status' },
			{ state = 'available' }
		)

		assert(wait_until(function()
			return got_cap ~= nil
		end, 1.0, 0.01))

		assert(got_err == '')
		assert(got_cap.class == 'artifact-store')
		assert(got_cap.id == 'main')

		pub:retain(
			{ 'raw', 'host', 'platform', 'cap', 'artifact-store', 'main', 'meta' },
			{ provider = 'hal' }
		)
		pub:retain(
			{ 'raw', 'host', 'platform', 'cap', 'artifact-store', 'main', 'state', 'mode' },
			'ready'
		)
		pub:publish(
			{ 'raw', 'host', 'platform', 'cap', 'artifact-store', 'main', 'event', 'changed' },
			{ what = 'mode' }
		)

		local status_ev, err1 = status_sub:recv()
		assert(status_ev, tostring(err1))
		assert(type(status_ev.payload) == 'table')
		assert(status_ev.payload.state == 'available')

		local meta_ev, err2 = meta_sub:recv()
		assert(meta_ev, tostring(err2))
		assert(type(meta_ev.payload) == 'table')
		assert(meta_ev.payload.provider == 'hal')

		local state_ev, err3 = state_sub:recv()
		assert(state_ev, tostring(err3))
		assert(state_ev.payload == 'ready')

		local event_ev, err4 = event_sub:recv()
		assert(event_ev, tostring(err4))
		assert(type(event_ev.payload) == 'table')
		assert(event_ev.payload.what == 'mode')

		meta_sub:unsubscribe()
		status_sub:unsubscribe()
		state_sub:unsubscribe()
		event_sub:unsubscribe()
		listener:close()
	end, { timeout = 2.0 })
end

function T.cap_sdk_raw_member_listener_and_ref_follow_raw_member_topics()
	runfibers.run(function(scope)
		local bus      = busmod.new()
		local pub      = bus:connect()
		local client   = bus:connect()

		local listener = cap_sdk.new_raw_member_cap_listener(client, 'mcu', 'updater', 'main')
		local ref      = cap_sdk.new_raw_member_cap_ref(client, 'mcu', 'updater', 'main')

		local got_cap, got_err
		local ok, err = scope:spawn(function()
			got_cap, got_err = listener:wait_for_cap({ timeout = 0.5 })
		end)
		assert(ok, tostring(err))

		-- Subscribe BEFORE publishing.
		local meta_sub   = ref:get_meta_sub()
		local status_sub = ref:get_status_sub()
		local state_sub  = ref:get_state_sub('version')
		local event_sub  = ref:get_event_sub('ready')

		pub:retain(
			{ 'raw', 'member', 'mcu', 'cap', 'updater', 'main', 'status' },
			{ state = 'available' }
		)

		assert(wait_until(function()
			return got_cap ~= nil
		end, 1.0, 0.01))

		assert(got_err == '')
		assert(got_cap.class == 'updater')
		assert(got_cap.id == 'main')

		pub:retain(
			{ 'raw', 'member', 'mcu', 'cap', 'updater', 'main', 'meta' },
			{ backing = 'rp2350' }
		)
		pub:retain(
			{ 'raw', 'member', 'mcu', 'cap', 'updater', 'main', 'state', 'version' },
			'1.2.3'
		)
		pub:publish(
			{ 'raw', 'member', 'mcu', 'cap', 'updater', 'main', 'event', 'ready' },
			{ ok = true }
		)

		local status_ev, err1 = status_sub:recv()
		assert(status_ev, tostring(err1))
		assert(type(status_ev.payload) == 'table')
		assert(status_ev.payload.state == 'available')

		local meta_ev, err2 = meta_sub:recv()
		assert(meta_ev, tostring(err2))
		assert(type(meta_ev.payload) == 'table')
		assert(meta_ev.payload.backing == 'rp2350')

		local state_ev, err3 = state_sub:recv()
		assert(state_ev, tostring(err3))
		assert(state_ev.payload == '1.2.3')

		local event_ev, err4 = event_sub:recv()
		assert(event_ev, tostring(err4))
		assert(type(event_ev.payload) == 'table')
		assert(event_ev.payload.ok == true)

		meta_sub:unsubscribe()
		status_sub:unsubscribe()
		state_sub:unsubscribe()
		event_sub:unsubscribe()
		listener:close()
	end, { timeout = 2.0 })
end

return T
