local safe         = require 'coxpcall'
local busmod       = require 'bus'
local mailbox      = require 'fibers.mailbox'
local fibers       = require 'fibers'
local sleep_mod    = require 'fibers.sleep'

local checksum     = require 'services.fabric.checksum'
local session      = require 'services.fabric.session'
local device       = require 'services.device'
local update       = require 'services.update'
local ui_service   = require 'services.ui.service'
local http_ui      = require 'services.ui.transport.http'

local duplex       = require 'tests.support.duplex_stream'
local probe        = require 'tests.support.bus_probe'
local runfibers    = require 'tests.support.run_fibers'
local storagecaps  = require 'tests.support.storage_caps'
local ui_fakes     = require 'tests.support.ui_fakes'

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

local function bind_reply_loop(scope, ep, handler)
	local ok, err = scope:spawn(function()
		while true do
			local req = ep:recv()
			if not req then return end
			local reply, ferr = handler(req.payload or {}, req)
			if reply == nil then
				if ferr == '__forwarded__' then
					-- transfer manager will reply later
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
		return type(payload) == 'table' and payload.state == 'running'
	end, timeout or 1.5)
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

local function wait_device_component(conn, name, pred, timeout)
	return wait_retained_state(conn, { 'state', 'device', 'component', name }, function(payload)
		return type(payload) == 'table' and pred(payload)
	end, timeout or 1.5)
end

local function wait_job(conn, job_id, pred, timeout)
	return wait_retained_state(conn, { 'state', 'update', 'jobs', job_id }, function(payload)
		return type(payload) == 'table' and pred(payload)
	end, timeout or 1.5)
end

