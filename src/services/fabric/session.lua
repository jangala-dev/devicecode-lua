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

local fibers         = require 'fibers'
local sleep          = require 'fibers.sleep'
local mailbox        = require 'fibers.mailbox'
local safe           = require 'coxpcall'

local session_ctl    = require 'services.fabric.session_ctl'
local reader         = require 'services.fabric.reader'
local writer         = require 'services.fabric.writer'
local rpc_bridge     = require 'services.fabric.rpc_bridge'
local transfer_mgr   = require 'services.fabric.transfer_mgr'
local transport_uart = require 'services.fabric.transport_uart'

local M = {}

local function q(cap)
	return mailbox.new(cap, { full = 'reject_newest' })
end

local function send_required(tx, value, what)
	local ok, reason = tx:send(value)
	if ok ~= true then
		error((what or 'mailbox_send_failed') .. ': ' .. tostring(reason or 'closed'), 0)
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
		safe.pcall(function() transport:close() end)
	end)

	local control_in_tx, control_in_rx = q(32)
	local rpc_in_tx,     rpc_in_rx     = q(64)
	local xfer_in_tx,    xfer_in_rx    = q(64)

	local tx_control_tx, tx_control_rx = q(32)
	local tx_rpc_tx,     tx_rpc_rx     = q(128)
	local tx_bulk_tx,    tx_bulk_rx    = q(64)

	local helper_done_tx, helper_done_rx = q(64)
	local status_tx,      status_rx      = q(64)

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

	-- Upward coarse summary reporter for the shell.
	fibers.spawn(function()
		local pulse = session:pulse()
		local last = nil

		while true do
			local snap = session:get()
			local summary = {
				state = snap.state,
				ready = snap.ready,
				established = snap.established,
				generation = snap.generation,
			}

			local changed = last == nil
				or last.state ~= summary.state
				or last.ready ~= summary.ready
				or last.established ~= summary.established
				or last.generation ~= summary.generation

			if changed then
				send_required(report_tx, {
					tag = 'link_summary',
					link_id = link_id,
					summary = summary,
				}, 'fabric_report_overflow')
				last = summary
			end

			local _, why = pulse:next()
			if why ~= nil then
				return
			end
		end
	end)

	fibers.spawn(function()
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
	end)

	fibers.spawn(function()
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
	end)

	fibers.spawn(function()
		session_ctl.run({
			link_id            = link_id,
			svc                = svc,
			session            = session,
			state_conn         = state_conn,
			control_rx         = control_in_rx,
			status_rx          = status_rx,
			tx_control         = tx_control_tx,
			hello_interval_s   = cfg.hello_interval_s,
			ping_interval_s    = cfg.ping_interval_s,
			liveness_timeout_s = cfg.liveness_timeout_s,
			node_id            = cfg.node_id,
		})
	end)

	fibers.spawn(function()
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
	end)

	fibers.spawn(function()
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
	end)

	-- Keep the child scope alive until one worker faults or the scope is cancelled.
	-- The shell joins the child scope and handles restart policy.
	while true do
		sleep.sleep(3600)
	end
end

return M
