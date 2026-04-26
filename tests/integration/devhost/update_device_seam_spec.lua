local safe         = require 'coxpcall'
local busmod       = require 'bus'
local mailbox      = require 'fibers.mailbox'
local fibers       = require 'fibers'
local sleep_mod    = require 'fibers.sleep'

local session      = require 'services.fabric.session'
local device       = require 'services.device'
local update       = require 'services.update'

local duplex       = require 'tests.support.duplex_stream'
local probe        = require 'tests.support.bus_probe'
local runfibers    = require 'tests.support.run_fibers'
local update_preflight = require 'tests.support.update_preflight'
local storagecaps  = require 'tests.support.storage_caps'

local T = {}

local function install_fake_mcu_preflight(extra)
	local restore = update_preflight.install_fake_mcu_preflight(extra)
	fibers.current_scope():finally(restore)
end

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

local function bind_reply_loop(scope, ep, handler)
	local ok, err = scope:spawn(function()
		while true do
			local req = ep:recv()
			if not req then return end

			local reply, ferr = handler(req.payload or {}, req)
			if reply == nil then
				if ferr == '__forwarded__' then
					-- transfer manager will answer later
				else
					req:fail(ferr or 'failed')
				end
			else
				req:reply(reply)
			end
		end
	end)
	assert(ok, tostring(err))
end

local function spawn_transfer_endpoint(scope, conn, topic, transfer_ctl_tx)
	local ep = conn:bind(topic, { queue_len = 16 })
	bind_reply_loop(scope, ep, function(_payload, req)
		local ok, reason = transfer_ctl_tx:send(req)
		if ok ~= true then
			return nil, reason or 'queue_closed'
		end
		return nil, '__forwarded__'
	end)
end

local function wait_retained_state(conn, topic, pred, timeout)
	return probe.wait_until(function()
		local ok, payload = safe.pcall(function()
			return probe.wait_payload(conn, topic, { timeout = 0.02 })
		end)
		return ok and pred(payload)
	end, { timeout = timeout or 1.0, interval = 0.01 })
end

local function wait_service_running(conn, name, timeout)
	return wait_retained_state(conn, { 'svc', name, 'status' }, function(payload)
		return type(payload) == 'table' and payload.state == 'running' and payload.ready == true
	end, timeout or 1.5)
end

local function wait_ready(conn, link_id, timeout)
	return probe.wait_until(function()
		local ok, payload = safe.pcall(function()
			return probe.wait_payload(conn, { 'state', 'fabric', 'link', link_id, 'session' }, { timeout = 0.02 })
		end)
		return ok
			and type(payload) == 'table'
			and type(payload.status) == 'table'
			and payload.status.ready == true
	end, { timeout = timeout or 1.5, interval = 0.01 })
end

local function wait_device_component(conn, name, pred, timeout)
	return wait_retained_state(conn, { 'state', 'device', 'component', name }, function(payload)
		return type(payload) == 'table' and pred(payload)
	end, timeout or 1.5)
end

