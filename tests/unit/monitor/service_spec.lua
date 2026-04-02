local busmod          = require 'bus'
local fibers          = require 'fibers'
local sleep           = require 'fibers.sleep'
local cjson           = require 'cjson'

local runfibers       = require 'tests.support.run_fibers'
local monitor_service = require 'services.monitor'

local T = {}

local function recv_with_timeout(ev, timeout_s)
	local which, a, b = fibers.perform(fibers.named_choice({
		value = ev,
		timer = sleep.sleep_op(timeout_s):wrap(function() return true end),
	}))
	return which, a, b
end

local function spawn_monitor(scope, bus)
	local ok, err = scope:spawn(function()
		monitor_service.start(bus:connect(), {
			name = 'monitor',
			env = 'dev',
		})
	end)
	assert(ok, tostring(err))
end

function T.monitor_can_publish_config_mcu_probe()
	runfibers.run(function(scope)
		local bus = busmod.new()
		local caller = bus:connect()
		local sub = caller:subscribe({ 'config', 'mcu' }, {
			queue_len = 4,
			full = 'drop_oldest',
		})

		spawn_monitor(scope, bus)
		fibers.perform(sleep.sleep_op(0.01))

		local reply, err = caller:call(
			{ 'rpc', 'monitor', 'fabric_publish_config_mcu' },
			{ payload = { mode = 'probe', answer = 42 } },
			{ timeout = 0.5 }
		)

		assert(reply ~= nil, tostring(err))
		assert(reply.ok == true)
		assert(reply.topic[1] == 'config')
		assert(reply.topic[2] == 'mcu')

		local which, msg, rerr = recv_with_timeout(sub:recv_op(), 0.5)
		assert(which == 'value', tostring(rerr))
		assert(msg ~= nil, tostring(rerr))
		assert(msg.topic[1] == 'config')
		assert(msg.topic[2] == 'mcu')
		assert(type(msg.payload) == 'table')
		assert(msg.payload.mode == 'probe')
		assert(msg.payload.answer == 42)
	end, { timeout = 1.5 })
end

function T.monitor_can_call_peer_hal_dump_probe()
	runfibers.run(function(scope)
		local bus = busmod.new()
		local caller = bus:connect()
		local peer = bus:connect()
		local ep = peer:bind({ 'rpc', 'peer', 'mcu-1', 'hal', 'dump' }, {
			queue_len = 4,
		})

		local ok_peer, perr = scope:spawn(function()
			local which, msg, err = recv_with_timeout(ep:recv_op(), 0.5)
			assert(which == 'value', tostring(err))
			assert(msg ~= nil, tostring(err))
			assert(type(msg.payload) == 'table')
			assert(msg.payload.ask == 'status')
			local ok, reason = peer:publish_one(msg.reply_to, {
				ok = true,
				source = 'peer-hal-dump',
			}, {
				id = msg.id,
			})
			assert(ok == true, tostring(reason))
		end)
		assert(ok_peer, tostring(perr))

		spawn_monitor(scope, bus)
		fibers.perform(sleep.sleep_op(0.01))

		local reply, err = caller:call(
			{ 'rpc', 'monitor', 'fabric_dump_peer_hal' },
			{ payload = { ask = 'status' }, timeout_s = 0.5 },
			{ timeout = 0.75 }
		)

		assert(reply ~= nil, tostring(err))
		assert(reply.ok == true)
		assert(reply.peer_id == 'mcu-1')
		assert(type(reply.reply) == 'table')
		assert(reply.reply.ok == true)
		assert(reply.reply.source == 'peer-hal-dump')
	end, { timeout = 1.5 })
end

function T.monitor_auto_probes_when_fabric_link_becomes_ready()
	runfibers.run(function(scope)
		local bus = busmod.new()
		local feeder = bus:connect()
		local watcher = bus:connect()
		local peer = bus:connect()

		local sub_cfg = watcher:subscribe({ 'config', 'mcu' }, {
			queue_len = 4,
			full = 'drop_oldest',
		})
		local sub_dump = watcher:subscribe({ 'obs', 'event', 'monitor', 'fabric_auto_probe_dump' }, {
			queue_len = 4,
			full = 'drop_oldest',
		})
		local ep = peer:bind({ 'rpc', 'peer', 'mcu-1', 'hal', 'dump' }, {
			queue_len = 4,
		})

		local ok_peer, perr = scope:spawn(function()
			for attempt = 1, 2 do
				local which, msg, err = recv_with_timeout(ep:recv_op(), 2.0)
				assert(which == 'value', tostring(err))
				assert(msg ~= nil, tostring(err))
				assert(type(msg.payload) == 'table')
				assert(msg.payload.source == 'monitor_auto_probe')
				local ok, reason = peer:publish_one(msg.reply_to, {
					ok = true,
					applied = (attempt >= 2),
					config_count = (attempt >= 2) and 1 or 0,
					source = 'auto-probe-reply',
				}, {
					id = msg.id,
				})
				assert(ok == true, tostring(reason))
			end
		end)
		assert(ok_peer, tostring(perr))

		spawn_monitor(scope, bus)
		fibers.perform(sleep.sleep_op(0.01))

		feeder:retain({ 'state', 'fabric', 'link', 'mcu0' }, {
			link_id = 'mcu0',
			peer_id = 'mcu-1',
			peer_sid = 'peer-sid-1',
			ready = true,
		})

		local which_cfg, msg_cfg, err_cfg = recv_with_timeout(sub_cfg:recv_op(), 2.0)
		assert(which_cfg == 'value', tostring(err_cfg))
		assert(msg_cfg ~= nil, tostring(err_cfg))
		assert(type(msg_cfg.payload) == 'table')
		assert(type(msg_cfg.payload.devices) == 'table')
		assert(#msg_cfg.payload.devices == 0)
		assert(type(msg_cfg.payload.pollers) == 'table')
		assert(#msg_cfg.payload.pollers == 0)
		local encoded = cjson.encode(msg_cfg.payload)
		assert(encoded == '{"devices":[],"pollers":[]}' or encoded == '{"pollers":[],"devices":[]}')

		local which_dump, msg_dump, err_dump = recv_with_timeout(sub_dump:recv_op(), 3.5)
		assert(which_dump == 'value', tostring(err_dump))
		assert(msg_dump ~= nil, tostring(err_dump))
		assert(type(msg_dump.payload) == 'table')
		assert(msg_dump.payload.ok == true)
		assert(msg_dump.payload.attempts == 2)
		assert(type(msg_dump.payload.reply) == 'table')
		assert(msg_dump.payload.reply.applied == true)
		assert(msg_dump.payload.reply.config_count == 1)
	end, { timeout = 4.0 })
end

return T
