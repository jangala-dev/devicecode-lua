local safe         = require 'coxpcall'
local cjson        = require 'cjson.safe'
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
local storagecaps  = require 'tests.support.storage_caps'

local T = {}

local function u16le(n)
	return string.char(n % 256, math.floor(n / 256) % 256)
end

local function u32le(n)
	return string.char(
		n % 256,
		math.floor(n / 256) % 256,
		math.floor(n / 65536) % 256,
		math.floor(n / 16777216) % 256
	)
end

local function make_dcmcu(opts)
	opts = opts or {}
	local payload = opts.payload or 'PAYLOAD'
	local manifest = {
		schema = 1,
		component = 'mcu',
		target = {
			product_family = 'bigbox',
			hardware_profile = opts.hardware_profile or 'bb-v1-cm5-2',
			mcu_board_family = opts.mcu_board_family or 'rp2354a',
		},
		build = {
			version = opts.version or 'mcu-v1',
			build_id = opts.build_id or '2026.04.24-1',
			image_id = opts.image_id or 'mcu-bigbox-1+2026.04.24-1',
		},
		payload = {
			format = 'raw-bin',
			length = #payload,
			sha256 = opts.sha256 or string.rep('b', 64),
		},
		signing = {
			key_id = 'test-key',
			sig_alg = 'ed25519',
		},
	}
	local manifest_bytes = cjson.encode(manifest)
	local sig = string.rep('S', 64)
	local header = table.concat({
		'DCMCUIMG', u16le(1), u16le(32), u32le(#manifest_bytes), u32le(64), u32le(#payload), u32le(0), u32le(0)
	})
	return header .. manifest_bytes .. sig .. payload
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
			else req:reply(reply) end
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
	timeout = timeout or 1.0
	local watch = conn:watch_retained(topic, {
		replay = true,
		queue_len = 16,
		full = 'drop_oldest',
	})
	local deadline = fibers.now() + timeout
	while fibers.now() < deadline do
		local remaining = deadline - fibers.now()
		local which, a, b = fibers.perform(fibers.named_choice({
			ev = watch:recv_op(),
			timeout = sleep_mod.sleep_op(remaining):wrap(function() return true end),
		}))
		if which == 'timeout' then
			pcall(function() watch:unwatch() end)
			return false
		end
		local ev, err = a, b
		if not ev then
			pcall(function() watch:unwatch() end)
			return false
		end
		if ev.op == 'retain' and pred(ev.payload) then
			pcall(function() watch:unwatch() end)
			return true
		end
	end
	pcall(function() watch:unwatch() end)
	return false
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
	return wait_retained_state(conn, { 'state', 'workflow', 'update-job', job_id }, function(payload)
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

function T.devhost_bundled_mcu_update_runs_end_to_end_over_fabric()
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

		local dcmcu_path = '/rom/mcu/current.dcmcu'
		local dcmcu_bytes = make_dcmcu({
			version = 'mcu-v1',
			image_id = 'mcu-image-1',
			sha256 = string.rep('b', 64),
			payload = 'MCU-PAYLOAD-v1',
		})
		storagecaps.seed_import_path(artifacts, dcmcu_path, dcmcu_bytes)

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
			bundled = {
				components = {
					mcu = {
						enabled = true,
						follow_mode_default = 'hold',
						auto_start = false,
						auto_commit = false,
						source = { kind = 'bundled', path = dcmcu_path },
						target = {
							product_family = 'bigbox',
							hardware_profile = 'bb-v1-cm5-2',
							mcu_board_family = 'rp2354a',
						},
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
						stage_update = {
							kind = 'fabric_stage',
							link_id = 'cm5-uart-mcu',
							receiver = { 'rpc', 'member', 'mcu', 'receive' },
							timeout_s = 1.0,
						},
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
		local image_id = { mcu = 'mcu-image-0' }
		local boot_id = { mcu = 'mcu-boot-1' }
		local received_blob = nil
		local remote_member_conn = bus:connect()

		local function publish_remote_status()
			remote_member_conn:retain({ 'member', 'mcu', 'updater' }, {
				state = 'running',
			})
			remote_member_conn:retain({ 'member', 'mcu', 'software' }, {
				version = versions.mcu,
				image_id = image_id.mcu,
				payload_sha256 = versions.mcu == 'mcu-v1' and string.rep('b', 64) or string.rep('0', 64),
				boot_id = boot_id.mcu,
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
		bind_reply_loop(scope, commit_ep, function(_payload)
			versions.mcu = 'mcu-v1'
			image_id.mcu = 'mcu-image-1'
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
						{ ['local'] = { 'member', 'mcu', 'updater' }, ['remote'] = { 'remote', 'member', 'mcu', 'updater' } },
						{ ['local'] = { 'member', 'mcu', 'health' }, ['remote'] = { 'remote', 'member', 'mcu', 'health' } },
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
				and payload.software.version == versions.mcu
				and payload.software.image_id == image_id.mcu
				and payload.software.boot_id == boot_id.mcu
		end, 1.5))

		local created, cerr = caller:call({ 'cap', 'update-manager', 'main', 'rpc', 'create-job' }, {
			component = 'mcu',
			artifact = { kind = 'bundled' },
			metadata = { source = 'manual-bundled-test' },
		}, { timeout = 0.5 })
		assert(cerr == nil)
		assert(created.ok == true)
		local job = created.job
		assert(type(job.artifact.ref) == 'string')
		local released_ref = job.artifact.ref

		local started, serr = caller:call({ 'cap', 'update-manager', 'main', 'rpc', 'start-job' }, { job_id = job.job_id }, { timeout = 0.5 })
		assert(serr == nil)
		assert(started.ok == true)

		assert(wait_job(caller, job.job_id, function(payload)
			return type(payload) == 'table' and type(payload.job) == 'table' and payload.job.lifecycle.state == 'awaiting_commit'
				and payload.job.artifact.ref == nil and payload.job.artifact.released_at ~= nil
		end, 0.75))
		assert(probe.wait_until(function()
			return artifacts.artifacts[released_ref] == nil
		end, { timeout = 0.25, interval = 0.01 }))
		assert(received_blob == dcmcu_bytes)

		local committed, perr = caller:call({ 'cap', 'update-manager', 'main', 'rpc', 'commit-job' }, { job_id = job.job_id }, { timeout = 1.0 })
		assert(perr == nil)
		assert(committed.ok == true)

		assert(wait_job(caller, job.job_id, function(payload)
			return type(payload) == 'table'
				and type(payload.job) == 'table'
				and payload.job.lifecycle.state == 'succeeded'
		end, 2.5))

		local final, ferr = caller:call({ 'cap', 'update-manager', 'main', 'rpc', 'get-job' }, { job_id = job.job_id }, { timeout = 0.5 })
		assert(ferr == nil)
		assert(final.ok == true)
		assert(final.job.lifecycle.state == 'succeeded')
		assert(type(final.job.result) == 'table')
		assert(final.job.result.image_id == 'mcu-image-1')
		assert(type(control.namespaces['update/jobs'][job.job_id]) == 'table')
	end, { timeout = 4.0 })
end

return T
