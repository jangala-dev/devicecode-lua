local busmod       = require 'bus'
local fibers       = require 'fibers'
local sleep        = require 'fibers.sleep'
local op           = require 'fibers.op'
local runfibers    = require 'tests.support.run_fibers'
local fake_hal_mod = require 'tests.support.fake_hal'
local cap_sdk      = require 'services.hal.sdk.cap'

local T = {}

local function topic_eq(a, b)
	if type(a) ~= 'table' or type(b) ~= 'table' or #a ~= #b then
		return false
	end
	for i = 1, #a do
		if a[i] ~= b[i] then return false end
	end
	return true
end

function T.legacy_cap_listener_retains_sync_wrappers()
	runfibers.run(function()
		local bus = busmod.new()
		fake_hal_mod.new({
			caps = { read_state = true },
			scripted = {
				read_state = {
					{ ok = true, found = true, data = '{"hello":true}' },
				},
			},
		}):start(bus:connect(), { name = 'hal' })

		local listener = cap_sdk.new_cap_listener(bus:connect(), 'fs', 'config')
		assert(type(listener.wait_for_cap) == 'function')

		local ref, err = listener:wait_for_cap({ timeout = 0.5 })
		assert(ref, tostring(err))
		assert(type(ref.call_control) == 'function')

		local opts, opts_err = cap_sdk.args.new.FilesystemReadOpts('services.json')
		assert(opts, tostring(opts_err))

		local reply, call_err = ref:call_control('read', opts)
		assert(reply, tostring(call_err))
		assert(reply.ok == true)
		assert(reply.reason == '{"hello":true}')
	end)
end

function T.curated_cap_listener_is_op_only_and_composes()
	runfibers.run(function()
		local bus = busmod.new()
		fake_hal_mod.new({
			caps = { read_state = true },
			scripted = {
				read_state = {
					{ ok = true, found = true, data = '{"x":1}' },
				},
			},
		}):start(bus:connect(), { name = 'hal' })

		local listener = cap_sdk.new_curated_cap_listener(bus:connect(), 'fs', 'config')
		assert(listener.wait_for_cap == nil)

		local which, ref, err = fibers.perform(fibers.named_choice{
			cap     = listener:wait_for_cap_op(),
			timeout = sleep.sleep_op(0.5),
		})
		assert(which == 'cap', tostring(err))
		assert(ref ~= nil)
		assert(ref.call_control == nil)

		local opts, opts_err = cap_sdk.args.new.FilesystemReadOpts('services.json')
		assert(opts, tostring(opts_err))
		local reply, call_err = fibers.perform(ref:call_control_op('read', opts))
		assert(reply, tostring(call_err))
		assert(reply.ok == true)
		assert(reply.reason == '{"x":1}')
	end)
end

function T.curated_cap_listener_fails_loudly_without_mailbox_backing()
	runfibers.run(function()
		local fake_sub = {
			unsubscribe = function() end,
		}

		local listener = setmetatable({
			conn = {},
			sub = fake_sub,
			topic = { 'cap', 'fs', 'config', 'status' },
			mode = 'curated-public',
		}, getmetatable(cap_sdk.new_curated_cap_listener(busmod.new():connect(), 'fs', 'config')))

		local ok, err = pcall(function()
			fibers.perform(listener:wait_for_cap_op())
		end)
		assert(ok == false)
		assert(tostring(err):match('mailbox%-backed subscription'))
	end)
end

function T.curated_cap_listener_reports_closed_subscription()
	runfibers.run(function()
		local bus = busmod.new()
		local conn = bus:connect()
		local listener = cap_sdk.new_curated_cap_listener(conn, 'fs', 'config')
		listener:close()

		local ref, err = fibers.perform(listener:wait_for_cap_op())
		assert(ref == nil)
		assert(type(err) == 'string')
		assert(err:match('closed') or err:match('unsubscribed'))
	end)
end

