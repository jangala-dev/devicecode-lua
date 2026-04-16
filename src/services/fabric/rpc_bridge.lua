-- services/fabric/rpc_bridge.lua

local fibers   = require 'fibers'
local op       = require 'fibers.op'
local runtime  = require 'fibers.runtime'
local sleep    = require 'fibers.sleep'
local uuid     = require 'uuid'

local protocol = require 'services.fabric.protocol'
local topicmap = require 'services.fabric.topicmap'

local M = {}

local function send_required(tx, value, what)
	local ok, reason = tx:send(value)
	if ok ~= true then
		error((what or 'mailbox_send_failed') .. ': ' .. tostring(reason or 'closed'), 0)
	end
end

local function send_rpc(tx_rpc, frame)
	local item, err = protocol.writer_item('rpc', frame)
	if not item then error(err, 0) end
	send_required(tx_rpc, item, 'tx_rpc_overflow')
end

local function is_import_origin(origin, link_id)
	return origin
		and origin.kind == 'fabric_import'
		and origin.link_id == link_id
end

local function topic_id(prefix, i)
	return prefix .. tostring(i)
end

local function nearest_deadline(pending)
	local best = math.huge
	for _, ent in pairs(pending) do
		if ent.deadline < best then best = ent.deadline end
	end
	return best
end

local function count_pending(pending)
	local n = 0
	for _ in pairs(pending) do n = n + 1 end
	return n
end

local function fail_pending(pending, reason)
	for id, ent in pairs(pending) do
		if ent.req and not ent.req:done() then ent.req:fail(reason) end
		pending[id] = nil
	end
end

local function maybe_replay_retained(cache, session, tx_rpc)
	local snap = session:get()
	if not snap.established then return end
	for _, by_topic in pairs(cache) do
		for _, ev in pairs(by_topic) do
			send_rpc(tx_rpc, {
				type = 'pub',
				topic = ev.topic,
				payload = ev.payload,
				retain = true,
			})
		end
	end
end

