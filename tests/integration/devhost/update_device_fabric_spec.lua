local busmod      = require 'bus'
local duplex      = require 'tests.support.duplex_stream'
local probe       = require 'tests.support.bus_probe'
local runfibers   = require 'tests.support.run_fibers'
local safe        = require 'coxpcall'
local mailbox     = require 'fibers.mailbox'
local fibers      = require 'fibers'
local sleep_mod   = require 'fibers.sleep'
local storagecaps = require 'tests.support.storage_caps'

local session = require 'services.fabric.session'
local device  = require 'services.device'
local update  = require 'services.update'

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
			return probe.wait_payload(conn, { 'state', 'fabric', 'link', link_id, 'session' }, { timeout = 0.02 })
		end)
		return ok and type(payload) == 'table'
			and type(payload.status) == 'table'
			and payload.status.ready == true
	end, { timeout = timeout or 1.5, interval = 0.01 })
end

local function bind_reply_loop(scope, ep, handler)
	local ok, err = scope:spawn(function()
		while true do
			local req = ep:recv()
			if not req then return end
			local reply, ferr = handler(req.payload or {}, req)
			if reply == nil then req:fail(ferr or 'failed') else req:reply(reply) end
		end
	end)
	assert(ok, tostring(err))
end

local function wait_retained_state(conn, topic, pred, timeout)
    return probe.wait_until(function()
        local ok, payload = safe.pcall(function()
            return probe.wait_payload(conn, topic, { timeout = 0.02 })
        end)
        return ok and pred(payload)
    end, { timeout = timeout or 1.0, interval = 0.01 })
end

