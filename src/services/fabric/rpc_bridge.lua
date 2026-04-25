-- services/fabric/rpc_bridge.lua
--
-- Per-link RPC/pub-sub bridge.
--
-- Responsibilities:
--   * export selected local pub/unretain traffic to the remote peer
--   * import selected remote pub/unretain traffic locally
--   * bridge outbound local calls to remote fabric calls
--   * spawn bounded helpers for inbound remote calls
--   * own pending-call timeout bookkeeping
--   * publish retained bridge state:
--       state/fabric/link/<id>/bridge
--
-- Two call directions exist here:
--   * local endpoint -> remote `call`
--   * remote `call`  -> local helper fibre
--
-- Design notes:
--   * this module owns per-link call bridging only; it does not interpret
--     session handshake or transfer protocol
--   * the main loop is expressed as a choice over first-class events
--   * retained bridge state is observational only; protocol authority remains
--     in the live mailbox/session state

local fibers   = require 'fibers'
local runtime  = require 'fibers.runtime'
local sleep    = require 'fibers.sleep'
local uuid     = require 'uuid'

local protocol = require 'services.fabric.protocol'
local topicmap = require 'services.fabric.topicmap'
local statefmt = require 'services.fabric.statefmt'

local perform = fibers.perform
local named_choice = fibers.named_choice

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