function T.devhost_update_uses_device_seam_even_when_member_topics_are_remapped()
	runfibers.run(function(scope)
		install_fake_mcu_preflight({ version = 'mcu-v1', image_id = 'mcu-image-1' })
		local orig_sleep = sleep_mod.sleep
		sleep_mod.sleep = function(dt)
			return orig_sleep(math.min(dt, 0.01))
		end
		fibers.current_scope():finally(function()
			sleep_mod.sleep = orig_sleep
		end)

		local bus = busmod.new()
		local caller = bus:connect()
		local seed = bus:connect()
		local control = storagecaps.start_control_store_cap(scope, bus:connect(), {})
		local artifacts = storagecaps.start_artifact_store_cap(scope, bus:connect(), {})

		seed:retain({ 'cfg', 'update' }, {
			schema = 'devicecode.config/update/1',
			components = {
				mcu = {
					backend = 'mcu_component',
					transfer = {
						link_id = 'cm5-uart-mcu',
						receiver = { 'rpc', 'member', 'mcu', 'receive' },
						timeout_s = 1.0,
					},
				},
			},
		})

		seed:retain({ 'cfg', 'device' }, {
			schema = 'devicecode.config/device/1',
			components = {
				mcu = {
					class = 'member',
					subtype = 'mcu',
					facts = {
						software = { 'state', 'odd', 'mcu', 'software' },
						updater  = { 'state', 'odd', 'mcu', 'updater'  },
						health   = { 'state', 'odd', 'mcu', 'health'   },
					},
					actions = {
						['prepare-update'] = { 'rpc', 'weird', 'mcu', 'prepare' },
						['stage-update'] = {
							kind = 'fabric_stage',
							link_id = 'cm5-uart-mcu',
							receiver = { 'rpc', 'member', 'mcu', 'receive' },
							timeout_s = 1.0,
						},
						['commit-update'] = { 'rpc', 'weird', 'mcu', 'commit' },
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
		local image_id = { mcu = 'mcu-image-0' }
		local boot_id  = { mcu = 'mcu-boot-1' }
		local pending_image_id = nil

		local remote_member_conn = bus:connect()

		local function publish_remote_status()
			remote_member_conn:retain({ 'selfish', 'software' }, {
				version = versions.mcu,
				image_id = image_id.mcu,
				boot_id = boot_id.mcu,
			})
			remote_member_conn:retain({ 'selfish', 'updater' }, {
				state = 'running',
			})
			remote_member_conn:retain({ 'selfish', 'health' }, {
				state = 'ok',
			})
		end

		local prepare_ep = remote_member_conn:bind({ 'rpc', 'member', 'mcu', 'prepare' }, { queue_len = 16 })
		local receive_ep = remote_member_conn:bind({ 'rpc', 'member', 'mcu', 'receive' }, { queue_len = 16 })
		local commit_ep  = remote_member_conn:bind({ 'rpc', 'member', 'mcu', 'commit'  }, { queue_len = 16 })

		bind_reply_loop(scope, prepare_ep, function(_payload)
			return { ok = true, prepared = true }
		end)

		bind_reply_loop(scope, receive_ep, function(payload)
			pending_image_id = type(payload) == 'table' and type(payload.meta) == 'table' and payload.meta.image_id or nil
			return { ok = true, accepted = true }
		end)

		bind_reply_loop(scope, commit_ep, function(_payload)
			versions.mcu = 'mcu-v1'
			image_id.mcu = pending_image_id or 'mcu-image-1'
			boot_id.mcu  = 'mcu-boot-2'
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
						{ ['local'] = { 'state', 'odd', 'mcu', 'software' }, ['remote'] = { 'remoteish', 'software' } },
						{ ['local'] = { 'state', 'odd', 'mcu', 'updater'  }, ['remote'] = { 'remoteish', 'updater'  } },
						{ ['local'] = { 'state', 'odd', 'mcu', 'health'   }, ['remote'] = { 'remoteish', 'health'   } },
					},
					outbound_call_rules = {
						{
							topic = { 'rpc', 'weird', 'mcu', 'prepare' },
							['local'] = { 'rpc', 'weird', 'mcu', 'prepare' },
							['remote'] = { 'rpc', 'member', 'mcu', 'prepare' },
							timeout = 1.0,
						},
						{
							topic = { 'rpc', 'weird', 'mcu', 'commit' },
							['local'] = { 'rpc', 'weird', 'mcu', 'commit' },
							['remote'] = { 'rpc', 'member', 'mcu', 'commit' },
							timeout = 1.0,
						},
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
					export_retained_rules = {
						{ ['local'] = { 'selfish', 'software' }, ['remote'] = { 'remoteish', 'software' } },
						{ ['local'] = { 'selfish', 'updater'  }, ['remote'] = { 'remoteish', 'updater'  } },
						{ ['local'] = { 'selfish', 'health'   }, ['remote'] = { 'remoteish', 'health'   } },
					},
					inbound_call_rules = {
						{ ['local'] = { 'rpc', 'member', 'mcu' }, ['remote'] = { 'rpc', 'member', 'mcu' }, timeout = 1.0 },
					},
				},
			})
		end)
		assert(ok2, tostring(err2))

		spawn_transfer_endpoint(scope, bus:connect(), { 'cap', 'transfer-manager', 'main', 'rpc', 'send-blob' }, a_ctl_tx)

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
		assert(wait_service_running(caller, 'device', 1.5) == true)
		assert(wait_service_running(caller, 'update', 1.5) == true)

		publish_remote_status()

		assert(wait_device_component(caller, 'mcu', function(payload)
			return payload.available == true
				and type(payload.software) == 'table'
				and payload.software.version == 'mcu-v0'
				and payload.software.boot_id == 'mcu-boot-1'
		end, 1.5))

		local ok_default = safe.pcall(function()
			return probe.wait_payload(caller, { 'raw', 'member', 'mcu', 'state', 'software' }, { timeout = 0.1 })
		end)
		assert(ok_default == false)

		local created, cerr = caller:call({ 'cap', 'update-manager', 'main', 'rpc', 'create-job' }, {
			component = 'mcu',
			artifact = {
				kind = 'import_path',
				path = storagecaps.seed_import_path(artifacts, '/tmp/mcu-image-v1.bin', 'mcu-image-v1'),
			},
			expected_image_id = 'mcu-image-1',
			metadata = {
				channel = 'test',
			},
		}, { timeout = 0.5 })
		assert(cerr == nil)
		assert(created.ok == true)

		local job = created.job

		local started, serr = caller:call({ 'cap', 'update-manager', 'main', 'rpc', 'start-job' }, {
			job_id = job.job_id,
		}, { timeout = 0.5 })
		assert(serr == nil)
		assert(started.ok == true)

		assert(wait_retained_state(caller, { 'state', 'workflow', 'update-job', job.job_id }, function(payload)
			return type(payload) == 'table'
				and type(payload.job) == 'table'
				and payload.job.lifecycle.state == 'awaiting_commit'
		end, 0.75))

		local committed, perr = caller:call({ 'cap', 'update-manager', 'main', 'rpc', 'commit-job' }, {
			job_id = job.job_id,
		}, { timeout = 1.0 })
		assert(perr == nil)
		assert(committed.ok == true)

		assert(wait_retained_state(caller, { 'state', 'workflow', 'update-job', job.job_id }, function(payload)
			return type(payload) == 'table'
				and type(payload.job) == 'table'
				and payload.job.lifecycle.state == 'succeeded'
		end, 2.0))

		assert(wait_device_component(caller, 'mcu', function(payload)
			return payload.available == true
				and type(payload.software) == 'table'
				and payload.software.version == 'mcu-v1'
				and payload.software.image_id == 'mcu-image-1'
				and payload.software.boot_id == 'mcu-boot-2'
		end, 2.0))

		local final, ferr = caller:call({ 'cap', 'update-manager', 'main', 'rpc', 'get-job' }, {
			job_id = job.job_id,
		}, { timeout = 0.5 })
		assert(ferr == nil)
		assert(final.ok == true)
		assert(type(final.job) == 'table')
		assert(final.job.lifecycle.state == 'succeeded')
		assert(type(control.namespaces['update/jobs'][job.job_id]) == 'table')
	end, { timeout = 4.0 })
end

return T
