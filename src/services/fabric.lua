-- services/fabric.lua
--
-- Fabric service shell.
--
-- Shell responsibilities:
--   * consume retained cfg/fabric
--   * maintain one supervised link child per configured link
--   * expose service-level transfer RPC and route requests to the right link
--   * own and publish aggregate fabric state only

local fibers   = require 'fibers'
local mailbox  = require 'fibers.mailbox'
local sleep    = require 'fibers.sleep'

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
	}
end

local function retain_best_effort(conn, topic, payload)
	pcall(function() conn:retain(topic, payload) end)
end

local function unretain_best_effort(conn, topic)
	pcall(function() conn:unretain(topic) end)
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

local function spawn_link(state, svc, conn, ctl_tx, link_id, cfg)
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

	svc:obs_event('link_spawn', { link_id = link_id, ts = svc:now() })

	local ok, serr = child:spawn(function()
		session.run({
			svc = svc,
			conn = conn,
			link_id = link_id,
			cfg = cfg,
			transfer_ctl_rx = transfer_rx,
			report_tx = ctl_tx,
		})
	end)
	if not ok then
		state.links[link_id] = nil
		error('link spawn failed: ' .. tostring(serr), 0)
	end

	fibers.spawn(function()
		local st, rep, primary = fibers.perform(child:join_op())
		send_required(ctl_tx, {
			tag = 'link_exited',
			link_id = link_id,
			st = st,
			report = rep,
			primary = primary,
		}, 'fabric_ctl_overflow')
	end)
end

local function stop_link(state, link_id, reason)
	local rec = state.links[link_id]
	if not rec then return end
	if rec.scope then
		rec.scope:cancel(reason or 'stopped')
	end
end

local function reconcile(state, svc, conn, ctl_tx, cfg_payload)
	local next_desired = normalise_links(extract_cfg(cfg_payload))

	for link_id, cfg in pairs(next_desired) do
		local current = state.desired[link_id]
		state.desired[link_id] = cfg

		if not current then
			spawn_link(state, svc, conn, ctl_tx, link_id, cfg)
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
			stop_link(state, link_id, 'config_removed')
		end
	end

	publish_summary(conn, svc, state)
end

local function handle_link_exit(state, svc, conn, ctl_tx, ev)
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
		fibers.spawn(function()
			sleep.sleep(backoff)
			send_required(ctl_tx, {
				tag = 'restart_link',
				link_id = link_id,
			}, 'fabric_ctl_overflow')
		end)
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

function M.start(conn, opts)
	opts = opts or {}
	local svc = base.new(conn, { name = opts.name or 'fabric', env = opts.env })

	fibers.current_scope():finally(function()
		unretain_best_effort(conn, FABRIC_STATE_TOPIC)
	end)

	local ctl_tx, ctl_rx = q(64)
	local state = {
		desired = {},
		links = {},
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

	fibers.spawn(function()
		while true do
			local ev, err = cfg_watch:recv()
			if not ev then
				send_required(ctl_tx, {
					tag = 'cfg_watch_closed',
					err = err,
				}, 'fabric_ctl_overflow')
				return
			end

			if ev.op == 'retain' then
				send_required(ctl_tx, {
					tag = 'cfg_changed',
					cfg = ev.payload,
				}, 'fabric_ctl_overflow')
			elseif ev.op == 'unretain' then
				send_required(ctl_tx, {
					tag = 'cfg_changed',
					cfg = { links = {} },
				}, 'fabric_ctl_overflow')
			end
		end
	end)

	fibers.spawn(function()
		while true do
			local req, err = transfer_ep:recv()
			if not req then
				send_required(ctl_tx, {
					tag = 'transfer_ep_closed',
					err = err,
				}, 'fabric_ctl_overflow')
				return
			end
			send_required(ctl_tx, {
				tag = 'transfer_req',
				req = req,
			}, 'fabric_ctl_overflow')
		end
	end)

	while true do
		local ev = ctl_rx:recv()
		if not ev then
			error('fabric ctl closed', 0)
		end

		if ev.tag == 'cfg_changed' then
			reconcile(state, svc, conn, ctl_tx, ev.cfg)

		elseif ev.tag == 'transfer_req' then
			dispatch_transfer_req(state, ev.req)

		elseif ev.tag == 'link_summary' then
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

		elseif ev.tag == 'restart_link' then
			local cfg = state.desired[ev.link_id]
			if cfg and not state.links[ev.link_id] then
				spawn_link(state, svc, conn, ctl_tx, ev.link_id, cfg)
				publish_summary(conn, svc, state)
			end

		elseif ev.tag == 'link_exited' then
			handle_link_exit(state, svc, conn, ctl_tx, ev)

		elseif ev.tag == 'cfg_watch_closed' then
			svc:status('failed', { reason = tostring(ev.err or 'cfg_watch_closed') })
			error('fabric config watch closed: ' .. tostring(ev.err), 0)

		elseif ev.tag == 'transfer_ep_closed' then
			svc:status('failed', { reason = tostring(ev.err or 'transfer_ep_closed') })
			error('fabric transfer endpoint closed: ' .. tostring(ev.err), 0)

		else
			svc:obs_log('warn', { what = 'unknown_fabric_event', tag = tostring(ev.tag) })
		end
	end
end

return M
