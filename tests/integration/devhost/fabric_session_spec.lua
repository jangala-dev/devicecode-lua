local busmod     = require 'bus'
local duplex     = require 'tests.support.duplex_stream'
local probe      = require 'tests.support.bus_probe'
local runfibers  = require 'tests.support.run_fibers'
local safe       = require 'coxpcall'

local session    = require 'services.fabric.session'

local T = {}

local function make_svc(conn)
	return {
		conn = conn,
		now = function() return require('fibers').now() end,
		wall = function() return 'now' end,
		obs_log = function() end,
		obs_event = function() end,
		obs_state = function() end,
		status = function() end,
	}
end

local function wait_ready(conn, link_id, timeout)
	return probe.wait_until(function()
		local ok, payload = safe.pcall(function()
			return probe.wait_payload(conn, { 'state', 'fabric', 'link', link_id }, { timeout = 0.02 })
		end)
		return ok and type(payload) == 'table' and payload.ready == true
	end, { timeout = timeout or 1.5, interval = 0.01 })
end

function T.devhost_sessions_bridge_publish_and_rpc_over_duplex_streams()
	runfibers.run(function(scope)
		local bus = busmod.new()
		local conn = bus:connect()

		local a_stream, b_stream = duplex.new_pair()
		local a_ctl_tx, a_ctl_rx = require('fibers.mailbox').new(8, { full = 'reject_newest' })
		local b_ctl_tx, b_ctl_rx = require('fibers.mailbox').new(8, { full = 'reject_newest' })

		local ok1, err1 = scope:spawn(function()
			session.run({
				svc = make_svc(bus:connect()),
				conn = bus:connect(),
				link_id = 'link-a',
				transfer_ctl_rx = a_ctl_rx,
				cfg = {
					node_id = 'node-a',
					transport = { open = function() return a_stream end },
					export_publish_rules = {
						{ ['local'] = { 'local' }, ['remote'] = { 'remote' } },
					},
					import_rules = {
						{ ['local'] = { 'seen' }, ['remote'] = { 'seen' } },
					},
					outbound_call_rules = {
						{ ['local'] = { 'rpc', 'proxy', 'echo' }, ['remote'] = { 'rpc', 'remote', 'echo' }, timeout = 1.0 },
					},
					inbound_call_rules = {
						{ ['local'] = { 'rpc', 'svc', 'echo' }, ['remote'] = { 'rpc', 'svc', 'echo' }, timeout = 1.0 },
					},
				},
			})
		end)
		assert(ok1, tostring(err1))

		local ok2, err2 = scope:spawn(function()
			session.run({
				svc = make_svc(bus:connect()),
				conn = bus:connect(),
				link_id = 'link-b',
				transfer_ctl_rx = b_ctl_rx,
				cfg = {
					node_id = 'node-b',
					transport = { open = function() return b_stream end },
					export_publish_rules = {
						{ ['local'] = { 'local' }, ['remote'] = { 'seen' } },
					},
					import_rules = {
						{ ['local'] = { 'seen' }, ['remote'] = { 'remote' } },
					},
					outbound_call_rules = {},
					inbound_call_rules = {
						{ ['local'] = { 'rpc', 'svc', 'echo' }, ['remote'] = { 'rpc', 'remote', 'echo' }, timeout = 1.0 },
					},
				},
			})
		end)
		assert(ok2, tostring(err2))

		local rpc_conn = bus:connect()
		local ep = rpc_conn:bind({ 'rpc', 'svc', 'echo' }, { queue_len = 8 })
		local ok3, err3 = scope:spawn(function()
			while true do
				local req = ep:recv()
				if not req then return end
				req:reply({ echoed = req.payload, from = 'local-echo' })
			end
		end)
		assert(ok3, tostring(err3))

		assert(wait_ready(conn, 'link-a', 2.0) == true)
		assert(wait_ready(conn, 'link-b', 2.0) == true)

		conn:publish({ 'local', 'wifi' }, { up = true })
		local seen = probe.wait_payload(conn, { 'seen', 'wifi' }, { timeout = 1.0 })
		assert(type(seen) == 'table')
		assert(seen.up == true)

		local reply, cerr = conn:call({ 'rpc', 'proxy', 'echo' }, { msg = 'hello' }, { timeout = 1.0 })
		assert(reply ~= nil, tostring(cerr))
		assert(type(reply.echoed) == 'table')
		assert(reply.echoed.msg == 'hello')
		assert(reply.from == 'local-echo')
	end, { timeout = 3.0 })
end

return T
