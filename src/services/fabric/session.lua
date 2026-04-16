-- services/fabric/session.lua

local fibers         = require 'fibers'
local mailbox        = require 'fibers.mailbox'

local session_ctl    = require 'services.fabric.session_ctl'
local reader         = require 'services.fabric.reader'
local writer         = require 'services.fabric.writer'
local rpc_bridge     = require 'services.fabric.rpc_bridge'
local transfer_mgr   = require 'services.fabric.transfer_mgr'
local transport_uart = require 'services.fabric.transport_uart'

local M = {}

function M.run(scope, params)
	assert(type(params) == 'table', 'session.run expects params table')
	local svc = assert(params.svc, 'session.run requires svc')
	local root_conn = assert(params.conn, 'session.run requires conn')
	local link_id = assert(params.link_id, 'session.run requires link_id')
	local cfg = params.cfg or {}
	local transfer_ctl_rx = assert(params.transfer_ctl_rx, 'session.run requires transfer_ctl_rx')

	local transport, err = transport_uart.open(root_conn, link_id, cfg)
	if not transport then error('fabric session transport open failed: ' .. tostring(err), 0) end
	fibers.current_scope():finally(function() pcall(function() transport:close() end) end)

	local control_in_tx, control_in_rx = mailbox.new(32, { full = 'reject_newest' })
	local rpc_in_tx, rpc_in_rx = mailbox.new(64, { full = 'reject_newest' })
	local xfer_in_tx, xfer_in_rx = mailbox.new(64, { full = 'reject_newest' })

	local tx_control_tx, tx_control_rx = mailbox.new(32, { full = 'reject_newest' })
	local tx_rpc_tx, tx_rpc_rx = mailbox.new(128, { full = 'reject_newest' })
	local tx_bulk_tx, tx_bulk_rx = mailbox.new(64, { full = 'reject_newest' })

	local helper_done_tx, helper_done_rx = mailbox.new(64, { full = 'reject_newest' })
	local status_tx, status_rx = mailbox.new(64, { full = 'reject_newest' })

	local state_conn = root_conn
	local peer_conn = root_conn
	local bus = root_conn._bus
	if bus and type(bus.connect) == 'function' then
		state_conn = bus:connect({
			principal = root_conn:principal(),
		})
	end

	local session = session_ctl.new_state(link_id, state_conn)
	params.session = session

	if bus and type(bus.connect) == 'function' then
		peer_conn = bus:connect({
			principal = root_conn:principal(),
			origin_factory = function()
				local snap = session:get()
				return {
					kind = 'fabric_import',
					link_id = link_id,
					peer_node = snap.peer_node,
					peer_sid = snap.peer_sid,
					generation = snap.generation,
				}
			end,
		})
	end

	local common = {
		svc = svc,
		link_id = link_id,
		session = session,
	}

	fibers.spawn(function()
		reader.run({
			transport = transport,
			link_id = link_id,
			svc = svc,
			control_tx = control_in_tx,
			rpc_tx = rpc_in_tx,
			xfer_tx = xfer_in_tx,
			status_tx = status_tx,
			bad_frame_limit = cfg.bad_frame_limit,
			bad_frame_window_s = cfg.bad_frame_window_s,
			read_timeout_s = cfg.read_timeout_s,
		})
	end)

	fibers.spawn(function()
		writer.run({
			transport = transport,
			link_id = link_id,
			tx_control = tx_control_rx,
			tx_rpc = tx_rpc_rx,
			tx_bulk = tx_bulk_rx,
			status_tx = status_tx,
			rpc_quantum = cfg.rpc_quantum,
			bulk_quantum = cfg.bulk_quantum,
		})
	end)

	fibers.spawn(function()
		session_ctl.run({
			link_id = link_id,
			svc = svc,
			session = session,
			control_rx = control_in_rx,
			status_rx = status_rx,
			tx_control = tx_control_tx,
			hello_interval_s = cfg.hello_interval_s,
			ping_interval_s = cfg.ping_interval_s,
			liveness_timeout_s = cfg.liveness_timeout_s,
			node_id = cfg.node_id,
		})
	end)

	fibers.spawn(function()
		rpc_bridge.run({
			link_id = link_id,
			svc = svc,
			conn = peer_conn,
			session = session,
			rpc_rx = rpc_in_rx,
			tx_rpc = tx_rpc_tx,
			status_tx = status_tx,
			helper_done_rx = helper_done_rx,
			helper_done_tx = helper_done_tx,
			export_publish_rules = cfg.export_publish_rules or cfg.export_publish,
			export_retained_rules = cfg.export_retained_rules,
			import_rules = cfg.import_rules,
			outbound_call_rules = cfg.outbound_call_rules,
			inbound_call_rules = cfg.inbound_call_rules,
			max_pending_calls = cfg.max_pending_calls,
			max_inbound_helpers = cfg.max_inbound_helpers,
			call_timeout_s = cfg.call_timeout_s,
		})
	end)

	fibers.spawn(function()
		transfer_mgr.run({
			link_id = link_id,
			conn = state_conn,
			session = session,
			xfer_rx = xfer_in_rx,
			tx_control = tx_control_tx,
			tx_bulk = tx_bulk_tx,
			transfer_ctl_rx = transfer_ctl_rx,
			status_tx = status_tx,
			chunk_size = cfg.chunk_size,
			transfer_phase_timeout_s = cfg.transfer_phase_timeout_s,
		})
	end)
end

return M
