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
-- The shell owns state.desired/state.links and arbitrates directly over its
-- event sources using a dynamic choice() set. Cross-owner reports from link
-- children still flow over a bounded mailbox.

local fibers   = require 'fibers'
local mailbox  = require 'fibers.mailbox'
local sleep    = require 'fibers.sleep'
local safe     = require 'coxpcall'

local base     = require 'devicecode.service_base'
local session  = require 'services.fabric.session'
local statefmt = require 'services.fabric.statefmt'

local M = {}

local FABRIC_STATE_TOPIC = { 'state', 'fabric' }

local function q(cap)
	return mailbox.new(cap, { full = 'reject_newest' })
end

local function send_required(tx, value, what)
	local ok, reason = tx:send(value)
	if ok ~= true then
		error((what or 'mailbox_send_failed') .. ': ' .. tostring(reason or 'closed'), 0)
	end
end

local function extract_cfg(payload)
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
				for kk, vv in pairs(v) do rec[kk] = vv end
				rec.id = id
				out[id] = rec
			end
		end
	end

	return out
end

local function same_plain(a, b, seen)
	if a == b then return true end
	if type(a) ~= type(b) then return false end
	if type(a) ~= 'table' then return false end

	seen = seen or {}
	if seen[a] == b then return true end
	seen[a] = b

	for k, va in pairs(a) do
		if not same_plain(va, b[k], seen) then return false end
	end
	for k in pairs(b) do
		if a[k] == nil then return false end
	end
	return true
end

local function count_keys(t)
	local n = 0
	for _ in pairs(t) do n = n + 1 end
	return n
end

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

local function retain_best_effort(conn, topic, payload)
	safe.pcall(function() conn:retain(topic, payload) end)
end

local function unretain_best_effort(conn, topic)
	safe.pcall(function() conn:unretain(topic) end)
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

	svc:status('running', status)
	svc:obs_state('summary', payload)
	retain_best_effort(conn, FABRIC_STATE_TOPIC, payload)
end

local function spawn_link(state, svc, conn, report_tx, link_id, cfg)
	local parent = fibers.current_scope()
	local child, err = parent:child()
	if not child then
		error(err or 'failed to create link scope', 0)
	end

	local transfer_tx, transfer_rx = q(8)

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
		session.run({
			svc = svc,
			conn = conn,
			link_id = link_id,
			cfg = cfg,
			transfer_ctl_rx = transfer_rx,
			report_tx = report_tx,
		})
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

local function reconcile(state, svc, conn, report_tx, cfg_payload)
	local next_desired = normalise_links(extract_cfg(cfg_payload))

	for link_id, cfg in pairs(next_desired) do
		local current = state.desired[link_id]
		state.desired[link_id] = cfg

		if not current then
			spawn_link(state, svc, conn, report_tx, link_id, cfg)
		elseif not same_plain(current, cfg) then
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
end

local function handle_link_exit(state, svc, conn, ev)
	local link_id = ev.link_id
	local rec = state.links[link_id]
	if rec then
		state.links[link_id] = nil
	end

	local desired = state.desired[link_id]
	if desired then
		svc:obs_log('warn', {
			what = 'link_stopped',
			link_id = link_id,
			status = ev.st,
			primary = ev.primary,
			report = ev.report,
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
		state.restart_at[link_id] = fibers.now() + backoff
	else
		state.restart_at[link_id] = nil
	end

	publish_summary(conn, svc, state)
end

local function dispatch_transfer_req(state, req)
	if req:done() then
		return
	end

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

local function cfg_event_op(cfg_watch)
	return cfg_watch:recv_op():wrap(function(ev, err)
		return { ev = ev, err = err }
	end)
end

local function transfer_event_op(transfer_ep)
	return transfer_ep:recv_op():wrap(function(req, err)
		return { req = req, err = err }
	end)
end

local function report_event_op(report_rx)
	return report_rx:recv_op():wrap(function(ev, err)
		return { ev = ev, err = err }
	end)
end

local function next_shell_event(state, cfg_watch, transfer_ep, report_rx)
	local ops = {
		cfg = cfg_event_op(cfg_watch),
		transfer = transfer_event_op(transfer_ep),
		report = report_event_op(report_rx),
	}

	for link_id, rec in pairs(state.links) do
		if rec.scope then
			ops['join:' .. link_id] = rec.scope:join_op():wrap(function(st, rep, primary)
				return {
					link_id = link_id,
					st = st,
					report = rep,
					primary = primary,
				}
			end)
		end
	end

	for link_id, at in pairs(state.restart_at) do
		local dt = at - fibers.now()
		if dt < 0 then dt = 0 end
		ops['restart:' .. link_id] = sleep.sleep_op(dt):wrap(function()
			return { link_id = link_id }
		end)
	end

	return fibers.named_choice(ops)
end

function M.start(conn, opts)
	opts = opts or {}
	local svc = base.new(conn, { name = opts.name or 'fabric', env = opts.env })

	fibers.current_scope():finally(function()
		unretain_best_effort(conn, FABRIC_STATE_TOPIC)
	end)

	local report_tx, report_rx = q(64)
	local state = {
		desired = {},
		links = {},
		restart_at = {},
	}

	svc:status('starting')
	svc:obs_log('info', { what = 'fabric_start' })

	local cfg_watch = conn:watch_retained({ 'cfg', 'fabric' }, {
		replay = true,
		queue_len = 8,
		full = 'drop_oldest',
	})

	local transfer_ep = conn:bind({ 'cmd', 'fabric', 'transfer' }, {
		queue_len = 32,
	})

	while true do
		local which, item = fibers.perform(next_shell_event(state, cfg_watch, transfer_ep, report_rx))

		if which == 'cfg' then
			if not item.ev then
				svc:status('failed', { reason = tostring(item.err or 'cfg_watch_closed') })
				error('fabric config watch closed: ' .. tostring(item.err), 0)
			end
			local ev = item.ev
			if ev.op == 'retain' then
				reconcile(state, svc, conn, report_tx, ev.payload)
			elseif ev.op == 'unretain' then
				reconcile(state, svc, conn, report_tx, { links = {} })
			elseif ev.op == 'replay_done' then
				-- nothing to do
			end

		elseif which == 'transfer' then
			if not item.req then
				svc:status('failed', { reason = tostring(item.err or 'transfer_ep_closed') })
				error('fabric transfer endpoint closed: ' .. tostring(item.err), 0)
			end
			dispatch_transfer_req(state, item.req)

		elseif which == 'report' then
			if not item.ev then
				error('fabric report channel closed: ' .. tostring(item.err), 0)
			end
			local ev = item.ev
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
				end
			else
				svc:obs_log('warn', { what = 'unknown_fabric_report', tag = tostring(ev.tag) })
			end

		elseif string.sub(which, 1, 5) == 'join:' then
			handle_link_exit(state, svc, conn, item)

		elseif string.sub(which, 1, 8) == 'restart:' then
			local link_id = item.link_id
			state.restart_at[link_id] = nil
			local cfg = state.desired[link_id]
			if cfg and not state.links[link_id] then
				spawn_link(state, svc, conn, report_tx, link_id, cfg)
				publish_summary(conn, svc, state)
			end

		else
			svc:obs_log('warn', { what = 'unknown_fabric_event', tag = tostring(which) })
		end
	end
end

return M
