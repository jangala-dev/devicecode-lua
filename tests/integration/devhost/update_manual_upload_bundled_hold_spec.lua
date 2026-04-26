local safe              = require 'coxpcall'
local cjson             = require 'cjson.safe'
local busmod            = require 'bus'
local mailbox           = require 'fibers.mailbox'
local fibers            = require 'fibers'
local sleep_mod         = require 'fibers.sleep'

local checksum          = require 'shared.hash.xxhash32'
local session           = require 'services.fabric.session'
local device            = require 'services.device'
local update            = require 'services.update'
local update_artifacts  = require 'services.update.artifacts'
local ui_service        = require 'services.ui.service'
local http_ui           = require 'services.ui.transport.http'

local duplex            = require 'tests.support.duplex_stream'
local probe             = require 'tests.support.bus_probe'
local runfibers         = require 'tests.support.run_fibers'
local storagecaps       = require 'tests.support.storage_caps'
local ui_fakes          = require 'tests.support.ui_fakes'

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
		'DCMCUIMG',
		u16le(1),
		u16le(32),
		u32le(#manifest_bytes),
		u32le(64),
		u32le(#payload),
		u32le(0),
		u32le(0),
	})

	return header .. manifest_bytes .. sig .. payload, manifest
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
					-- handled asynchronously by transfer manager
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

local function latest_payload(conn, topic)
	local ok, payload = safe.pcall(function()
		return probe.wait_payload(conn, topic, { timeout = 0.02 })
	end)
	if ok then return payload end
	return nil
end

local function pretty(v)
	local ok, s = pcall(cjson.encode, v)
	if ok and s then return s end
	return tostring(v)
end

local function dump_state_string(conn, control, job_id, label)
	local bundled = latest_payload(conn, { 'state', 'update', 'component', 'mcu' })
	local job = latest_payload(conn, { 'state', 'workflow', 'update-job', job_id })
	local comp = latest_payload(conn, { 'state', 'device', 'component', 'mcu' })
	local link = latest_payload(conn, { 'state', 'fabric', 'link', 'cm5-uart-mcu', 'session' })

	local ns = control.namespaces['update/state/bundled'] or {}
	local persisted = ns['mcu']

	return table.concat({
		'',
		'[DEBUG] ' .. tostring(label),
		'  bundled retained  = ' .. pretty(bundled),
		'  job retained      = ' .. pretty(job),
		'  device component  = ' .. pretty(comp),
		'  fabric session    = ' .. pretty(link),
		'  bundled persisted = ' .. pretty(persisted),
	}, '\n')
end

local function wait_until_debug(pred, debug_msg_fn, timeout)
	local ok = probe.wait_until(pred, { timeout = timeout or 1.5, interval = 0.01 })
	assert(ok, debug_msg_fn())
end

local function wait_service_running(conn, name, timeout, control, job_id)
	wait_until_debug(function()
		local payload = latest_payload(conn, { 'svc', name, 'status' })
		return type(payload) == 'table'
			and payload.state == 'running'
			and payload.ready == true
	end, function()
		return dump_state_string(conn, control, job_id, 'service not running: ' .. tostring(name))
	end, timeout)
end

local function wait_ready(conn, link_id, timeout, control, job_id)
	wait_until_debug(function()
		local payload = latest_payload(conn, { 'state', 'fabric', 'link', link_id, 'session' })
		return type(payload) == 'table'
			and type(payload.status) == 'table'
			and payload.status.ready == true
	end, function()
		return dump_state_string(conn, control, job_id, 'fabric link not ready: ' .. tostring(link_id))
	end, timeout)
end

local function wait_device_component(conn, control, job_id, pred, timeout, label)
	wait_until_debug(function()
		local payload = latest_payload(conn, { 'state', 'device', 'component', 'mcu' })
		return type(payload) == 'table' and pred(payload)
	end, function()
		return dump_state_string(conn, control, job_id, label or 'device component wait failed')
	end, timeout)
end

local function wait_job(conn, control, job_id, pred, timeout, label)
	wait_until_debug(function()
		local payload = latest_payload(conn, { 'state', 'workflow', 'update-job', job_id })
		return type(payload) == 'table' and pred(payload)
	end, function()
		return dump_state_string(conn, control, job_id, label or 'job wait failed')
	end, timeout)
end

local function wait_bundled(conn, control, job_id, pred, timeout, label)
	wait_until_debug(function()
		local payload = latest_payload(conn, { 'state', 'update', 'component', 'mcu' })
		return type(payload) == 'table' and pred(payload)
	end, function()
		return dump_state_string(conn, control, job_id, label or 'bundled wait failed')
	end, timeout)
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

local function start_update_service(parent_scope, bus)
	local s, err = parent_scope:child()
	assert(s, tostring(err))
	local ok, spawn_err = s:spawn(function()
		update.start(bus:connect(), { name = 'update', env = 'dev' })
	end)
	assert(ok, tostring(spawn_err))
	return s
