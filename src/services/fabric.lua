-- services/fabric.lua
--
-- Fabric service shell.
--
-- Shell responsibilities:
--   * consume retained cfg/fabric
--   * maintain one supervised link child per configured link
--   * expose service-level transfer RPC and route requests to the right link
--   * own and publish aggregate fabric state only
--
-- Ownership model:
--   * fabric.lua       -> aggregate shell state and restart policy
--   * session.lua      -> one link child scope
--   * session_ctl.lua  -> handshake, readiness, liveness
--   * rpc_bridge.lua   -> pub/rpc bridging
--   * transfer_mgr.lua -> object transfer
--   * reader/writer    -> framed I/O only
--
-- Cross-owner reports from link children flow upward over a bounded mailbox.

local fibers   = require 'fibers'
local mailbox  = require 'fibers.mailbox'
local sleep    = require 'fibers.sleep'

local base     = require 'devicecode.service_base'
local session  = require 'services.fabric.session'
local statefmt = require 'services.fabric.statefmt'
local topics   = require 'services.fabric.topics'

local perform = fibers.perform
local named_choice = fibers.named_choice
local run_scope = fibers.run_scope
local now = fibers.now

local M = {}

local FABRIC_STATE_TOPIC = { 'state', 'fabric' }

local function new_mailbox(cap)
	return mailbox.new(cap, { full = 'reject_newest' })
end

local function send_required(tx, value, what)
	local ok, reason = tx:send(value)
	if ok ~= true then
		error((what or 'mailbox_send_failed') .. ': ' .. tostring(reason or 'closed'), 0)
	end
end

----------------------------------------------------------------------
-- Config normalisation
----------------------------------------------------------------------

local function extract_fabric_cfg(payload)
	if type(payload) ~= 'table' then return {} end
	local data = payload.data or payload
	if type(data) ~= 'table' then return {} end
	return data
end

local function normalise_links(cfg)
	local links = cfg.links or cfg
	local out = {}
	if type(links) ~= 'table' then return out end

	for k, v in pairs(links) do
		if type(v) == 'table' then
			local id = v.id or v.link_id or k
			if type(id) == 'string' and id ~= '' then
				local rec = {}
				for kk, vv in pairs(v) do
					rec[kk] = vv
				end
				rec.id = id
				out[id] = rec
			end
		end
	end

	return out
end

local function deep_equal_plain(a, b, seen)
	if a == b then return true end
	if type(a) ~= type(b) then return false end
	if type(a) ~= 'table' then return false end

	seen = seen or {}
	if seen[a] == b then return true end
	seen[a] = b

	for k, va in pairs(a) do
		if not deep_equal_plain(va, b[k], seen) then
			return false
		end
	end
	for k in pairs(b) do
		if a[k] == nil then
			return false
		end
	end
	return true
end

local function count_keys(t)
	local n = 0
	for _ in pairs(t) do
		n = n + 1
	end
	return n
end

----------------------------------------------------------------------
-- Aggregate publication
----------------------------------------------------------------------

local function link_summary(rec)
	local s = rec.summary or {}
	return {
		state = s.state or 'starting',
		ready = not not s.ready,
		established = not not s.established,
		generation = s.generation,
		member_class = rec.cfg and rec.cfg.member_class or nil,
		link_class = rec.cfg and rec.cfg.link_class or nil,
		node_id = rec.cfg and rec.cfg.node_id or nil,
	}
end

local function publish_summary(conn, svc, state)
	local links = {}
	for link_id, rec in pairs(state.links) do
		links[link_id] = link_summary(rec)
	end

	local status = {
		desired = count_keys(state.desired),
		live = count_keys(state.links),
	}

	local payload = statefmt.summary(status, links, { ts = svc:now() })

	svc:set_ready(true, status)
	svc:obs_state('summary', payload)
	conn:retain(FABRIC_STATE_TOPIC, payload)
end

local function same_plain(a, b)
	if a == nil or b == nil then return a == b end
	for k, v in pairs(a) do
		if b[k] ~= v then return false end
	end
	for k, v in pairs(b) do
		if a[k] ~= v then return false end
	end
	return true
end