function T.devhost_update_flows_via_device_over_fabric_to_remote_mcu_member()
	runfibers.run(function(scope)
		local orig_sleep = sleep_mod.sleep
		sleep_mod.sleep = function(dt)
			return orig_sleep(math.min(dt, 0.01))
		end
		fibers.current_scope():finally(function()
			sleep_mod.sleep = orig_sleep
		end)

		local bus = busmod.new()
		local caller = bus:connect()
		local control = storagecaps.start_control_store_cap(scope, bus:connect(), {})
		local artifacts = storagecaps.start_artifact_store_cap(scope, bus:connect(), {})
		local seed = bus:connect()

		seed:retain({ 'cfg', 'device' }, {
			schema = 'devicecode.config/device/1',
			components = {
				mcu = {
					class = 'member',
					subtype = 'mcu',
					status_topic = { 'imported', 'member', 'mcu', 'status' },
					get_topic = { 'rpc', 'member', 'mcu', 'status' },
					actions = {
						prepare_update = { 'rpc', 'member', 'mcu', 'prepare' },
						stage_update = { 'rpc', 'member', 'mcu', 'stage' },
						commit_update = { 'rpc', 'member', 'mcu', 'commit' },
					},
				},
			},
		})

		local a_stream, b_stream = duplex.new_pair()
		local a_ctl_tx, a_ctl_rx = mailbox.new(8, { full = 'reject_newest' })
		local b_ctl_tx, b_ctl_rx = mailbox.new(8, { full = 'reject_newest' })
		local a_report_tx, a_report_rx = mailbox.new(8, { full = 'reject_newest' })
		local b_report_tx, b_report_rx = mailbox.new(8, { full = 'reject_newest' })

		local versions = { mcu = 'mcu-v0' }
		local incarnation = { mcu = 1 }
		local remote_member_conn = bus:connect()

		local function publish_remote_status()
			remote_member_conn:publish({ 'member', 'mcu', 'status' }, {
				version = versions.mcu,
				state = 'running',
				incarnation = incarnation.mcu,
			})
		end

		local status_ep = remote_member_conn:bind({ 'rpc', 'member', 'mcu', 'status' }, { queue_len = 16 })
		local prepare_ep = remote_member_conn:bind({ 'rpc', 'member', 'mcu', 'prepare' }, { queue_len = 16 })
		local stage_ep = remote_member_conn:bind({ 'rpc', 'member', 'mcu', 'stage' }, { queue_len = 16 })
		local commit_ep = remote_member_conn:bind({ 'rpc', 'member', 'mcu', 'commit' }, { queue_len = 16 })

		bind_reply_loop(scope, status_ep, function()
			return { version = versions.mcu, state = 'running', incarnation = incarnation.mcu }
		end)
		bind_reply_loop(scope, prepare_ep, function(payload)
			return { ok = true, prepared = true }
		end)
		bind_reply_loop(scope, stage_ep, function(payload)
			assert(type(payload.artifact_ref) == 'string')
			return { ok = true, staged = payload.artifact_ref, expected_version = payload.expected_version }
		end)
		bind_reply_loop(scope, commit_ep, function(payload)
			versions.mcu = payload.metadata and payload.metadata.next_version or 'mcu-v1'
			incarnation.mcu = incarnation.mcu + 1
			publish_remote_status()
			return { ok = true, started = true }
		end)

		local ok1, err1 = scope:spawn(function()
			session.run({
				svc = make_svc(bus:connect()),
				conn = bus:connect(),
				link_id = 'cm5-uart-mcu',
				transfer_ctl_rx = a_ctl_rx,
				report_tx = a_report_tx,
				cfg = {
					node_id = 'cm5',
					member_class = 'cm5',
					link_class = 'member_uart',
					transport = { open = function() return a_stream end },
					import_rules = {
						{ ['local'] = { 'imported', 'member', 'mcu', 'status' }, ['remote'] = { 'remote', 'member', 'mcu', 'status' } },
					},
					outbound_call_rules = {
						{ ['local'] = { 'rpc', 'member', 'mcu' }, ['remote'] = { 'rpc', 'member', 'mcu' }, timeout = 1.0 },
					},
				},
			})
		end)
		assert(ok1, tostring(err1))

		local ok2, err2 = scope:spawn(function()
			session.run({
				svc = make_svc(bus:connect()),
				conn = bus:connect(),
				link_id = 'mcu-uart-cm5',
				transfer_ctl_rx = b_ctl_rx,
				report_tx = b_report_tx,
				cfg = {
					node_id = 'mcu',
					member_class = 'mcu',
					link_class = 'member_uart',
					transport = { open = function() return b_stream end },
					export_publish_rules = {
						{ ['local'] = { 'member', 'mcu', 'status' }, ['remote'] = { 'remote', 'member', 'mcu', 'status' } },
					},
					inbound_call_rules = {
						{ ['local'] = { 'rpc', 'member', 'mcu' }, ['remote'] = { 'rpc', 'member', 'mcu' }, timeout = 1.0 },
					},
				},
			})
		end)
		assert(ok2, tostring(err2))

		local ok3, err3 = scope:spawn(function()
			device.start(bus:connect(), { name = 'device', env = 'dev' })
		end)
		assert(ok3, tostring(err3))

		local ok4, err4 = scope:spawn(function()
			update.start(bus:connect(), { name = 'update', env = 'dev' })
		end)
		assert(ok4, tostring(err4))

		assert(wait_ready(caller, 'cm5-uart-mcu', 2.0) == true)
		assert(wait_ready(caller, 'mcu-uart-cm5', 2.0) == true)

		publish_remote_status()

		local created, cerr = caller:call({ 'cmd', 'update', 'job', 'create' }, {
			component = 'mcu',
			artifact_data = 'mcu-image-v1',
			expected_version = 'mcu-v1',
			metadata = { channel = 'test', next_version = 'mcu-v1' },
		}, { timeout = 0.5 })
		assert(cerr == nil)
		assert(created.ok == true)
		local job = created.job
		assert(type(job.artifact.ref) == 'string')

		assert(type(job) == 'table')
		assert(job.lifecycle.state == 'created')
		assert(type(job.artifact.ref) == 'string')

		local started, serr = caller:call({ 'cmd', 'update', 'job', 'start' }, { job_id = job.job_id }, { timeout = 0.5 })
		assert(serr == nil)
		assert(started.ok == true)

		assert(wait_retained_state(caller, { 'state', 'update', 'jobs', job.job_id }, function(payload)
			return type(payload) == 'table' and type(payload.job) == 'table' and payload.job.lifecycle.state == 'awaiting_commit'
				and payload.job.artifact.ref == nil and payload.job.artifact.released_at ~= nil
		end, 0.75))
		assert(next(artifacts.artifacts) == nil)

		local committed, perr = caller:call({ 'cmd', 'update', 'job', 'commit' }, { job_id = job.job_id }, { timeout = 1.0 })
		assert(perr == nil)
		assert(committed.ok == true)

		assert(probe.wait_until(function()
			local ok, payload = safe.pcall(function()
				return probe.wait_payload(caller, { 'state', 'update', 'jobs', job.job_id }, { timeout = 0.02 })
			end)
			return ok and type(payload) == 'table'
				and type(payload.job) == 'table'
				and payload.job.lifecycle.state == 'succeeded'
		end, { timeout = 1.5, interval = 0.01 }))

		local final, ferr = caller:call({ 'cmd', 'update', 'job', 'get' }, { job_id = job.job_id }, { timeout = 0.5 })
		assert(ferr == nil)
		assert(final.ok == true)
		assert(final.job.lifecycle.state == 'succeeded')
		assert(type(final.job.result) == 'table')
		assert(final.job.result.version == 'mcu-v1')
		assert(type(control.namespaces['update/jobs'][job.job_id]) == 'table')
	end, { timeout = 4.0 })
end

return T