function T.curated_ref_routes_meta_status_state_event_and_control_topics()
	runfibers.run(function()
		local seen = {}

		local conn = {
			subscribe = function(_, topic, opts)
				seen[#seen + 1] = { kind = 'subscribe', topic = topic, opts = opts }
				return { topic = topic }
			end,
			call_op = function(_, topic, args, opts)
				seen[#seen + 1] = { kind = 'call', topic = topic, args = args, opts = opts }
				return op.always({ ok = true }, nil)
			end,
		}

		local ref = cap_sdk.new_curated_cap_ref(conn, 'wifi', 'main')
		assert(ref.call_control == nil)

		ref:get_meta_sub()
		ref:get_status_sub()
		ref:get_state_sub('signal')
		ref:get_event_sub('changed')
		local reply, err = fibers.perform(ref:call_control_op('scan', { passive = true }))
		assert(reply, tostring(err))

		assert(topic_eq(seen[1].topic, { 'cap', 'wifi', 'main', 'meta' }))
		assert(topic_eq(seen[2].topic, { 'cap', 'wifi', 'main', 'status' }))
		assert(topic_eq(seen[3].topic, { 'cap', 'wifi', 'main', 'state', 'signal' }))
		assert(topic_eq(seen[4].topic, { 'cap', 'wifi', 'main', 'event', 'changed' }))
		assert(topic_eq(seen[5].topic, { 'cap', 'wifi', 'main', 'rpc', 'scan' }))
	end)
end

function T.raw_host_ref_routes_topics()
	runfibers.run(function()
		local seen = {}

		local conn = {
			subscribe = function(_, topic, opts)
				seen[#seen + 1] = { kind = 'subscribe', topic = topic, opts = opts }
				return { topic = topic }
			end,
			call_op = function(_, topic, args, opts)
				seen[#seen + 1] = { kind = 'call', topic = topic, args = args, opts = opts }
				return op.always({ ok = true }, nil)
			end,
		}

		local ref = cap_sdk.new_raw_host_cap_ref(conn, 'uart_main', 'uart', 'main')

		ref:get_meta_sub()
		ref:get_status_sub()
		ref:get_state_sub('baud')
		ref:get_event_sub('opened')
		local reply, err = fibers.perform(ref:call_control_op('open', { speed = 115200 }))
		assert(reply, tostring(err))

		assert(topic_eq(seen[1].topic, { 'raw', 'host', 'uart_main', 'cap', 'uart', 'main', 'meta' }))
		assert(topic_eq(seen[2].topic, { 'raw', 'host', 'uart_main', 'cap', 'uart', 'main', 'status' }))
		assert(topic_eq(seen[3].topic, { 'raw', 'host', 'uart_main', 'cap', 'uart', 'main', 'state', 'baud' }))
		assert(topic_eq(seen[4].topic, { 'raw', 'host', 'uart_main', 'cap', 'uart', 'main', 'event', 'opened' }))
		assert(topic_eq(seen[5].topic, { 'raw', 'host', 'uart_main', 'cap', 'uart', 'main', 'rpc', 'open' }))
	end)
end

function T.raw_member_ref_routes_topics()
	runfibers.run(function()
		local seen = {}

		local conn = {
			subscribe = function(_, topic, opts)
				seen[#seen + 1] = { kind = 'subscribe', topic = topic, opts = opts }
				return { topic = topic }
			end,
			call_op = function(_, topic, args, opts)
				seen[#seen + 1] = { kind = 'call', topic = topic, args = args, opts = opts }
				return op.always({ ok = true }, nil)
			end,
		}

		local ref = cap_sdk.new_raw_member_cap_ref(conn, 'member_a', 'gps', 'main')

		ref:get_meta_sub()
		ref:get_status_sub()
		ref:get_state_sub('fix')
		ref:get_event_sub('updated')
		local reply, err = fibers.perform(ref:call_control_op('poll', {}))
		assert(reply, tostring(err))

		assert(topic_eq(seen[1].topic, { 'raw', 'member', 'member_a', 'cap', 'gps', 'main', 'meta' }))
		assert(topic_eq(seen[2].topic, { 'raw', 'member', 'member_a', 'cap', 'gps', 'main', 'status' }))
		assert(topic_eq(seen[3].topic, { 'raw', 'member', 'member_a', 'cap', 'gps', 'main', 'state', 'fix' }))
		assert(topic_eq(seen[4].topic, { 'raw', 'member', 'member_a', 'cap', 'gps', 'main', 'event', 'updated' }))
		assert(topic_eq(seen[5].topic, { 'raw', 'member', 'member_a', 'cap', 'gps', 'main', 'rpc', 'poll' }))
	end)
end

function T.raw_host_listener_requires_structured_status_not_legacy_added()
	runfibers.run(function()
		local bus = busmod.new()
		local admin = bus:connect()
		local listener = cap_sdk.new_raw_host_cap_listener(bus:connect(), 'uart_main', 'uart', 'main')

		admin:retain({ 'raw', 'host', 'uart_main', 'cap', 'uart', 'main', 'status' }, 'added')

		local which = fibers.perform(op.named_choice{
			cap     = listener:wait_for_cap_op():wrap(function() return 'cap' end),
			timeout = sleep.sleep_op(0.05):wrap(function() return 'timeout' end),
		})

		assert(which == 'timeout')
		listener:close()
	end)
end

function T.raw_host_listener_accepts_structured_status()
	runfibers.run(function()
		local bus = busmod.new()
		local admin = bus:connect()
		local listener = cap_sdk.new_raw_host_cap_listener(bus:connect(), 'uart_main', 'uart', 'main')

		admin:retain({ 'raw', 'host', 'uart_main', 'cap', 'uart', 'main', 'status' }, {
			state = 'available',
			available = true,
		})

		local ref, err = fibers.perform(listener:wait_for_cap_op())
		assert(ref, tostring(err))
		assert(ref.call_control == nil)
		assert(ref.class == 'uart')
		assert(ref.id == 'main')
		assert(ref.source == 'uart_main')
		listener:close()
	end)
end

return T