end

local function count_jobs(control)
	local jobs = control.namespaces['update/jobs'] or {}
	local n = 0
	for _ in pairs(jobs) do n = n + 1 end
	return n
end

function T.manual_upload_puts_bundled_mcu_following_into_hold_and_persists_across_update_restart()
	runfibers.run(function(scope)
		update_artifacts.reset_default_preflighters()
		fibers.current_scope():finally(function()
			update_artifacts.reset_default_preflighters()
		end)

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

		local bundled_path = '/rom/mcu/current.dcmcu'
		local bundled_bytes, bundled_manifest = make_dcmcu({
			version = 'mcu-v1',
			build_id = '2026.04.24-1',
			image_id = 'mcu-image-1',
			sha256 = string.rep('b', 64),
			payload = 'MCU-PAYLOAD-v1',
		})
		storagecaps.seed_import_path(artifacts, bundled_path, bundled_bytes)

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
						follow_mode_default = 'auto',
						auto_start = true,
						auto_commit = false,
						source = { kind = 'bundled', path = bundled_path },
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
		local a_report_tx, _ = mailbox.new(8, { full = 'reject_newest' })
		local b_report_tx, _ = mailbox.new(8, { full = 'reject_newest' })

		local remote_member_conn = bus:connect()
		local current = {
			version = bundled_manifest.build.version,
			image_id = bundled_manifest.build.image_id,
			boot_id = 'mcu-boot-1',
		}
		local pending = {
			version = nil,
			image_id = nil,
		}
		local received_blob = nil

		local function publish_remote_status()
			remote_member_conn:retain({ 'member', 'mcu', 'software' }, {
				version = current.version,
				image_id = current.image_id,
				boot_id = current.boot_id,
			})
			remote_member_conn:retain({ 'member', 'mcu', 'updater' }, { state = 'running' })
			remote_member_conn:retain({ 'member', 'mcu', 'health' }, { state = 'ok' })
		end

		local prepare_ep = remote_member_conn:bind({ 'rpc', 'member', 'mcu', 'prepare' }, { queue_len = 16 })
		local receive_ep = remote_member_conn:bind({ 'rpc', 'member', 'mcu', 'receive' }, { queue_len = 16 })
		local commit_ep = remote_member_conn:bind({ 'rpc', 'member', 'mcu', 'commit' }, { queue_len = 16 })

		bind_reply_loop(scope, prepare_ep, function()
			return { ok = true, prepared = true }
		end)

		bind_reply_loop(scope, receive_ep, function(payload)
			assert(type(payload.artefact) == 'table')
			assert(type(payload.artefact.open_source) == 'function')
			received_blob = read_all(payload.artefact:open_source())

			local meta = type(payload) == 'table' and payload.meta or nil
			if type(meta) == 'table' then
				pending.version = meta.version
				pending.image_id = meta.image_id
			end

			return { ok = true, accepted = true }
		end)

		bind_reply_loop(scope, commit_ep, function()
			current.version = pending.version or current.version
			current.image_id = pending.image_id or current.image_id
			current.boot_id = 'mcu-boot-2'
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

		local update_scope = start_update_service(scope, bus)
		fibers.current_scope():finally(function()
			update_scope:cancel('test shutdown')
		end)

		local connect = ui_fakes.connect_factory(bus)
		local captured = {}
		local ok4, err4 = scope:spawn(function()
			ui_service.start(bus:connect(), {
				name = 'ui',
				env = 'dev',
				connect = connect,
				verify_login = function(username, password)
					if username ~= 'admin' or password ~= 'pw' then
						return nil, 'invalid credentials'
					end
					return ui_fakes.principal('admin')
				end,
				run_http = function(_, app, http_opts)
					captured.app = app
					captured.http_opts = http_opts
					while true do
						require('fibers.sleep').sleep(3600)
					end
				end,
				model_ready_timeout_s = 0.5,
			})
		end)
		assert(ok4, tostring(err4))

		wait_ready(caller, 'cm5-uart-mcu', 2.0, control, 'n/a')
		wait_ready(caller, 'mcu-uart-cm5', 2.0, control, 'n/a')
		wait_service_running(caller, 'device', 1.5, control, 'n/a')
		wait_service_running(caller, 'update', 1.5, control, 'n/a')
		wait_until_debug(function() return captured.app ~= nil end, function()
			return dump_state_string(caller, control, 'n/a', 'ui app not captured')
		end, 0.5)

		publish_remote_status()

		wait_device_component(caller, control, 'n/a', function(payload)
			return payload.available == true
				and type(payload.software) == 'table'
				and payload.software.version == current.version
				and payload.software.image_id == current.image_id
		end, 1.5, 'initial mcu component not ready')

		wait_bundled(caller, control, 'n/a', function(payload)
			return payload.follow_mode == 'auto'
				and payload.sync_state == 'satisfied'
				and type(payload.desired) == 'table'
				and payload.desired.image_id == bundled_manifest.build.image_id
		end, 1.5, 'initial bundled state should be satisfied')

		local session_rec, lerr = captured.app.login('admin', 'pw')
		assert(lerr == nil and type(session_rec) == 'table' and type(session_rec.session_id) == 'string' and session_rec.session_id ~= '')
		local sid = session_rec.session_id

		local handler = http_ui.build_handler({ obs_log = function() end }, captured.app, {
			spawn_ws_client = function() error('ws not expected') end,
			ws_opts = captured.http_opts and captured.http_opts.ws_opts or {},
		})

		local upload_body, upload_manifest = make_dcmcu({
			version = 'mcu-v2',
			build_id = '2026.04.24-2',
			image_id = 'mcu-image-2',
			sha256 = string.rep('c', 64),
			payload = 'MCU-PAYLOAD-v2',
		})
		local upload_checksum = checksum.digest_hex(upload_body)

		local upload_stream = ui_fakes.fake_http_stream({
			method = 'POST',
			path = '/api/update/uploads',
			body = upload_body,
			headers = {
				[':method'] = 'POST',
				[':path'] = '/api/update/uploads',
				['x-session-id'] = sid,
				['x-artifact-component'] = 'mcu',
				['x-artifact-name'] = 'manual-mcu-v2.dcmcu',
				['x-artifact-version'] = upload_manifest.build.version,
				['x-artifact-build'] = upload_manifest.build.build_id,
				['x-artifact-checksum'] = upload_checksum,
			},
		})
		handler({}, upload_stream)
		assert(upload_stream:status() == '200')

		local upload_json = upload_stream:json()
		assert(type(upload_json) == 'table' and upload_json.ok == true)
		assert(type(upload_json.data) == 'table')
		local job_id = assert(upload_json.data.job and upload_json.data.job.job_id)

		wait_job(caller, control, job_id, function(payload)
			return type(payload.job) == 'table'
				and type(payload.job.lifecycle) == 'table'
				and payload.job.lifecycle.state == 'awaiting_commit'
				and payload.job.lifecycle.stage == 'staged_on_mcu'
		end, 2.0, 'job should reach awaiting_commit')

		assert(received_blob == upload_body, dump_state_string(caller, control, job_id, 'received blob mismatch'))

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

        wait_device_component(caller, control, job_id, function(payload)
            return payload.available == true
                and type(payload.software) == 'table'
                and payload.software.image_id == upload_manifest.build.image_id
                and payload.software.boot_id == 'mcu-boot-2'
        end, 2.0, 'mcu component did not update after commit')

		wait_job(caller, control, job_id, function(payload)
			return type(payload.job) == 'table'
				and type(payload.job.lifecycle) == 'table'
				and payload.job.lifecycle.state == 'succeeded'
		end, 2.0, 'job should reach succeeded')

		-- This may briefly be "manual_success_hold" before a subsequent reconcile
		-- normalises it to "held". The important thing here is hold + diverged.
		wait_bundled(caller, control, job_id, function(payload)
			return payload.follow_mode == 'hold'
				and payload.sync_state == 'diverged'
				and (payload.last_result == 'manual_success_hold' or payload.last_result == 'held')
				and payload.last_manual_job_id == job_id
				and type(payload.desired) == 'table'
				and payload.desired.image_id == bundled_manifest.build.image_id
		end, 1.5, 'bundled state should move to hold after manual success')

		assert(count_jobs(control) == 1, dump_state_string(caller, control, job_id, 'unexpected job count after manual success'))

		update_scope:cancel('restart update service')
		local outer_st, child_st = fibers.current_scope():try(update_scope:join_op())
		assert(outer_st == 'ok')
		assert(child_st == 'cancelled')

		local update_scope2 = start_update_service(scope, bus)
		fibers.current_scope():finally(function()
			update_scope2:cancel('test shutdown 2')
		end)

		wait_service_running(caller, 'update', 1.5, control, job_id)
		wait_device_component(caller, control, job_id, function(payload)
			return payload.available == true
				and type(payload.software) == 'table'
				and payload.software.image_id == upload_manifest.build.image_id
		end, 1.5, 'mcu component not ready after update restart')

		wait_bundled(caller, control, job_id, function(payload)
			return payload.follow_mode == 'hold'
				and payload.sync_state == 'diverged'
				and payload.last_result == 'held'
				and payload.last_manual_job_id == job_id
				and type(payload.desired) == 'table'
				and payload.desired.image_id == bundled_manifest.build.image_id
		end, 1.5, 'bundled state should remain held after update restart')

		sleep_mod.sleep(0.10)
		assert(count_jobs(control) == 1, dump_state_string(caller, control, job_id, 'restart should not create a second job'))
	end, { timeout = 5.0 })
end

return T
