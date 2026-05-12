-- tests/unit/fabric/test_fabric.lua

local fibers  = require 'fibers'
local mailbox = require 'fibers.mailbox'
local sleep   = require 'fibers.sleep'
local busmod  = require 'bus'

local fabric   = require 'services.fabric'
local protocol = require 'services.fabric.protocol'
local hal_transport = require 'services.fabric.hal_transport'
local queue    = require 'devicecode.support.queue'

local tests = {}

local function fail(msg) error(msg or 'assertion failed', 3) end
local function assert_true(v, msg) if v ~= true then fail(msg or ('expected true, got ' .. tostring(v))) end end
local function assert_not_nil(v, msg) if v == nil then fail(msg or 'expected non-nil value') end end
local function assert_eq(a, b, msg) if a ~= b then fail(msg or ('expected ' .. tostring(b) .. ', got ' .. tostring(a))) end end
local function assert_match(s, pat, msg) if type(s) ~= 'string' or not s:match(pat) then fail(msg or ('expected "' .. tostring(s) .. '" to match ' .. tostring(pat))) end end

local function closed_rx(reason)
	local tx, rx = mailbox.new(1, { full = 'reject_newest' })
	tx:close(reason or 'closed')
	return rx
end

function tests.test_public_entrypoint_exports_semantic_modules()
	assert_eq(fabric.service, require 'services.fabric.service')
	assert_eq(fabric.link, require 'services.fabric.link')
	assert_eq(fabric.io, require 'services.fabric.io')
	assert_eq(fabric.bridge, require 'services.fabric.bridge')
	assert_eq(fabric.bus_adapter, require 'services.fabric.bus_adapter')
	assert_eq(fabric.session, require 'services.fabric.session')
	assert_eq(fabric.transfer, require 'services.fabric.transfer')
	assert_eq(fabric.transfer_client, require 'services.fabric.transfer_client')
	assert_eq(fabric.transfer_sender, require 'services.fabric.transfer_sender')
	assert_eq(fabric.state, require 'services.fabric.state')
	assert_eq(type(fabric.start), 'function')
	assert_eq(type(fabric.run), 'function')
	assert_eq(type(fabric.run_link), 'function')
end


function tests.test_fabric_service_components_report_through_event_ports()
	local function read(path)
		local f = assert(io.open(path, 'r'))
		local text = f:read('*a')
		f:close()
		return text
	end

	local service = read('../src/services/fabric/service.lua')
	assert_true(service:find('devicecode.support.service_events', 1, true) ~= nil)
	assert_true(service:find('service_events.reporter_for', 1, true) ~= nil)
	assert_true(service:find('snapshot = public_snapshot(self)', 1, true) ~= nil)
	assert_true(service:find('snapshot = function', 1, true) == nil)

	local link = read('../src/services/fabric/link.lua')
	assert_true(link:find('devicecode.support.service_events', 1, true) ~= nil)
	assert_true(link:find('service_events.reporter_for', 1, true) ~= nil)
	assert_true(link:find('snapshot = public_snapshot(self)', 1, true) ~= nil)
	assert_true(link:find('snapshot = function', 1, true) == nil)
end