local function topic_key(topic)
	local parts = {}
	for i = 1, #topic do
		local v = topic[i]
		local tv = type(v)
		local s = tostring(v)
		parts[#parts + 1] = tv:sub(1, 1) .. #s .. ':' .. s
	end
	return table.concat(parts, '|')
end

local function watch_topic_for_prefix(prefix, multi_wild)
	local t = {}
	for i = 1, #prefix do
		t[i] = prefix[i]
	end
	if #t == 0 or t[#t] ~= multi_wild then
		t[#t + 1] = multi_wild
	end
	return t
end

local function pending_count(pending)
	local n = 0
	for _ in pairs(pending) do
		n = n + 1
	end
	return n
end

local function nearest_deadline(pending)
	local best = math.huge
	for _, ent in pairs(pending) do
		if ent.deadline < best then
			best = ent.deadline
		end
	end
	return best
end

local function fail_pending(pending, reason)
	for id, ent in pairs(pending) do
		if ent.req and not ent.req:done() then
			ent.req:fail(reason)
		end
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

-- Bridge shell event selection.
--
-- state contains the live per-link bridge machinery:
--   * session / session_seen
--   * rpc_rx / helper_done_rx
--   * export_subs / retained_watches / endpoints
--   * pending :: id -> { req, deadline, generation }
--
-- The returned op resolves to one tagged event at a time.
local function next_bridge_event_op(state)
	local ops = {
		rpc_in = state.rpc_rx:recv_op(),
		helper_done = state.helper_done_rx:recv_op(),
		session = state.session:changed_op(state.session_seen),
	}

	for i = 1, #state.export_subs do
		ops['export:' .. tostring(i)] = state.export_subs[i]:recv_op()
	end

	for i = 1, #state.retained_watches do
		ops['retain:' .. tostring(i)] = state.retained_watches[i]:recv_op()
	end

	for i = 1, #state.endpoints do
		ops['endpoint:' .. tostring(i)] = state.endpoints[i]:recv_op()
	end

	local nd = nearest_deadline(state.pending)
	if nd < math.huge then
		local dt = nd - runtime.now()
		if dt < 0 then dt = 0 end
		ops.timeout = sleep.sleep_op(dt):wrap(function()
			return true
		end)
	end

	return named_choice(ops)
end

function M.run(ctx)
	local conn = assert(ctx.conn, 'rpc_bridge requires conn')
	local state_conn = assert(ctx.state_conn, 'rpc_bridge requires state_conn')
	local session = assert(ctx.session, 'rpc_bridge requires session')
	local rpc_rx = assert(ctx.rpc_rx, 'rpc_bridge requires rpc_rx')
	local tx_rpc = assert(ctx.tx_rpc, 'rpc_bridge requires tx_rpc')
	local status_tx = assert(ctx.status_tx, 'rpc_bridge requires status_tx')
	local helper_done_rx = assert(ctx.helper_done_rx, 'rpc_bridge requires helper_done_rx')
	local helper_done_tx = assert(ctx.helper_done_tx, 'rpc_bridge requires helper_done_tx')
	local link_id = assert(ctx.link_id, 'rpc_bridge requires link_id')
	local svc = ctx.svc

	local export_pub_rules = topicmap.normalise_prefix_rules(ctx.export_publish_rules or {}, 'export_publish')
	local export_retained_rules = topicmap.normalise_prefix_rules(ctx.export_retained_rules or {}, 'export_retained')
	local import_rules = topicmap.normalise_prefix_rules(ctx.import_rules or {}, 'import')
	local outbound_call_rules = topicmap.normalise_prefix_rules(ctx.outbound_call_rules or {}, 'outbound_call')
	local inbound_call_rules = topicmap.normalise_prefix_rules(ctx.inbound_call_rules or {}, 'inbound_call')

	local max_pending = tonumber(ctx.max_pending_calls) or 64
	local max_inbound_helpers = tonumber(ctx.max_inbound_helpers) or max_pending
	local call_timeout = tonumber(ctx.call_timeout_s) or 5.0
	local bridge_topic = statefmt.component_topic(link_id, 'bridge')

	local bus = conn._bus
	local multi_wild = (bus and bus._m_wild) or '#'

	local export_subs = {}
	for i = 1, #export_pub_rules do
		export_subs[i] = conn:subscribe(watch_topic_for_prefix(export_pub_rules[i].local_prefix, multi_wild))
	end

	local retained_watches = {}
	-- retained_cache[index][topic_key] = { topic = remote_topic, payload = ... }
	--
	-- This is only the bridge's replay cache. It mirrors what has been exported
	-- for retained replay after a session replacement or re-establishment.
	local retained_cache = {}
	local replay_pending = 0
	for i = 1, #export_retained_rules do
		retained_watches[i] = conn:watch_retained(
			watch_topic_for_prefix(export_retained_rules[i].local_prefix, multi_wild),
			{ replay = true, queue_len = 64, full = 'drop_oldest' }
		)
		retained_cache[i] = {}
		replay_pending = replay_pending + 1
	end

	local endpoints = {}
	for i = 1, #outbound_call_rules do
		endpoints[i] = conn:bind(outbound_call_rules[i].local_prefix, { queue_len = 16 })
	end

	-- pending[id] = {
	--   id = <wire call id>,
	--   req = <bus endpoint request>,
	--   deadline = <monotonic timeout>,
	--   generation = <session generation when sent>,
	-- }
	local pending = {}
	local inbound_helpers = 0
	local session_seen = session:pulse():version()
	local snap0 = session:get()
	local last_generation = snap0.generation
	local last_peer_sid = snap0.peer_sid
	local last_established = snap0.established
	local last_bridge = nil
	local last_rpc_ready = nil

	local state = {
		conn = conn,
		state_conn = state_conn,
		session = session,
		rpc_rx = rpc_rx,
		tx_rpc = tx_rpc,
		status_tx = status_tx,
		helper_done_rx = helper_done_rx,
		helper_done_tx = helper_done_tx,
		export_subs = export_subs,
		retained_watches = retained_watches,
		endpoints = endpoints,
		pending = pending,
		session_seen = session_seen,
	}

	-- Bridge readiness is purely the bridge's own replay readiness.
	-- session_ctl combines this with handshake establishment.
	local function current_rpc_ready()
		return replay_pending == 0
	end

	local function emit_rpc_ready(force)
		local ready = current_rpc_ready()
		if force or ready ~= last_rpc_ready then
			send_required(status_tx, { kind = 'rpc_ready', ready = ready }, 'rpc_ready_status')
			last_rpc_ready = ready
		end
	end

	local function publish_bridge_state(force)
		local snap = session:get()
		local status = {
			ready = current_rpc_ready(),
			replay_pending = replay_pending,
			pending_calls = pending_count(pending),
			inbound_helpers = inbound_helpers,
			session_generation = snap.generation,
			peer_sid = snap.peer_sid,
			established = snap.established,
		}

		local changed = force
			or last_bridge == nil
			or last_bridge.ready ~= status.ready
			or last_bridge.replay_pending ~= status.replay_pending
			or last_bridge.pending_calls ~= status.pending_calls
			or last_bridge.inbound_helpers ~= status.inbound_helpers
			or last_bridge.session_generation ~= status.session_generation
			or last_bridge.peer_sid ~= status.peer_sid
			or last_bridge.established ~= status.established

		if changed then
			state_conn:retain(bridge_topic, statefmt.link_component('bridge', link_id, status))
			last_bridge = status
		end
	end

	fibers.current_scope():finally(function()
		state_conn:unretain(bridge_topic)
	end)

	emit_rpc_ready(true)
	publish_bridge_state(true)

	local function fail_expired_pending_calls()
		local now = runtime.now()
		local changed = false
		for id, ent in pairs(pending) do
			if ent.deadline <= now then
				ent.req:fail('timeout')
				pending[id] = nil
				changed = true
			end
		end
		if changed then
			publish_bridge_state(false)
		end
	end

	local function on_session_change(snap)
		local session_replaced = (snap.generation ~= last_generation)
		local session_established = snap.established and (not last_established or snap.peer_sid ~= last_peer_sid)

		if session_replaced then
			last_generation = snap.generation
			fail_pending(pending, 'session_reset')
		end

		if session_replaced or session_established then
			emit_rpc_ready(true) -- clear edge during replay if watchers exist
			maybe_replay_retained(retained_cache, session, tx_rpc)
			emit_rpc_ready(true)
		end

		last_peer_sid = snap.peer_sid
		last_established = snap.established
		publish_bridge_state(false)
	end

	local function export_message(rule, msg)
		if is_import_origin(msg.origin, link_id) then return end
		local remote_topic = select(1, topicmap.map_local_to_remote_rule(rule, msg.topic))
		if not remote_topic then return end

		send_rpc(tx_rpc, {
			type = 'pub',
			topic = remote_topic,
			payload = msg.payload,
			retain = false,
		})
	end

	local function export_retained_event(rule, index, ev)
		if ev.op == 'replay_done' then
			if replay_pending > 0 then replay_pending = replay_pending - 1 end
			emit_rpc_ready(false)
			publish_bridge_state(false)
			return
		end

		if ev.origin and is_import_origin(ev.origin, link_id) then return end
		if not ev.topic then return end

		local remote_topic = select(1, topicmap.map_local_to_remote_rule(rule, ev.topic))
		if not remote_topic then return end

		local key = topic_key(remote_topic)
		if ev.op == 'retain' then
			retained_cache[index][key] = {
				topic = remote_topic,
				payload = ev.payload,
			}
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
			if svc then
				svc:obs_log('warn', {
					what = 'fabric_import_drop',
					reason = 'no_import_rule',
					link_id = link_id,
					frame = msg,
				})
			end
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
		if msg.ok then
			ent.req:reply(msg.value)
		else
			ent.req:fail(msg.err or 'remote_error')
		end
		publish_bridge_state(false)
	end

	local function spawn_local_call_helper(frame)
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
		publish_bridge_state(false)

		-- One helper fibre per inbound remote call. Helpers are bounded by the
		-- configured helper limit and report completion back through helper_done_tx.
		fibers.spawn(function()
			local timeout = tonumber(rule and rule.timeout) or call_timeout
			local ok, err = conn:call(local_topic, frame.payload, { timeout = timeout })
			send_required(helper_done_tx, {
				kind = 'local_call_done',
				id = frame.id,
				ok = ok ~= nil,
				value = ok,
				err = err,
			}, 'helper_done_overflow')
		end)
	end

	local function handle_outbound_call_request(rule, req)
		if #outbound_call_rules == 0 then
			req:fail('no_rules')
			return
		end
		if session:get().ready ~= true then
			req:fail('not_ready')
			return
		end
		if req:done() then return end

		local remote_topic = select(1, topicmap.map_local_to_remote_rule(rule, req.topic))
		if not remote_topic then
			req:fail('no_route')
			return
		end
		if pending_count(pending) >= max_pending then
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
		publish_bridge_state(false)
	end

	while true do
		fail_expired_pending_calls()

		state.session_seen = session_seen
		local which, a, b = perform(next_bridge_event_op(state))

		if which == 'rpc_in' then
			local item = a
			if not item then error(b or 'rpc_in_closed', 0) end

			local msg = item.msg or item
			if msg.type == 'pub' then
				handle_inbound_pub(msg)
			elseif msg.type == 'unretain' then
				handle_inbound_unretain(msg)
			elseif msg.type == 'reply' then
				handle_inbound_reply(msg)
			elseif msg.type == 'call' then
				spawn_local_call_helper(msg)
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
				publish_bridge_state(false)
			end

		elseif which == 'session' then
			session_seen = a or session_seen
			on_session_change(b or session:get())

		elseif which == 'timeout' then
			fail_expired_pending_calls()

		elseif which and which:match('^export:') then
			local index = tonumber(which:match('(%d+)$'))
			if not a then error(b or 'export_feed_closed', 0) end
			export_message(export_pub_rules[index], a)

		elseif which and which:match('^retain:') then
			local index = tonumber(which:match('(%d+)$'))
			if not a then error(b or 'retained_feed_closed', 0) end
			export_retained_event(export_retained_rules[index], index, a)

		elseif which and which:match('^endpoint:') then
			local index = tonumber(which:match('(%d+)$'))
			if not a then error(b or 'endpoint_feed_closed', 0) end
			handle_outbound_call_request(outbound_call_rules[index], a)
		end
	end
end

return M
