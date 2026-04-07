-- integration/devhost/ui_firmware_uart_spec.lua
--
-- End-to-end integration test for the current priority path:
--   UI API -> fabric RPC -> HAL open_serial_stream -> UART session ->
--   remote peer transfer protocol -> monitored transfer state.

local cjson          = require 'cjson.safe'

local fibers         = require 'fibers'
local sleep          = require 'fibers.sleep'
local busmod         = require 'bus'
local safe           = require 'coxpcall'

local runfibers      = require 'tests.support.run_fibers'
local probe          = require 'tests.support.bus_probe'
local fake_hal_mod   = require 'tests.support.fake_hal'
local fake_pair_mod  = require 'tests.support.fake_stream_pair'
local diag           = require 'tests.support.stack_diag'

local mainmod        = require 'devicecode.main'
local config_service = require 'services.config'
local fabric_service = require 'services.fabric'
local ui_service     = require 'services.ui'

local blob_source    = require 'services.fabric.blob_source'
local b64url         = require 'services.fabric.b64url'
local checksum       = require 'services.fabric.checksum'
local protocol       = require 'services.fabric.protocol'
local authz          = require 'devicecode.authz'

local T = {}

local function encode_state_blob(t)
	local s, err = cjson.encode(t)
	assert(s ~= nil, tostring(err))
	return s
end

local function config_timings()
	return {
		hal_wait_timeout_s        = 0.25,
		hal_wait_tick_s           = 0.01,
		heartbeat_s               = 60.0,
		persist_debounce_s        = 0.02,
		persist_max_delay_s       = 0.05,
		persist_retry_initial_s   = 0.02,
		persist_retry_max_s       = 0.05,
	}
end