function tests.test_composed_link_wires_session_bridge_transfer_and_writer_without_callbacks()
	fibers.run(function ()
		local local_tx, local_rx = mailbox.new(8, { full = 'reject_newest' })
		local written = {}
		local read_count = 0

		local inbound = { assert(protocol.hello_ack('peer-sid', 'peer-a')) }
		local transport = {
			read_line_op = function ()
				read_count = read_count + 1
				local frame = inbound[read_count]
				if frame == nil then return fibers.always(nil, 'eof') end
				return fibers.always(assert(protocol.encode_line(frame)), nil)
			end,
			write_line_op = function (_, line)
				written[#written + 1] = assert(protocol.decode_line(line))
				return fibers.always(true, nil)
			end,
			flush_op = function () return fibers.always(true, nil) end,
			terminate = function () return true, nil end,
		}

		fibers.spawn(function ()
			assert_true(local_tx:send({ kind = 'publish', topic = { 'local', 'state' }, payload = { ok = true }, retain = true }))
			local_tx:close('local done')
		end)

		local st, rep, result = fibers.run_scope(function (scope)
			return fabric.run_link(scope, {
				link_id = 'link-composed',
				session = { local_node = 'host-a' },
				open_transport_op = function ()
					local wrapped, err = hal_transport.wrap_transport(transport)
					return fibers.always(wrapped, err)
				end,
				local_rx = local_rx,
				transfer_admission_rx = closed_rx('no transfers'),
				bridge = {
					export_publish_rules = {
						{ local_prefix = { 'local' }, remote_prefix = { 'remote' } },
					},
				},
			})
		end)

		assert_eq(st, 'ok')
		assert_eq(#rep.extra_errors, 0)
		assert_not_nil(result)
		assert_eq(result.snapshot.state, 'completed')
		assert_eq(result.snapshot.components.reader.status, 'ok')
		assert_eq(result.snapshot.components.session.status, 'ok')
		assert_eq(result.snapshot.components.writer.status, 'ok')
		assert_eq(result.snapshot.components.rpc_bridge.status, 'ok')
		assert_eq(result.snapshot.components.transfer_manager.status, 'ok')
		assert_eq(written[1].type, 'hello')
		assert_eq(written[1].node, 'host-a')
		assert_eq(written[2].type, 'pub')
		assert_eq(written[2].topic[1], 'remote')
	end)
end

function tests.test_public_fabric_run_uses_supplied_link_runner()
	fibers.run(function ()
		local called = false
		local st, _, result = fibers.run_scope(function (scope)
			return fabric.run(scope, {
				links = { { link_id = 'a', generation = 1 } },
				link_runner = function ()
					called = true
					return { link_id = 'a', snapshot = { state = 'completed' } }
				end,
			})
		end)
		assert_eq(st, 'ok')
		assert_true(called)
		assert_eq(result.snapshot.links.a.status, 'ok')
	end)
end

function tests.test_composed_link_transport_open_failure_fails_link_scope_before_components_start()
	fibers.run(function ()
		local st, _, primary = fibers.run_scope(function (scope)
			return fabric.run_link(scope, {
				link_id = 'bad-open',
				open_transport_op = function () return fibers.always(nil, 'open failed') end,
			})
		end)
		assert_eq(st, 'failed')
		assert_match(primary, 'open failed')
	end)
end

function tests.test_hal_transport_waits_for_raw_host_capability_before_open()
	fibers.run(function ()
		local bus = busmod.new()
		local conn = bus:connect()
		local opened = false

		local session = {
			read_line_op = function () return fibers.always(nil, 'closed') end,
			write_line_op = function () return fibers.always(true, nil) end,
			terminate = function () return true, nil end,
		}

		local ok_spawn, spawn_err = fibers.spawn(function ()
			fibers.perform(sleep.sleep_op(0.01))
			local ep = conn:bind({ 'raw', 'host', 'uart_manager', 'cap', 'uart', 'uart-0', 'rpc', 'open' })
			conn:retain({ 'raw', 'host', 'uart_manager', 'cap', 'uart', 'uart-0', 'status' }, {
				state = 'available',
				available = true,
			})
			local req = fibers.perform(ep:recv_op())
			opened = true
			assert_true(req:reply({ ok = true, reason = { session = session } }))
		end)
		assert_true(ok_spawn, tostring(spawn_err))

		local transport, err = fibers.perform(hal_transport.open_transport_op(conn, {
			source = 'uart_manager',
			class = 'uart',
			id = 'uart-0',
			ready_timeout_s = 0.5,
		}))

		assert_not_nil(transport, err)
		assert_true(opened, 'open should happen after the raw host capability is published')
	end)
end

return tests