function M.run(ctx)
	local conn = assert(ctx.conn, 'rpc_bridge requires conn')
	local session = assert(ctx.session, 'rpc_bridge requires session')
	local rpc_rx = assert(ctx.rpc_rx, 'rpc_bridge requires rpc_rx')
	local tx_rpc = assert(ctx.tx_rpc, 'rpc_bridge requires tx_rpc')
	local status_tx = assert(ctx.status_tx, 'rpc_bridge requires status_tx')
	local helper_done_rx = assert(ctx.helper_done_rx, 'rpc_bridge requires helper_done_rx')
	local helper_done_tx = assert(ctx.helper_done_tx, 'rpc_bridge requires helper_done_tx')
	local link_id = assert(ctx.link_id, 'rpc_bridge requires link_id')
	local svc = ctx.svc

	local export_pub_rules = topicmap.normalise_prefix_rules(ctx.export_publish_rules or ctx.export_rules or {}, 'export_publish')
	local export_retained_rules = topicmap.normalise_prefix_rules(ctx.export_retained_rules or {}, 'export_retained')
	local import_rules = topicmap.normalise_prefix_rules(ctx.import_rules or {}, 'import')
	local outbound_call_rules = topicmap.normalise_prefix_rules(ctx.outbound_call_rules or {}, 'outbound_call')
	local inbound_call_rules = topicmap.normalise_prefix_rules(ctx.inbound_call_rules or {}, 'inbound_call')

	local max_pending = tonumber(ctx.max_pending_calls) or 64
	local max_inbound_helpers = tonumber(ctx.max_inbound_helpers) or max_pending
	local call_timeout = tonumber(ctx.call_timeout_s) or 5.0

	local export_subs = {}
	for i = 1, #export_pub_rules do
		export_subs[i] = conn:subscribe(export_pub_rules[i].local_prefix)
	end

	local retained_watches = {}
	local retained_cache = {}
	local replay_pending = 0
	for i = 1, #export_retained_rules do
		retained_watches[i] = conn:watch_retained(export_retained_rules[i].local_prefix, {
			replay = true,
			queue_len = 64,
			full = 'drop_oldest',
		})
		retained_cache[i] = {}
		replay_pending = replay_pending + 1
	end

	local endpoints = {}
	for i = 1, #outbound_call_rules do
		endpoints[i] = conn:bind(outbound_call_rules[i].local_prefix, { queue_len = 16 })
	end

	send_required(status_tx, { kind = 'rpc_ready', ready = (replay_pending == 0) }, 'rpc_ready_status')

	local pending = {}
	local inbound_helpers = 0
	local session_seen = session:pulse():version()
	local snap0 = session:get()
	local last_generation = snap0.generation
	local last_peer_sid = snap0.peer_sid
	local last_established = snap0.established

	local function maybe_fail_expired()
		local now = runtime.now()
		for id, ent in pairs(pending) do
			if ent.deadline <= now then
				ent.req:fail('timeout')
				pending[id] = nil
			end
		end
	end

	local function on_session_change()
		local snap = session:get()
		local session_replaced = (snap.generation ~= last_generation)
		local session_established = snap.established and (not last_established or snap.peer_sid ~= last_peer_sid)
		if session_replaced then
			last_generation = snap.generation
			fail_pending(pending, 'session_reset')
		end
		if session_replaced or session_established then
			send_required(status_tx, { kind = 'rpc_ready', ready = false }, 'rpc_ready_status')
			maybe_replay_retained(retained_cache, session, tx_rpc)
			send_required(status_tx, { kind = 'rpc_ready', ready = (replay_pending == 0) }, 'rpc_ready_status')
		end
		last_peer_sid = snap.peer_sid
		last_established = snap.established
	end

	local function export_message(rule, msg)
		if is_import_origin(msg.origin, link_id) then return end
		local remote_topic = select(1, topicmap.map_local_to_remote({ rule }, msg.topic))
		if not remote_topic then return end
		send_rpc(tx_rpc, {
			type = 'pub',
			topic = remote_topic,
			payload = msg.payload,
			retain = false,
		})
	end

	local function retained_key(topic)
		return table.concat((function()
			local t = {}
			for i = 1, #topic do t[#t + 1] = tostring(topic[i]) end
			return t
		end)(), '/')
	end

	local function export_retained_event(rule, index, ev)
		if ev.op == 'replay_done' then
			if replay_pending > 0 then replay_pending = replay_pending - 1 end
			send_required(status_tx, { kind = 'rpc_ready', ready = (replay_pending == 0) }, 'rpc_ready_status')
			return
		end
		if ev.origin and is_import_origin(ev.origin, link_id) then return end
		if not ev.topic then return end
		local remote_topic = select(1, topicmap.map_local_to_remote({ rule }, ev.topic))
		if not remote_topic then return end
		local key = retained_key(remote_topic)
		if ev.op == 'retain' then
			retained_cache[index][key] = { topic = remote_topic, payload = ev.payload }
			send_rpc(tx_rpc, {
				type = 'pub',
				topic = remote_topic,
				payload = ev.payload,
				retain = true,
			})
		elseif ev.op == 'unretain' then
			retained_cache[index][key] = nil
			send_rpc(tx_rpc, {
				type = 'unretain',
				topic = remote_topic,
			})
		end
	end

	local function handle_inbound_pub(msg)
		local local_topic = select(1, topicmap.map_remote_to_local(import_rules, msg.topic))
		if not local_topic then
			if svc then svc:obs_log('warn', { what = 'fabric_import_drop', reason = 'no_import_rule', link_id = link_id, frame = msg }) end
			return
		end
		if msg.retain then
			conn:retain(local_topic, msg.payload)
		else
			conn:publish(local_topic, msg.payload)
		end
	end

	local function handle_inbound_unretain(msg)
		local local_topic = select(1, topicmap.map_remote_to_local(import_rules, msg.topic))
		if not local_topic then return end
		conn:unretain(local_topic)
	end

	local function handle_inbound_reply(msg)
		local ent = pending[msg.id]
		if not ent then return end
		pending[msg.id] = nil
		if msg.ok then ent.req:reply(msg.value) else ent.req:fail(msg.err or 'remote_error') end
	end

	local function spawn_inbound_helper(frame)
		if inbound_helpers >= max_inbound_helpers then
			send_rpc(tx_rpc, { type = 'reply', id = frame.id, ok = false, err = 'busy' })
			return
		end
		local local_topic, rule = topicmap.map_remote_to_local(inbound_call_rules, frame.topic)
		if not local_topic then
			send_rpc(tx_rpc, { type = 'reply', id = frame.id, ok = false, err = 'no_route' })
			return
		end
		inbound_helpers = inbound_helpers + 1
		fibers.spawn(function()
			local ok, err
			local timeout = tonumber(rule and rule.timeout) or call_timeout
			ok, err = conn:call(local_topic, frame.payload, { timeout = timeout })
			send_required(helper_done_tx, {
				kind = 'local_call_done',
				id = frame.id,
				ok = ok ~= nil,
				value = ok,
				err = err,
			}, 'helper_done_overflow')
		end)
	end

	local function handle_inbound_call(frame)
		spawn_inbound_helper(frame)
	end

	local function handle_endpoint_call(rule, req)
		if #outbound_call_rules == 0 then
			req:fail('no_rules')
			return
		end
		if session:get().ready ~= true then
			req:fail('not_ready')
			return
		end
		if req:done() then return end
		local remote_topic = select(1, topicmap.map_local_to_remote({ rule }, req.topic))
		if not remote_topic then
			req:fail('no_route')
			return
		end
		if count_pending(pending) >= max_pending then
			req:fail('pending_full')
			return
		end
		local id = tostring(uuid.new())
		pending[id] = {
			id = id,
			req = req,
			deadline = runtime.now() + (tonumber(rule.timeout) or call_timeout),
			generation = session:get().generation,
		}
		send_rpc(tx_rpc, {
			type = 'call',
			id = id,
			topic = remote_topic,
			payload = req.payload,
		})
	end

	while true do
		maybe_fail_expired()

		local ops = {
			rpc_in = rpc_rx:recv_op(),
			helper_done = helper_done_rx:recv_op(),
			session = session:pulse():changed_op(session_seen),
		}
		for i = 1, #export_subs do ops[topic_id('export_', i)] = export_subs[i]:recv_op() end
		for i = 1, #retained_watches do ops[topic_id('retain_', i)] = retained_watches[i]:recv_op() end
		for i = 1, #endpoints do ops[topic_id('endpoint_', i)] = endpoints[i]:recv_op() end

		local nd = nearest_deadline(pending)
		if nd < math.huge then
			local dt = nd - runtime.now()
			if dt < 0 then dt = 0 end
			ops.timeout = sleep.sleep_op(dt):wrap(function() return true end)
		end

		local which, a, b = fibers.perform(fibers.named_choice(ops))
		if which == 'rpc_in' then
			local item = a
			if not item then error(b or 'rpc_in_closed', 0) end
			local msg = item.msg or item
			if msg.type == 'pub' then handle_inbound_pub(msg)
			elseif msg.type == 'unretain' then handle_inbound_unretain(msg)
			elseif msg.type == 'reply' then handle_inbound_reply(msg)
			elseif msg.type == 'call' then handle_inbound_call(msg)
			end
		elseif which == 'helper_done' then
			local item = a
			if item and item.kind == 'local_call_done' then
				if inbound_helpers > 0 then inbound_helpers = inbound_helpers - 1 end
				send_rpc(tx_rpc, {
					type = 'reply',
					id = item.id,
					ok = not not item.ok,
					value = item.value,
					err = item.err,
				})
			end
		elseif which == 'session' then
			session_seen = a or session_seen
			on_session_change()
		elseif which == 'timeout' then
			maybe_fail_expired()
		elseif which and which:match('^export_') then
			local index = tonumber(which:match('(%d+)$'))
			if not a then error(b or 'export_feed_closed', 0) end
			export_message(export_pub_rules[index], a)
		elseif which and which:match('^retain_') then
			local index = tonumber(which:match('(%d+)$'))
			if not a then error(b or 'retained_feed_closed', 0) end
			export_retained_event(export_retained_rules[index], index, a)
		elseif which and which:match('^endpoint_') then
			local index = tonumber(which:match('(%d+)$'))
			if not a then error(b or 'endpoint_feed_closed', 0) end
			handle_endpoint_call(outbound_call_rules[index], a)
		end
	end
end

return M