local function firmware_bytes()
	local parts = {}
	for i = 0, 255 do
		parts[#parts + 1] = string.char(i)
	end
	parts[#parts + 1] = 'devicecode-firmware-test'
	return table.concat(parts)
end

local function fabric_cfg(serial_ref, peer_id)
	return {
		schema = 'devicecode.fabric/1',
		links = {
			uart0 = {
				peer_id = peer_id,
				transport = {
					kind = 'uart',
					serial_ref = serial_ref,
					max_line_bytes = 4096,
				},
				transfer = {
					chunk_raw = 32,
					ack_timeout_s = 0.05,
					max_retries = 3,
				},
				export = {
					publish = {},
				},
				import = {
					publish = {},
					call = {},
				},
				proxy_calls = {},
			},
		},
	}
end

local function wait_retained_payload_matching(conn, topic, pred, opts)
	opts = opts or {}

	local found = nil
	local ok = probe.wait_until(function()
		local ok2, payload = safe.pcall(function()
			return probe.wait_payload(conn, topic, { timeout = 0.02 })
		end)

		if ok2 and pred(payload) then
			found = payload
			return true
		end

		return false
	end, {
		timeout  = opts.timeout or 1.0,
		interval = opts.interval or 0.01,
	})

	if ok then
		return found
	end

	return nil
end

local function spawn_tinygoish_peer(scope, stream, peer_id, expected_bytes, results)
	local ok_spawn, err = scope:spawn(function()
		local ack_sid = 'tinygo-session-1'
		local active = nil

		local function send_msg(msg)
			local line, e1 = protocol.encode_line(msg)
			assert(line ~= nil, tostring(e1))
			local n, e2 = fibers.perform(stream:write_op(line, '\n'))
			assert(n ~= nil, tostring(e2))
		end

		while true do
			local line, rerr = fibers.perform(stream:read_line_op())
			assert(line ~= nil, tostring(rerr))

			local raw, derr = protocol.decode_line(line)
			assert(raw ~= nil, tostring(derr))

			local msg, verr = protocol.validate_message(raw)
			assert(msg ~= nil, tostring(verr))

			if msg.t == 'hello' then
				assert(msg.peer == peer_id)
				send_msg(protocol.hello_ack(peer_id, {
					sid = ack_sid,
				}))

			elseif msg.t == 'ping' then
				send_msg(protocol.pong({ sid = ack_sid }))

			elseif msg.t == 'xfer_begin' then
				active = {
					id       = msg.id,
					name     = msg.name,
					kind     = msg.kind,
					format   = msg.format,
					size     = msg.size,
					sha256   = msg.sha256,
					chunk_raw = msg.chunk_raw,
					chunks   = msg.chunks,
					next_seq = 0,
					off      = 0,
					parts    = {},
				}

				results.begin = {
					id        = msg.id,
					kind      = msg.kind,
					name      = msg.name,
					format    = msg.format,
					size      = msg.size,
					sha256    = msg.sha256,
					chunk_raw = msg.chunk_raw,
					chunks    = msg.chunks,
				}

				send_msg(protocol.xfer_ready(msg.id, true, 0, nil))

			elseif msg.t == 'xfer_chunk' then
				assert(active ~= nil)
				assert(msg.id == active.id)
				assert(msg.seq == active.next_seq)
				assert(msg.off == active.off)

				local raw_bytes, berr = b64url.decode(msg.data)
				assert(raw_bytes ~= nil, tostring(berr))
				assert(#raw_bytes == msg.n)
				assert(checksum.crc32_hex(raw_bytes) == tostring(msg.crc32):lower())

				active.parts[#active.parts + 1] = raw_bytes
				active.next_seq = active.next_seq + 1
				active.off = active.off + #raw_bytes
				results.last_seq = msg.seq
				results.bytes_done = active.off

				send_msg(protocol.xfer_need(msg.id, msg.seq + 1, nil))

			elseif msg.t == 'xfer_commit' then
				assert(active ~= nil)
				assert(msg.id == active.id)

				local all = table.concat(active.parts)
				assert(#all == msg.size)
				assert(#all == #expected_bytes)
				assert(all == expected_bytes)
				assert(checksum.sha256_hex(all) == tostring(msg.sha256):lower())

				results.done = {
					id     = msg.id,
					size   = msg.size,
					sha256 = msg.sha256,
					bytes  = all,
				}

				send_msg(protocol.xfer_done(msg.id, true, {
					received_size = #all,
					received_sha256 = checksum.sha256_hex(all),
					applied = true,
				}, nil))
				return

			elseif msg.t == 'xfer_abort' then
				error('unexpected xfer_abort from sender: ' .. tostring(msg.reason), 0)

			else
				error('unexpected message type from sender: ' .. tostring(msg.t), 0)
			end
		end
	end)

	assert(ok_spawn, tostring(err))
end

local function make_ui_run_http(api_box)
	return function(_svc, api, _opts)
		api_box.api = api
		while true do
			sleep.sleep(3600.0)
		end
	end
end

local function make_verify_login()
	return function(username, password)
		if username ~= 'admin' or password ~= 'secret' then
			return nil, 'invalid credentials'
		end
		return authz.user_principal('admin', { roles = { 'admin' } }), nil
	end
end

local function make_service_loader(fake_hal)
	return function(name)
		if name == 'hal' then
			return {
				start = function(conn, opts)
					fake_hal:start(conn, {
						name = opts and opts.name or 'hal',
						env  = opts and opts.env  or 'dev',
					})
					while true do
						sleep.sleep(3600.0)
					end
				end,
			}
		elseif name == 'config' then
			return {
				start = function(conn, opts)
					return config_service.start(conn, {
						name    = opts and opts.name or 'config',
						env     = opts and opts.env  or 'dev',
						timings = config_timings(),
					})
				end,
			}
		elseif name == 'fabric' then
			return {
				start = function(conn, opts)
					return fabric_service.start(conn, {
						name    = opts and opts.name or 'fabric',
						env     = opts and opts.env  or 'dev',
						connect = opts and opts.connect,
					})
				end,
			}
		elseif name == 'ui' then
			return {
				start = function(conn, opts)
					return ui_service.start(conn, {
						name         = opts and opts.name or 'ui',
						env          = opts and opts.env  or 'dev',
						connect      = opts and opts.connect,
						run_http     = opts and opts.run_http,
						verify_login = opts and opts.verify_login,
						session_ttl_s = 60.0,
					})
				end,
			}
		end

		error('unexpected service name: ' .. tostring(name), 0)
	end
end

local function spawn_main(scope, bus, fake_hal, service_opts)
	local child, cerr = scope:child()
	assert(child ~= nil, tostring(cerr))

	local ok_spawn, err = scope:spawn(function()
		mainmod.run(child, {
			env            = 'dev',
			services_csv   = 'hal,config,fabric,ui',
			bus            = bus,
			service_loader = make_service_loader(fake_hal),
			service_opts   = service_opts,
		})
	end)
	assert(ok_spawn, tostring(err))

	return child
end

function T.devhost_ui_firmware_upload_reaches_fabric_uart_and_completes_transfer()
	runfibers.run(function(scope)
		local bus      = busmod.new()
		local req_conn = bus:connect()
		local api_box  = {}

		local serial_ref = 'uart-0'
		local peer_id    = 'tinygo-peer-1'
		local fw_bytes   = firmware_bytes()

		local hal_stream, peer_stream = fake_pair_mod.new_pair()
		local peer_results = {}
		spawn_tinygoish_peer(scope, peer_stream, peer_id, fw_bytes, peer_results)

		local fake_hal = fake_hal_mod.new({
			backend = 'fakehal',
			caps = {
				read_state         = true,
				write_state        = true,
				open_serial_stream = true,
			},
			scripted = {
				read_state = {
					{
						ok    = true,
						found = true,
						data  = encode_state_blob({
							fabric = {
								rev  = 1,
								data = fabric_cfg(serial_ref, peer_id),
							},
						}),
					},
				},
				open_serial_stream = function(req)
					if type(req) ~= 'table' or req.ref ~= serial_ref then
						return { ok = false, err = 'unexpected serial ref' }
					end
					return {
						ok = true,
						stream = hal_stream,
						info = {
							ref = serial_ref,
						},
					}
				end,
			},
		})

		local rec = diag.start(scope, bus, {
			{ label = 'obs',    topic = { 'obs', '#' } },
			{ label = 'svc',    topic = { 'svc', '#' } },
			{ label = 'config', topic = { 'config', '#' } },
			{ label = 'state',  topic = { 'state', '#' } },
		}, {
			max_records = 400,
		})

		spawn_main(scope, bus, fake_hal, {
			ui = {
				run_http     = make_ui_run_http(api_box),
				verify_login = make_verify_login(),
			},
		})

		local main_ready = wait_retained_payload_matching(req_conn, { 'obs', 'state', 'main' }, function(payload)
			return type(payload) == 'table'
				and payload.status == 'running'
		end, { timeout = 1.0 })

		if main_ready == nil then
			error(diag.explain(
				'expected main stack to reach running state',
				rec,
				fake_hal
			), 0)
		end

		local fabric_ready = wait_retained_payload_matching(req_conn, { 'state', 'fabric', 'link', 'uart0' }, function(payload)
			return type(payload) == 'table'
				and payload.status == 'ready'
				and payload.ready == true
				and payload.peer_id == peer_id
		end, { timeout = 1.0 })

		if fabric_ready == nil then
			error(diag.explain(
				'expected fabric link uart0 to reach ready state',
				rec,
				fake_hal
			), 0)
		end

		local got_api = probe.wait_until(function()
			return type(api_box.api) == 'table'
		end, { timeout = 1.0, interval = 0.01 })
		assert(got_api == true, 'expected ui api to be exposed by run_http test hook')

		local login, lerr = api_box.api.login('admin', 'secret')
		assert(login ~= nil, tostring(lerr))
		assert(type(login.session_id) == 'string' and login.session_id ~= '')

		local source = blob_source.from_string('firmware.bin', fw_bytes, {
			format = 'bin',
		})

		local started, serr = api_box.api.firmware_send(login.session_id, 'uart0', source, {
			kind   = 'firmware.rp2350',
			name   = 'firmware.bin',
			format = 'bin',
		})

		assert(started ~= nil, tostring(serr))
		assert(started.ok == true)
		assert(type(started.transfer_id) == 'string' and started.transfer_id ~= '')

		local transfer_id = started.transfer_id
		local final_status = nil

		local done = probe.wait_until(function()
			local out, err = api_box.api.transfer_status(login.session_id, transfer_id)
			if out and out.ok == true and type(out.transfer) == 'table' then
				final_status = out.transfer
				return out.transfer.status == 'done'
			end
			return false
		end, { timeout = 1.5, interval = 0.02 })

		if done ~= true then
			error(diag.explain(
				'expected transfer to reach done state',
				rec,
				fake_hal
			), 0)
		end

		assert(final_status ~= nil)
		assert(final_status.id == transfer_id)
		assert(final_status.status == 'done')
		assert(final_status.size == #fw_bytes)
		assert(final_status.sha256 == checksum.sha256_hex(fw_bytes))
		assert(type(final_status.info) == 'table')
		assert(final_status.info.received_size == #fw_bytes)
		assert(final_status.info.received_sha256 == checksum.sha256_hex(fw_bytes))

		local retained_transfer = wait_retained_payload_matching(req_conn, { 'state', 'fabric', 'transfer', transfer_id }, function(payload)
			return type(payload) == 'table'
				and payload.id == transfer_id
				and payload.status == 'done'
		end, { timeout = 0.5 })
		assert(retained_transfer ~= nil, 'expected retained transfer state')

		local retained_link_transfer = wait_retained_payload_matching(req_conn, { 'state', 'fabric', 'link', 'uart0', 'transfer' }, function(payload)
			return type(payload) == 'table'
				and payload.id == transfer_id
				and payload.status == 'done'
		end, { timeout = 0.5 })
		assert(retained_link_transfer ~= nil, 'expected retained per-link transfer state')

		assert(type(peer_results.begin) == 'table')
		assert(peer_results.begin.kind == 'firmware.rp2350')
		assert(peer_results.begin.name == 'firmware.bin')
		assert(peer_results.begin.format == 'bin')
		assert(peer_results.begin.size == #fw_bytes)
		assert(peer_results.begin.sha256 == checksum.sha256_hex(fw_bytes))
		assert(type(peer_results.done) == 'table')
		assert(peer_results.done.bytes == fw_bytes)

		local open_calls = fake_hal:calls_for('open_serial_stream')
		assert(#open_calls >= 1)
		assert(type(open_calls[1].req) == 'table')
		assert(open_calls[1].req.ref == serial_ref)
	end, { timeout = 2.5 })
end

return T
