-- tests/integration/devhost/ui_http_firmware_spec.lua

local cjson            = require 'cjson.safe'
local http_request     = require 'http.request'
local safe             = require 'coxpcall'

local fibers           = require 'fibers'
local sleep            = require 'fibers.sleep'
local busmod           = require 'bus'

local runfibers        = require 'tests.support.run_fibers'
local probe            = require 'tests.support.bus_probe'
local fake_hal_mod     = require 'tests.support.fake_hal'
local fake_stream_pair = require 'tests.support.fake_stream_pair'
local diag             = require 'tests.support.stack_diag'

local mainmod          = require 'devicecode.main'
local config_service   = require 'services.config'
local fabric_service   = require 'services.fabric'
local ui_service       = require 'services.ui'
local http_transport   = require 'services.ui.http_transport'
local authz            = require 'devicecode.authz'

local protocol         = require 'services.fabric.protocol'
local b64url           = require 'services.fabric.b64url'
local checksum         = require 'services.fabric.checksum'

local T = {}

local function encode_state_blob(t)
	local s, err = cjson.encode(t)
	assert(s ~= nil, tostring(err))
	return s
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
		timeout  = opts.timeout or 1.5,
		interval = opts.interval or 0.01,
	})

	if ok then return found end
	return nil
end

local function fabric_blob()
	return {
		fabric = {
			rev = 1,
			data = {
				schema = 'devicecode.fabric/1',
				links = {
					uart0 = {
						peer_id = 'tinygo-peer-1',
						transport = {
							kind = 'uart',
							serial_ref = 'uart-0',
							max_line_bytes = 4096,
						},
						transfer = {
							chunk_raw = 32,
							ack_timeout_s = 0.05,
							max_retries = 3,
						},
						export = { publish = {} },
						import = { publish = {}, call = {} },
						proxy_calls = {},
					},
				},
			},
		},
	}
end

local function start_fake_peer(scope, stream, sink)
	local ok_spawn, err = scope:spawn(function()
		local peer_sid = 'tinygo-session-1'
		local current = nil

		local function send(msg)
			local line, lerr = protocol.encode_line(msg)
			assert(line ~= nil, tostring(lerr))
			local n, werr = fibers.perform(stream:write_op(line, '\n'))
			assert(n ~= nil, tostring(werr))
		end

		while true do
			local line, rerr = fibers.perform(stream:read_line_op())
			assert(line ~= nil, tostring(rerr))

			local raw, derr = protocol.decode_line(line)
			assert(raw ~= nil, tostring(derr))

			local msg, verr = protocol.validate_message(raw)
			assert(msg ~= nil, tostring(verr))

			if msg.t == 'hello' then
				send(protocol.hello_ack('tinygo-peer-1', {
					sid = peer_sid,
				}))

			elseif msg.t == 'ping' then
				send(protocol.pong({ sid = peer_sid }))

			elseif msg.t == 'xfer_begin' then
				current = {
					id      = msg.id,
					size    = msg.size,
					sha256  = msg.sha256,
					next    = 0,
					parts   = {},
					name    = msg.name,
					format  = msg.format,
				}
				send(protocol.xfer_ready(msg.id, true, 0, nil))

			elseif msg.t == 'xfer_chunk' then
				assert(current ~= nil, 'chunk before begin')
				assert(msg.id == current.id, 'wrong transfer id')
				assert(msg.seq == current.next, 'unexpected seq')

				local raw_bytes, berr = b64url.decode(msg.data)
				assert(raw_bytes ~= nil, tostring(berr))
				assert(#raw_bytes == msg.n, 'chunk size mismatch')
				assert(checksum.crc32_hex(raw_bytes) == tostring(msg.crc32):lower(), 'crc mismatch')

				current.parts[#current.parts + 1] = raw_bytes
				current.next = current.next + 1

				send(protocol.xfer_need(msg.id, current.next, nil))

			elseif msg.t == 'xfer_commit' then
				assert(current ~= nil, 'commit before begin')
				local bytes = table.concat(current.parts)

				assert(#bytes == msg.size, 'final size mismatch')
				assert(checksum.sha256_hex(bytes) == tostring(msg.sha256):lower(), 'final sha mismatch')

				sink.done   = true
				sink.bytes  = bytes
				sink.size   = #bytes
				sink.sha256 = checksum.sha256_hex(bytes)
				sink.name   = current.name
				sink.format = current.format

				send(protocol.xfer_done(msg.id, true, {
					received = #bytes,
				}, nil))

			elseif msg.t == 'xfer_abort' then
				sink.aborted = msg.reason or 'aborted'
				return
			end
		end
	end)

	assert(ok_spawn, tostring(err))
end

local function http_call(method, uri, body, extra_headers, timeout)
	local req = assert(http_request.new_from_uri(uri))
	req.headers:upsert(':method', method)

	if extra_headers then
		for k, v in pairs(extra_headers) do
			req.headers:upsert(k, v)
		end
	end

	if body ~= nil then
		req:set_body(body)
	end

	local headers, stream = assert(req:go(timeout or 5.0))
	local text = assert(stream:get_body_as_string())
	return tonumber(headers:get(':status')), headers, text
end

local function service_loader(fake_hal, http_port)
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
						name = opts and opts.name or 'config',
						env  = opts and opts.env  or 'dev',
						timings = {
							hal_wait_timeout_s       = 0.25,
							hal_wait_tick_s          = 0.01,
							heartbeat_s              = 60.0,
							persist_debounce_s       = 0.02,
							persist_max_delay_s      = 0.05,
							persist_retry_initial_s  = 0.02,
							persist_retry_max_s      = 0.05,
						},
					})
				end,
			}
		elseif name == 'fabric' then
			return { start = fabric_service.start }
		elseif name == 'ui' then
			return {
				start = function(conn, opts)
					return ui_service.start(conn, {
						name    = opts and opts.name or 'ui',
						env     = opts and opts.env  or 'dev',
						connect = opts.connect,

						verify_login = function(username, password)
							if username == 'admin' and password == 'secret' then
								return authz.user_principal('admin', { roles = { 'admin' } }), nil
							end
							return nil, 'invalid credentials'
						end,

						run_http = function(svc, api, _)
							return http_transport.run(svc, api, {
								host = '127.0.0.1',
								port = http_port,
							})
						end,
					})
				end,
			}
		end

		error('unexpected service name: ' .. tostring(name), 0)
	end
