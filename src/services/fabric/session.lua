-- services/fabric/session.lua
--
-- One link child scope.
--
-- Child responsibilities:
--   * own transport/session/bridge/transfer mechanics for one link
--   * report only coarse summary upward to the fabric shell
--
-- Retained subtree ownership inside the child:
--   * session_ctl  -> state/fabric/link/<id>/session
--   * rpc_bridge   -> state/fabric/link/<id>/bridge
--   * transfer_mgr -> state/fabric/link/<id>/transfer
--
-- The outer fabric shell owns restart policy entirely.

local fibers         = require 'fibers'
local mailbox        = require 'fibers.mailbox'

local session_ctl    = require 'services.fabric.session_ctl'
local reader         = require 'services.fabric.reader'
local writer         = require 'services.fabric.writer'
local rpc_bridge     = require 'services.fabric.rpc_bridge'
local transfer_mgr   = require 'services.fabric.transfer_mgr'
local transport_uart = require 'services.fabric.transport_uart'

local M = {}

local function new_mailbox(cap)
	return mailbox.new(cap, { full = 'reject_newest' })
end

local function spawn_required(fn, what)
	local ok, err = fibers.spawn(fn)
	if ok ~= true then
		error((what or 'spawn_failed') .. ': ' .. tostring(err or 'spawn_failed'), 0)
	end
end

function M.run(params)
	assert(type(params) == 'table', 'session.run expects params table')

	local svc             = assert(params.svc, 'session.run requires svc')
	local root_conn       = assert(params.conn, 'session.run requires conn')
	local link_id         = assert(params.link_id, 'session.run requires link_id')
	local transfer_ctl_rx = assert(params.transfer_ctl_rx, 'session.run requires transfer_ctl_rx')
	local report_tx       = assert(params.report_tx, 'session.run requires report_tx')
	local cfg             = params.cfg or {}

	local transport, err = transport_uart.open(root_conn, link_id, cfg)
	if not transport then
		error('fabric session transport open failed: ' .. tostring(err), 0)
	end

	fibers.current_scope():finally(function()
		transport:close()
	end)

	local control_in_tx, control_in_rx = new_mailbox(32)
	local rpc_in_tx,     rpc_in_rx     = new_mailbox(64)
	local xfer_in_tx,    xfer_in_rx    = new_mailbox(64)

	local tx_control_tx, tx_control_rx = new_mailbox(32)
	local tx_rpc_tx,     tx_rpc_rx     = new_mailbox(128)
	local tx_bulk_tx,    tx_bulk_rx    = new_mailbox(64)

	local helper_done_tx, helper_done_rx = new_mailbox(64)
	local status_tx,      status_rx      = new_mailbox(64)

	local state_conn = root_conn:derive()
	local session = session_ctl.new_state(link_id, state_conn)

	local peer_conn = root_conn:derive({
		origin_factory = function()
			local snap = session:get()
			return {
				kind       = 'fabric_import',
				link_id    = link_id,
				peer_node  = snap.peer_node,
				peer_sid   = snap.peer_sid,
				generation = snap.generation,
			}
		end,
	})

	spawn_required(function()
		reader.run({
			transport          = transport,
			link_id            = link_id,
			svc                = svc,
			control_tx         = control_in_tx,
			rpc_tx             = rpc_in_tx,
			xfer_tx            = xfer_in_tx,
			status_tx          = status_tx,
			bad_frame_limit    = cfg.bad_frame_limit,
			bad_frame_window_s = cfg.bad_frame_window_s,
			read_timeout_s     = cfg.read_timeout_s,
		})
	end, 'reader_spawn')

	spawn_required(function()
		writer.run({
			transport    = transport,
			link_id      = link_id,
			tx_control   = tx_control_rx,
			tx_rpc       = tx_rpc_rx,
			tx_bulk      = tx_bulk_rx,
			status_tx    = status_tx,
			rpc_quantum  = cfg.rpc_quantum,
			bulk_quantum = cfg.bulk_quantum,
		})
	end, 'writer_spawn')

	spawn_required(function()
		session_ctl.run({
			link_id            = link_id,
			svc                = svc,
			session            = session,
			state_conn         = state_conn,
			report_tx          = report_tx,
			control_rx         = control_in_rx,
			status_rx          = status_rx,
			tx_control         = tx_control_tx,
			hello_interval_s   = cfg.hello_interval_s,
			ping_interval_s    = cfg.ping_interval_s,
			liveness_timeout_s = cfg.liveness_timeout_s,
			node_id            = cfg.node_id,
		})
	end, 'session_ctl_spawn')

	spawn_required(function()
		rpc_bridge.run({
			link_id               = link_id,
			svc                   = svc,
			conn                  = peer_conn,
			state_conn            = state_conn,
			session               = session,
			rpc_rx                = rpc_in_rx,
			tx_rpc                = tx_rpc_tx,
			status_tx             = status_tx,
			helper_done_rx        = helper_done_rx,
			helper_done_tx        = helper_done_tx,
			export_publish_rules  = cfg.export_publish_rules or cfg.export_publish,
			export_retained_rules = cfg.export_retained_rules,
			import_rules          = cfg.import_rules,
			outbound_call_rules   = cfg.outbound_call_rules,
			inbound_call_rules    = cfg.inbound_call_rules,
			max_pending_calls     = cfg.max_pending_calls,
			max_inbound_helpers   = cfg.max_inbound_helpers,
			call_timeout_s        = cfg.call_timeout_s,
		})
	end, 'rpc_bridge_spawn')

	spawn_required(function()
		transfer_mgr.run({
			link_id                  = link_id,
			conn                     = state_conn,
			session                  = session,
			xfer_rx                  = xfer_in_rx,
			tx_control               = tx_control_tx,
			tx_bulk                  = tx_bulk_tx,
			transfer_ctl_rx          = transfer_ctl_rx,
			chunk_size               = cfg.chunk_size,
			transfer_phase_timeout_s = cfg.transfer_phase_timeout_s,
		})
	end, 'transfer_mgr_spawn')

	-- Keep the child scope alive until one worker faults or the scope is
	-- cancelled. Restart policy lives entirely in the outer shell.
	return fibers.perform(fibers.current_scope():not_ok_op())
end

return M