local function read_all(source)
	local chunks, offset = {}, 0
	while true do
		local chunk, err = source:read_chunk(offset, 64 * 1024)
		assert(chunk ~= nil, tostring(err or 'read_failed'))
		if chunk == '' then break end
		chunks[#chunks + 1] = chunk
		offset = offset + #chunk
	end
	return table.concat(chunks)
end

function T.devhost_ui_upload_creates_starts_and_transfers_mcu_update_over_fabric()
	runfibers.run(function(scope)
		local orig_sleep = sleep_mod.sleep
		sleep_mod.sleep = function(dt)
			return orig_sleep(math.min(dt, 0.01))
		end
		fibers.current_scope():finally(function()
			sleep_mod.sleep = orig_sleep
		end)

		local bus = busmod.new()
		local seed = bus:connect()
		local caller = bus:connect()
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
						software = { 'imported', 'member', 'mcu', 'software' },
						updater = { 'imported', 'member', 'mcu', 'updater' },
						health = { 'imported', 'member', 'mcu', 'health' },
					},
					actions = {
						prepare_update = { 'rpc', 'member', 'mcu', 'prepare' },
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
		local boot_id = { mcu = 'mcu-boot-1' }
		local received_blob = nil
		local remote_member_conn = bus:connect()

		local function publish_remote_status()
			remote_member_conn:retain({ 'member', 'mcu', 'software' }, {
				version = versions.mcu,
				boot_id = boot_id.mcu,
			})
			remote_member_conn:retain({ 'member', 'mcu', 'updater' }, {
				state = 'running',
			})
			remote_member_conn:retain({ 'member', 'mcu', 'health' }, {
				state = 'ok',
			})
		end

		local prepare_ep = remote_member_conn:bind({ 'rpc', 'member', 'mcu', 'prepare' }, { queue_len = 16 })
		local receive_ep = remote_member_conn:bind({ 'rpc', 'member', 'mcu', 'receive' }, { queue_len = 16 })
		local commit_ep = remote_member_conn:bind({ 'rpc', 'member', 'mcu', 'commit' }, { queue_len = 16 })

		bind_reply_loop(scope, prepare_ep, function(_payload)
			return { ok = true, prepared = true }
		end)
		bind_reply_loop(scope, receive_ep, function(payload)
			assert(type(payload.artefact) == 'table')
			assert(type(payload.artefact.open_source) == 'function')
			received_blob = read_all(payload.artefact:open_source())
			return { ok = true, accepted = true }
		end)
		bind_reply_loop(scope, commit_ep, function(payload)
			versions.mcu = payload.metadata and payload.metadata.version or 'mcu-v1'
			boot_id.mcu = 'mcu-boot-2'
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
						{ ['local'] = { 'imported', 'member', 'mcu', 'software' }, ['remote'] = { 'remote', 'member', 'mcu', 'software' } },
						{ ['local'] = { 'imported', 'member', 'mcu', 'updater' }, ['remote'] = { 'remote', 'member', 'mcu', 'updater' } },
						{ ['local'] = { 'imported', 'member', 'mcu', 'health' }, ['remote'] = { 'remote', 'member', 'mcu', 'health' } },
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
					export_retained_rules = {
						{ ['local'] = { 'member', 'mcu', 'software' }, ['remote'] = { 'remote', 'member', 'mcu', 'software' } },
						{ ['local'] = { 'member', 'mcu', 'updater' },  ['remote'] = { 'remote', 'member', 'mcu', 'updater' } },
						{ ['local'] = { 'member', 'mcu', 'health' },   ['remote'] = { 'remote', 'member', 'mcu', 'health' } },
					},
					inbound_call_rules = {
						{ ['local'] = { 'rpc', 'member', 'mcu' }, ['remote'] = { 'rpc', 'member', 'mcu' }, timeout = 1.0 },
					},
				},
			})
		end)
		assert(ok2, tostring(err2))

		spawn_transfer_endpoint(scope, bus:connect(), { 'cmd', 'fabric', 'transfer' }, a_ctl_tx)

		local ok3, err3 = scope:spawn(function()
			device.start(bus:connect(), { name = 'device', env = 'dev' })
		end)
		assert(ok3, tostring(err3))

		local ok4, err4 = scope:spawn(function()
			update.start(bus:connect(), { name = 'update', env = 'dev' })
		end)
		assert(ok4, tostring(err4))

		local connect = ui_fakes.connect_factory(bus)
		local captured = {}
		local ok5, err5 = scope:spawn(function()
			ui_service.start(bus:connect(), {
				name = 'ui',
				env = 'dev',
				connect = connect,
				verify_login = function(username, password)
					if username ~= 'admin' or password ~= 'pw' then return nil, 'invalid credentials' end
					return ui_fakes.principal('admin')
				end,
				run_http = function(_, app, http_opts)
					captured.app = app
					captured.http_opts = http_opts
					while true do require('fibers.sleep').sleep(3600) end
				end,
				model_ready_timeout_s = 0.5,
			})
		end)
		assert(ok5, tostring(err5))

		assert(wait_ready(caller, 'cm5-uart-mcu', 2.0) == true)
		assert(wait_ready(caller, 'mcu-uart-cm5', 2.0) == true)
		assert(wait_service_running(caller, 'device', 1.5) == true)
		assert(wait_service_running(caller, 'update', 1.5) == true)
		assert(probe.wait_until(function() return captured.app ~= nil end, { timeout = 0.5, interval = 0.01 }))

		publish_remote_status()
		assert(wait_device_component(caller, 'mcu', function(payload)
			return payload.available == true and type(payload.software) == 'table' and payload.software.version == versions.mcu
		end, 1.5))

		local session_rec, lerr = captured.app.login('admin', 'pw')
		assert(lerr == nil and type(session_rec) == 'table' and type(session_rec.session_id) == 'string' and session_rec.session_id ~= '')
		local sid = session_rec.session_id

		local handler = http_ui.build_handler({ obs_log = function() end }, captured.app, {
			spawn_ws_client = function() error('ws not expected') end,
			ws_opts = captured.http_opts and captured.http_opts.ws_opts or {},
		})

		local body = 'MCU-FW-IMAGE-v1\nhello\0world'
		local body_checksum = checksum.digest_hex(body)
		local upload_stream = ui_fakes.fake_http_stream({
			method = 'POST',
			path = '/api/update/uploads',
			body = body,
			headers = {
				[':method'] = 'POST',
				[':path'] = '/api/update/uploads',
				['x-session-id'] = sid,
				['x-artifact-component'] = 'mcu',
				['x-artifact-name'] = 'mcu-fw.bin',
				['x-artifact-version'] = 'mcu-v1',
				['x-artifact-build'] = 'build-42',
				['x-artifact-checksum'] = body_checksum,
			},
		})
		handler({}, upload_stream)
		assert(upload_stream:status() == '200')
		local upload_json = upload_stream:json()
		assert(type(upload_json) == 'table' and upload_json.ok == true)
		assert(type(upload_json.data) == 'table')
		assert(type(upload_json.data.artifact) == 'table')
		assert(upload_json.data.artifact.checksum == body_checksum)
		local job_id = assert(upload_json.data.job and upload_json.data.job.job_id)
		local artifact_ref = assert(upload_json.data.artifact.ref)

		assert(wait_job(caller, job_id, function(payload)
			return type(payload) == 'table'
				and type(payload.job) == 'table'
				and type(payload.job.lifecycle) == 'table'
				and payload.job.lifecycle.state == 'awaiting_commit'
				and payload.job.lifecycle.stage == 'staged_on_mcu'
		end, 1.5))
		assert(received_blob == body)
		assert(artifacts.next_id >= 1)
		assert(artifacts.artifacts[artifact_ref] == nil)

		local commit_stream = ui_fakes.fake_http_stream({
			method = 'POST',
			path = '/api/update/jobs/' .. job_id .. '/do',
			body = '{"op":"commit"}',
			headers = {
				[':method'] = 'POST',
				[':path'] = '/api/update/jobs/' .. job_id .. '/do',
				['x-session-id'] = sid,
			},
		})
		handler({}, commit_stream)
		assert(commit_stream:status() == '200')
		local commit_json = commit_stream:json()
		assert(type(commit_json) == 'table' and commit_json.ok == true)

		assert(wait_device_component(caller, 'mcu', function(payload)
			return payload.available == true
				and type(payload.software) == 'table'
				and payload.software.version == 'mcu-v1'
				and payload.software.boot_id == 'mcu-boot-2'
		end, 2.0))

	assert(wait_job(caller, job_id, function(payload)
		return type(payload) == 'table'
			and type(payload.job) == 'table'
			and type(payload.job.lifecycle) == 'table'
			and payload.job.lifecycle.state == 'succeeded'
	end, 2.0))
	end, { timeout = 4.0 })
end

return T