local function publish_transfer_manager(conn, svc, state)
	local live = count_keys(state.links)
	conn:retain(topics.transfer_mgr_meta(), {
		owner = svc.name,
		interface = 'devicecode.cap/transfer-manager/1',
		methods = { ['send-blob'] = true },
		events = { ['status-changed'] = true },
	})
	local status = {
		state = 'available',
		live_links = live,
		desired_links = count_keys(state.desired),
	}
	if not same_plain(state.transfer_mgr_status, status) then
		state.transfer_mgr_status = status
		conn:retain(topics.transfer_mgr_status(), status)
		conn:publish(topics.transfer_mgr_event('status-changed'), status)
	else
		conn:retain(topics.transfer_mgr_status(), status)
	end
end

----------------------------------------------------------------------
-- Link child lifecycle
----------------------------------------------------------------------

local function spawn_link(state, svc, conn, report_tx, link_id, cfg)
	local parent = fibers.current_scope()
	local child, err = parent:child()
	if not child then
		error(err or 'failed to create link scope', 0)
	end

	local transfer_tx, transfer_rx = new_mailbox(8)

	state.links[link_id] = {
		id = link_id,
		cfg = cfg,
		scope = child,
		transfer_tx = transfer_tx,
		summary = {
			state = 'starting',
			ready = false,
			established = false,
			generation = nil,
		},
	}
	state.restart_at[link_id] = nil

	svc:obs_event('link_spawn', { link_id = link_id, ts = svc:now() })

	local ok, serr = child:spawn(function()
		local link_conn = conn:derive()

		local st, _report, primary = run_scope(function()
			return session.run({
				svc = svc,
				conn = link_conn,
				link_id = link_id,
				cfg = cfg,
				transfer_ctl_rx = transfer_rx,
				report_tx = report_tx,
			})
		end)

		send_required(report_tx, {
			tag = 'link_exit',
			link_id = link_id,
			st = st or 'ok',
			primary = primary,
		}, 'fabric_link_exit_report')

		if st == 'failed' then
			error(primary or 'link_failed', 0)
		end
	end)

	if not ok then
		state.links[link_id] = nil
		error('link spawn failed: ' .. tostring(serr), 0)
	end
end

local function stop_link(state, link_id, reason)
	local rec = state.links[link_id]
	if not rec then return end
	if rec.scope then
		rec.scope:cancel(reason or 'stopped')
	end
end

local function handle_link_exit(state, svc, conn, ev)
	local link_id = ev.link_id
	local rec = state.links[link_id]

	if rec then
		state.links[link_id] = nil
		if rec.scope then
			-- Destructive join is acceptable here: the child has exited and the
			-- shell is reclaiming the link scope.
			perform(rec.scope:join_op())
		end
	end

	local desired = state.desired[link_id]
	if desired then
		svc:obs_log('warn', {
			what = 'link_stopped',
			link_id = link_id,
			status = ev.st,
			primary = ev.primary,
		})
	else
		svc:obs_event('link_removed', {
			link_id = link_id,
			status = ev.st,
			primary = ev.primary,
			ts = svc:now(),
		})
	end

	if desired then
		local backoff = tonumber(desired.restart_backoff_s) or 2.0
		state.restart_at[link_id] = now() + backoff
	else
		state.restart_at[link_id] = nil
	end

	publish_summary(conn, svc, state)
	publish_transfer_manager(conn, svc, state)
end

local function dispatch_transfer_request(state, req)
	if req:done() then return end

	local payload = req.payload or {}
	local link_id = payload.link_id
	local op_name = payload.op

	if type(link_id) ~= 'string' or link_id == '' then
		req:fail('missing_link_id')
		return
	end

	if op_name ~= 'send_blob' and op_name ~= 'status' and op_name ~= 'abort' then
		req:fail('unsupported_op')
		return
	end

	local rec = state.links[link_id]
	if not rec or not rec.transfer_tx then
		req:fail('no_such_link')
		return
	end

	local ok, reason = rec.transfer_tx:send(req)
	if ok ~= true then
		req:fail(reason or 'link_queue_closed')
	end
end

----------------------------------------------------------------------
-- Reconcile and event selection
----------------------------------------------------------------------

local function reconcile(state, svc, conn, report_tx, cfg_payload)
	local next_desired = normalise_links(extract_fabric_cfg(cfg_payload))

	for link_id, cfg in pairs(next_desired) do
		local current = state.desired[link_id]
		state.desired[link_id] = cfg

		if not current then
			spawn_link(state, svc, conn, report_tx, link_id, cfg)
		elseif not deep_equal_plain(current, cfg) then
			local rec = state.links[link_id]
			if rec then
				rec.cfg = cfg
				stop_link(state, link_id, 'config_changed')
			end
		end
	end

	for link_id in pairs(state.desired) do
		if not next_desired[link_id] then
			state.desired[link_id] = nil
			state.restart_at[link_id] = nil
			stop_link(state, link_id, 'config_removed')
		end
	end

	publish_summary(conn, svc, state)
	publish_transfer_manager(conn, svc, state)
