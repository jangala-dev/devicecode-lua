-- services/fabric.lua
--
-- Fabric service.
--
-- Service-level responsibilities:
--   * consume retained cfg/fabric
--   * maintain one supervised link instance per configured link
--   * expose service-level transfer RPC and route jobs to the right link

local fibers   = require 'fibers'
local mailbox  = require 'fibers.mailbox'
local sleep    = require 'fibers.sleep'
local op       = require 'fibers.op'

local base     = require 'devicecode.service_base'
local session  = require 'services.fabric.session'

local M = {}

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

local function count_keys(t)
	local n = 0
	for _ in pairs(t) do n = n + 1 end
	return n
end

local function spawn_link_supervisor(scope, svc, conn, desired_ref, links_ref, link_id, cfg)
	return scope:spawn(function()
		while desired_ref[link_id] do
			local live_cfg = desired_ref[link_id] or cfg
			local backoff = tonumber(live_cfg.restart_backoff_s) or 2.0
			local transfer_ctl_tx, transfer_ctl_rx = mailbox.new(8, { full = 'reject_newest' })
			links_ref[link_id] = {
				id = link_id,
				cfg = live_cfg,
				transfer_ctl_tx = transfer_ctl_tx,
				child = nil,
			}

			local child, cerr = fibers.current_scope():child()
			if not child then error(cerr or 'failed to create link scope', 0) end
			links_ref[link_id].child = child

			svc:obs_event('link_spawn', { link_id = link_id, t = svc:now() })

			local ok_spawn, serr = child:spawn(function()
				session.run({
					svc = svc,
					conn = conn,
					link_id = link_id,
					cfg = live_cfg,
					transfer_ctl_rx = transfer_ctl_rx,
				})
			end)
			if not ok_spawn then
				links_ref[link_id] = nil
				error('link spawn failed: ' .. tostring(serr), 0)
			end

			local st, rep, primary = fibers.perform(child:join_op())
			links_ref[link_id] = nil
			if not desired_ref[link_id] then break end
			svc:obs_log('warn', {
				what = 'link_stopped',
				link_id = link_id,
				status = st,
				primary = primary,
				report = rep,
			})
			if st == 'ok' then
				break
			end
			sleep.sleep(backoff)
		end
	end)
end

function M.start(conn, opts)
	opts = opts or {}
	local svc = base.new(conn, { name = opts.name or 'fabric', env = opts.env })
	local links = {}
	local desired = {}

	svc:status('starting')
	svc:obs_log('info', { what = 'fabric_start' })

	local cfg_watch = conn:watch_retained({ 'cfg', 'fabric' }, {
		replay = true,
		queue_len = 8,
		full = 'drop_oldest',
	})

	local send_ep = conn:bind({ 'cmd', 'fabric', 'send_blob' }, { queue_len = 16 })
	local status_ep = conn:bind({ 'cmd', 'fabric', 'transfer_status' }, { queue_len = 16 })
	local abort_ep = conn:bind({ 'cmd', 'fabric', 'transfer_abort' }, { queue_len = 16 })

	local function route_transfer_job(payload, op_name)
		local timeout_s = (type(payload) == 'table' and type(payload.timeout) == 'number') and payload.timeout or 5.0
		local link_id = payload and payload.link_id
		if type(link_id) ~= 'string' or link_id == '' then
			return nil, 'missing_link_id'
		end
		local rec = links[link_id]
		if not rec or not rec.transfer_ctl_tx then
			return nil, 'no_such_link'
		end
		local reply_tx, reply_rx = mailbox.new(1, { full = 'reject_newest' })
		local job = {
			op = op_name,
			link_id = link_id,
			xfer_id = payload.xfer_id,
			source = payload.source or payload.data,
			meta = payload.meta,
			reason = payload.reason,
			reply_tx = reply_tx,
		}
		local ok, reason = rec.transfer_ctl_tx:send(job)
		if ok ~= true then return nil, reason or 'link_queue_closed' end
		local which, reply = fibers.perform(fibers.named_choice({
			reply = reply_rx:recv_op(),
			timeout = require('fibers.sleep').sleep_op(timeout_s):wrap(function() return nil end),
		}))
		if which == 'reply' and reply ~= nil then return reply, nil end
		return nil, 'timeout'
	end

	local function spawn_endpoint_handler(ep, op_name)
		fibers.spawn(function()
			while true do
				local req, err = ep:recv()
				if not req then return end
				local reply, rerr = route_transfer_job(req.payload or {}, op_name)
				if reply ~= nil then
					req:reply(reply)
				else
					req:fail(rerr or 'failed')
				end
			end
		end)
	end

	spawn_endpoint_handler(send_ep, 'send_blob')
	spawn_endpoint_handler(status_ep, 'status')
	spawn_endpoint_handler(abort_ep, 'abort')

	local function apply_config(cfg_payload)
		local cfg = extract_cfg(cfg_payload)
		local next_links = normalise_links(cfg)

		for link_id, rec in pairs(next_links) do
			local existing = desired[link_id]
			if not existing then
				desired[link_id] = rec
				local ok, err = spawn_link_supervisor(fibers.current_scope(), svc, conn, desired, links, link_id, rec)
				if not ok then
					desired[link_id] = nil
					svc:obs_log('error', { what = 'link_supervisor_failed', link_id = link_id, err = tostring(err) })
				end
			else
				desired[link_id] = rec
				if links[link_id] and links[link_id].cfg ~= rec and links[link_id].child then
					links[link_id].cfg = rec
					links[link_id].child:cancel('config_changed')
				end
			end
		end

		for link_id, _ in pairs(desired) do
			if not next_links[link_id] then
				desired[link_id] = nil
				local rec = links[link_id]
				if rec and rec.child then
					rec.child:cancel('config_removed')
				end
			end
		end

		svc:status('running', { links = count_keys(desired) })
		svc:obs_state('links', { links = count_keys(desired), ts = svc:now() })
	end

	while true do
		local ev, err = cfg_watch:recv()
		if not ev then
			svc:status('failed', { reason = tostring(err or 'cfg_watch_closed') })
			error('fabric config watch closed: ' .. tostring(err), 0)
		end
		if ev.op == 'retain' then
			apply_config(ev.payload)
		elseif ev.op == 'unretain' then
			apply_config({ links = {} })
		end
	end
end

return M