end

function T.devhost_ui_http_firmware_upload_reaches_fabric_uart_and_completes_transfer()
	runfibers.run(function(scope)
		local http_port = 19181

		local bus      = busmod.new()
		local conn     = bus:connect()
		local dev_uart, peer_uart = fake_stream_pair.new_pair()

		local sink = {}

		start_fake_peer(scope, peer_uart, sink)

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
						data  = encode_state_blob(fabric_blob()),
					},
				},
				open_serial_stream = {
					{
						ok = true,
						stream = dev_uart,
						info = {
							ref = 'uart-0',
						},
					},
				},
			},
		})

		local rec = diag.start(scope, bus, {
			{ label = 'obs',    topic = { 'obs', '#' } },
			{ label = 'svc',    topic = { 'svc', '#' } },
			{ label = 'config', topic = { 'config', '#' } },
			{ label = 'state',  topic = { 'state', '#' } },
		}, {
			max_records = 300,
		})

		local child, cerr = scope:child()
		assert(child ~= nil, tostring(cerr))

		local ok_spawn, serr = scope:spawn(function()
			mainmod.run(child, {
				env            = 'dev',
				services_csv   = 'hal,config,fabric,ui',
				bus            = bus,
				service_loader = service_loader(fake_hal, http_port),
			})
		end)
		assert(ok_spawn, tostring(serr))

		local fabric_ready = wait_retained_payload_matching(conn, { 'state', 'fabric', 'link', 'uart0' }, function(payload)
			return type(payload) == 'table'
				and payload.status == 'ready'
				and payload.ready == true
		end, { timeout = 1.5 })

		if fabric_ready == nil then
			error(diag.explain(
				'expected fabric link uart0 to reach ready state',
				rec,
				fake_hal
			), 0)
		end

		local login_status, _, login_body = http_call(
			'POST',
			('http://127.0.0.1:%d/api/login'):format(http_port),
			cjson.encode({ username = 'admin', password = 'secret' }),
			{
				['content-type'] = 'application/json',
			}
		)
		assert(login_status == 200, login_body)

		local login = assert(cjson.decode(login_body))
		assert(login.ok == true)
		local sid = assert(login.data.session_id)

		local firmware = string.rep(string.char(0xA5), 257)

		local up_status, _, up_body = http_call(
			'POST',
			('http://127.0.0.1:%d/api/fabric/firmware/uart0'):format(http_port),
			firmware,
			{
				['x-session-id'] = sid,
				['x-filename']   = 'fw.uf2',
				['content-type'] = 'application/octet-stream',
				['content-length'] = tostring(#firmware),
			}
		)
		assert(up_status == 200, up_body)

		local up = assert(cjson.decode(up_body))
		assert(up.ok == true)
		assert(type(up.data.transfer_id) == 'string' and up.data.transfer_id ~= '')

		local transfer_id = up.data.transfer_id

		local done = probe.wait_until(function()
			local st, _, body = http_call(
				'GET',
				('http://127.0.0.1:%d/api/fabric/transfer/%s'):format(http_port, transfer_id),
				nil,
				{
					['x-session-id'] = sid,
				}
			)

			if st ~= 200 then
				return false
			end

			local obj = cjson.decode(body)
			return obj
				and obj.ok == true
				and type(obj.data) == 'table'
				and type(obj.data.transfer) == 'table'
				and obj.data.transfer.status == 'done'
		end, {
			timeout = 2.0,
			interval = 0.02,
		})

		assert(done == true, 'expected transfer to reach done')
		assert(sink.done == true, 'expected fake peer to complete transfer')
		assert(sink.bytes == firmware, 'expected fake peer bytes to match upload')
		assert(sink.sha256 == checksum.sha256_hex(firmware), 'expected fake peer sha256 to match upload')
	end, { timeout = 3.0 })
end

return T