end

-- All shell concerns are first-class events:
--   * config changes
--   * transfer requests
--   * child reports
--   * restart timers
local function next_shell_event_op(state, cfg_watch, transfer_ep, report_rx)
	local ops = {
		cfg = cfg_watch:recv_op(),
		transfer = transfer_ep:recv_op(),
		report = report_rx:recv_op(),
	}

	for link_id, at in pairs(state.restart_at) do
		local dt = at - now()
		if dt < 0 then dt = 0 end
		ops['restart:' .. link_id] = sleep.sleep_op(dt):wrap(function()
			return link_id
		end)
	end

	return named_choice(ops)
end

function M.start(conn, opts)
	opts = opts or {}
	local svc = base.new(conn, { name = opts.name or 'fabric', env = opts.env })

	fibers.current_scope():finally(function()
		conn:unretain(FABRIC_STATE_TOPIC)
	conn:unretain(topics.transfer_mgr_meta())
	conn:unretain(topics.transfer_mgr_status())
	end)

	svc:announce({
		role = 'fabric',
		caps = { transfer = true, summary = true },
		state_topic = FABRIC_STATE_TOPIC,
	})

	local report_tx, report_rx = new_mailbox(64)
	local state = {
		desired = {},
		links = {},
		restart_at = {},
		transfer_mgr_status = nil,
	}

	svc:starting({ desired = 0, live = 0 })
	svc:obs_log('info', { what = 'fabric_start' })

	local cfg_watch = conn:watch_retained({ 'cfg', 'fabric' }, {
		replay = true,
		queue_len = 8,
		full = 'drop_oldest',
	})

	publish_transfer_manager(conn, svc, state)

	local transfer_ep = conn:bind(topics.transfer_mgr_rpc('send-blob'), {
		queue_len = 32,
	})

	while true do
		local which, a, b = perform(next_shell_event_op(state, cfg_watch, transfer_ep, report_rx))

		if which == 'cfg' then
			local ev, err = a, b
			if not ev then
				svc:failed(tostring(err or 'cfg_watch_closed'))
				error('fabric config watch closed: ' .. tostring(err), 0)
			end

			if ev.op == 'retain' then
				reconcile(state, svc, conn, report_tx, ev.payload)
			elseif ev.op == 'unretain' then
				reconcile(state, svc, conn, report_tx, { links = {} })
			elseif ev.op == 'replay_done' then
				-- nothing further to do
			end

		elseif which == 'transfer' then
			local req, err = a, b
			if not req then
				svc:failed(tostring(err or 'transfer_ep_closed'))
				error('fabric transfer endpoint closed: ' .. tostring(err), 0)
			end
			dispatch_transfer_request(state, req)

		elseif which == 'report' then
			local ev, err = a, b
			if not ev then
				error('fabric report channel closed: ' .. tostring(err), 0)
			end

			if ev.tag == 'link_summary' then
				local rec = state.links[ev.link_id]
				if rec then
					rec.summary = {
						state = ev.summary and ev.summary.state or 'unknown',
						ready = ev.summary and ev.summary.ready or false,
						established = ev.summary and ev.summary.established or false,
						generation = ev.summary and ev.summary.generation or nil,
					}
					publish_summary(conn, svc, state)
	publish_transfer_manager(conn, svc, state)
				end

			elseif ev.tag == 'link_exit' then
				handle_link_exit(state, svc, conn, ev)

			else
				svc:obs_log('warn', {
					what = 'unknown_fabric_report',
					tag = tostring(ev.tag),
				})
			end

		elseif which and which:sub(1, 8) == 'restart:' then
			local link_id = a
			state.restart_at[link_id] = nil

			local cfg = state.desired[link_id]
			if cfg and not state.links[link_id] then
				spawn_link(state, svc, conn, report_tx, link_id, cfg)
				publish_summary(conn, svc, state)
	publish_transfer_manager(conn, svc, state)
			end

		else
			svc:obs_log('warn', {
				what = 'unknown_fabric_event',
				tag = tostring(which),
			})
		end
	end
end

return M
