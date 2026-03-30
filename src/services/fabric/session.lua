-- services/fabric/session.lua
--
-- One fabric session per configured link.
--
-- This version makes readiness explicit:
--   * opening     : transport open / local setup incomplete
--   * session_up  : peer session established, local setup not yet complete
--   * ready       : peer session established and local forwarding surfaces installed
--   * down        : terminal state published on failure
--
-- Current features:
--   * UART transport
--   * local export publish forwarding
--   * remote import publish forwarding
--   * local proxy calls -> remote calls
--   * remote calls -> local calls
--
-- Deliberate omissions remain:
--   * transfer streams
--   * retained local->remote unretain propagation
--   * wire auth

local fibers   = require 'fibers'
local sleep    = require 'fibers.sleep'
local mailbox  = require 'fibers.mailbox'
local authz    = require 'devicecode.authz'

local protocol = require 'services.fabric.protocol'
local topicmap = require 'services.fabric.topicmap'
local uart_tx  = require 'services.fabric.transport_uart'

local perform      = fibers.perform
local named_choice = fibers.named_choice

local M = {}

local function topic_s(t)
	return table.concat(t or {}, '/')
end

local function publish_link_state(conn, svc, link_id, fields)
	local payload = { link_id = link_id, t = svc:now() }
	for k, v in pairs(fields or {}) do payload[k] = v end
	conn:retain({ 'state', 'fabric', 'link', link_id }, payload)
end

local function choose_transport(svc, link_cfg)
	local k = (((link_cfg.transport or {}).kind) or 'uart')
	if k == 'uart' then
		return uart_tx.new(svc, link_cfg.transport)
	end
	error('fabric: unsupported transport kind ' .. tostring(k), 0)
end

local function max2(a, b)
	if a == nil then return b end
	if b == nil then return a end
	return (a > b) and a or b
end

local function keepalive_cfg(link_cfg)
	local ka = (type(link_cfg.keepalive) == 'table') and link_cfg.keepalive or {}
	return {
		hello_retry_s = (type(ka.hello_retry_s) == 'number') and ka.hello_retry_s or 10.0,
		idle_ping_s   = (type(ka.idle_ping_s)   == 'number') and ka.idle_ping_s   or 15.0,
		stale_after_s = (type(ka.stale_after_s) == 'number') and ka.stale_after_s or 45.0,
	}
end

local function new_pending_store()
	local by_id = {}

	local store = {}

	function store:open(id)
		local tx, rx = mailbox.new(1, { full = 'reject_newest' })
		by_id[id] = { tx = tx, rx = rx }
		return rx
	end

	function store:deliver(id, msg)
		local rec = by_id[id]
		if not rec then return false end
		rec.tx:send(msg)
		rec.tx:close('done')
		by_id[id] = nil
		return true
	end

	function store:close(id, reason)
		local rec = by_id[id]
		if not rec then return false end
		rec.tx:close(reason or 'closed')
		by_id[id] = nil
		return true
	end

	function store:close_all(reason)
		for id, rec in pairs(by_id) do
			rec.tx:close(reason or 'closed')
			by_id[id] = nil
		end
	end

	return store
end

local function start_export_publishers(conn, svc, transport, link_id, export_cfg, send_frame, mark_ready)
	for i = 1, #(export_cfg.publish or {}) do
		local rule = export_cfg.publish[i]
		fibers.spawn(function()
			local sub = conn:subscribe(rule.local_topic, {
				queue_len = rule.queue_len or 50,
				full      = 'drop_oldest',
			})

			mark_ready('export')

			svc:obs_log('info', {
				what     = 'export_publish_started',
				link_id  = link_id,
				local_t  = topic_s(rule.local_topic),
				remote_t = topic_s(rule.remote_topic),
			})

			while true do
				local msg, err = perform(sub:recv_op())
				if not msg then
					svc:obs_log('warn', {
						what    = 'export_publish_stopped',
						link_id = link_id,
						err     = tostring(err),
					})
					return
				end

				local remote_topic = topicmap.apply_first({ rule }, msg.topic, 'local_topic', 'remote_topic')
				if remote_topic then
					local ok, serr = send_frame(protocol.pub(remote_topic, msg.payload, rule.retain))
					if ok ~= true then
						svc:obs_log('warn', {
							what    = 'export_send_failed',
							link_id = link_id,
							err     = tostring(serr),
						})
					end
				end
			end
		end)
	end
end

local function remote_call(transport, pending, send_frame, remote_topic, payload, timeout_s)
	local id = protocol.next_id()
	local rx = pending:open(id)

	local ok, serr = send_frame(
		protocol.call(id, remote_topic, payload, math.floor((timeout_s or 5.0) * 1000))
	)
	if ok ~= true then
		pending:close(id, 'send_failed')
		return nil, tostring(serr)
	end

	local which, a = perform(named_choice {
		reply = rx:recv_op(),
		timer = sleep.sleep_op(timeout_s or 5.0):wrap(function() return true end),
	})

	if which == 'timer' then
		pending:close(id, 'timeout')
		return nil, 'timeout'
	end

	local msg = a
	if type(msg) ~= 'table' or msg.t ~= 'reply' then
		return nil, 'invalid reply'
	end
	if msg.ok == true then
		return msg.payload, nil
	end
	return nil, tostring(msg.err or 'remote error')
end

local function start_proxy_call_endpoints(conn, svc, transport, link_id, proxy_rules, pending, send_frame, mark_ready)
	for i = 1, #(proxy_rules or {}) do
		local rule = proxy_rules[i]
		fibers.spawn(function()
			local ep = conn:bind(rule.local_topic, { queue_len = rule.queue_len or 8 })

			mark_ready('proxy')

			svc:obs_log('info', {
				what     = 'proxy_call_started',
				link_id  = link_id,
				local_t  = topic_s(rule.local_topic),
				remote_t = topic_s(rule.remote_topic),
			})

			while true do
				local msg, err = perform(ep:recv_op())
				if not msg then
					svc:obs_log('warn', {
						what    = 'proxy_call_stopped',
						link_id = link_id,
						err     = tostring(err),
					})
					return
				end

				local payload, cerr = remote_call(
					transport,
					pending,
					send_frame,
					rule.remote_topic,
					msg.payload,
					rule.timeout_s or 5.0
				)

				if msg.reply_to ~= nil then
					if payload ~= nil then
						conn:publish_one(msg.reply_to, payload, { id = msg.id })
					else
						conn:publish_one(msg.reply_to, { ok = false, err = tostring(cerr) }, { id = msg.id })
					end
				end
			end
		end)
	end
end

local function handle_incoming_pub(peer_conn, link_cfg, msg)
	local local_topic = topicmap.apply_first(link_cfg.import.publish, msg.topic, 'remote_topic', 'local_topic')
	if not local_topic then
		return false, 'no import rule'
	end

	if msg.retain then
		peer_conn:retain(local_topic, msg.payload)
	else
		peer_conn:publish(local_topic, msg.payload)
	end
	return true, nil
end

local function handle_incoming_unretain(peer_conn, link_cfg, msg)
	local local_topic = topicmap.apply_first(link_cfg.import.publish, msg.topic, 'remote_topic', 'local_topic')
	if not local_topic then
		return false, 'no import rule'
	end

	peer_conn:unretain(local_topic)
	return true, nil
end

local function handle_incoming_call(peer_conn, send_frame, link_cfg, msg)
	local local_topic = topicmap.apply_first(link_cfg.import.call, msg.topic, 'remote_topic', 'local_topic')
	if not local_topic then
		return send_frame(protocol.reply_err(msg.id, 'no_route'))
	end

	local payload, err = peer_conn:call(local_topic, msg.payload, {
		timeout = (type(msg.timeout_ms) == 'number' and msg.timeout_ms > 0) and (msg.timeout_ms / 1000.0) or 5.0,
	})

	if payload ~= nil then
		return send_frame(protocol.reply_ok(msg.id, payload))
	else
		return send_frame(protocol.reply_err(msg.id, err or 'call failed'))
	end
end

function M.run(conn, svc, opts)
	local link_id  = assert(opts.link_id, 'fabric session requires link_id')
	local link_cfg = assert(opts.link, 'fabric session requires link cfg')
	local peer_id  = assert(link_cfg.peer_id, 'fabric session requires peer_id')
	local connect  = assert(opts.connect, 'fabric session requires connect(principal)')

	local peer_conn = connect(authz.peer_principal(peer_id, { roles = { 'admin' } }))
	local pending   = new_pending_store()
	local transport = choose_transport(svc, link_cfg)
	local ka        = keepalive_cfg(link_cfg)

	local state = {
		node_id            = opts.node_id or os.getenv('DEVICECODE_NODE_ID') or 'devicecode',
		local_sid          = protocol.next_id(),
		peer_id            = peer_id,
		peer_node          = nil,
		peer_sid           = nil,
		established        = false,
		last_rx_at         = nil,
		last_tx_at         = nil,
		last_hello_at      = nil,
		last_peer_hello_at = nil,
		last_ping_at       = nil,
		last_pong_at       = nil,
	}

	local readiness = {
		expected     = #(link_cfg.export.publish or {}) + #(link_cfg.proxy_calls or {}),
		started      = 0,
		export_ready = 0,
		proxy_ready  = 0,
	}

	local function is_ready()
		return readiness.started >= readiness.expected
	end

	local function current_status()
		if state.established and is_ready() then
			return 'ready'
		end
		if state.established then
			return 'session_up'
		end
		return 'opening'
	end

	local function publish_session(extra)
		extra = extra or {}

		local payload = {
			status       = extra.status or current_status(),
			ready        = state.established and is_ready() or false,
			established  = state.established,
			peer_id      = peer_id,
			local_sid    = state.local_sid,
			peer_sid     = state.peer_sid,
			remote_id    = state.peer_node,
			kind         = ((link_cfg.transport or {}).kind) or 'uart',
			last_rx_at   = state.last_rx_at,
			last_tx_at   = state.last_tx_at,
			last_pong_at = state.last_pong_at,
			export_ready = readiness.export_ready,
			proxy_ready  = readiness.proxy_ready,
			expected     = readiness.expected,
		}

		if extra.err ~= nil then payload.err = extra.err end
		if extra.reason ~= nil then payload.reason = extra.reason end

		publish_link_state(conn, svc, link_id, payload)
	end

	local function mark_worker_ready(kind)
		readiness.started = readiness.started + 1
		if kind == 'export' then
			readiness.export_ready = readiness.export_ready + 1
		elseif kind == 'proxy' then
			readiness.proxy_ready = readiness.proxy_ready + 1
		end
		publish_session()
	end

	local function mark_tx(msg)
		local tnow = svc:now()
		state.last_tx_at = tnow
		if msg.t == 'hello' then
			state.last_hello_at = tnow
		elseif msg.t == 'ping' then
			state.last_ping_at = tnow
		end
	end

	local function mark_rx(msg)
		local tnow = svc:now()
		state.last_rx_at = tnow
		if msg.t == 'pong' then
			state.last_pong_at = tnow
		end
	end

	local function send_frame(msg)
		local ok, err = perform(transport:send_msg_op(msg))
		if ok == true then
			mark_tx(msg)
			return true, nil
		end
		return nil, err
	end

	local function note_peer_identity(msg, is_hello)
		local sid_changed = (state.peer_sid ~= nil and msg.sid ~= nil and state.peer_sid ~= msg.sid)

		if msg.node ~= nil then state.peer_node = msg.node end
		if msg.sid  ~= nil then state.peer_sid  = msg.sid  end

		state.established = true
		if is_hello then
			state.last_peer_hello_at = svc:now()
		end

		if sid_changed then
			pending:close_all('peer_session_changed')
			svc:obs_event('peer_session_changed', {
				link_id  = link_id,
				peer_id  = peer_id,
				peer_sid = state.peer_sid,
				node     = state.peer_node,
			})
		end

		publish_session()
	end

	local function last_activity()
		return max2(state.last_rx_at, state.last_tx_at)
	end

	local function next_deadline(tnow)
		local best = math.huge

		if not state.established then
			local hello_due = (state.last_hello_at and (state.last_hello_at + ka.hello_retry_s)) or tnow
			if hello_due < best then best = hello_due end
		end

		local act = last_activity()
		if act ~= nil then
			local ping_due = act + ka.idle_ping_s
			if ping_due < best then best = ping_due end
		end

		if state.last_rx_at ~= nil then
			local stale_due = state.last_rx_at + ka.stale_after_s
			if stale_due < best then best = stale_due end
		end

		return best
	end

	local scope = fibers.current_scope()
	scope:finally(function()
		pcall(function() pending:close_all('session_end') end)
		pcall(function() transport:close() end)
	end)

	local ok, err = transport:open()
	if ok ~= true then
		publish_link_state(conn, svc, link_id, {
			status  = 'down',
			ready   = false,
			peer_id = peer_id,
			err     = tostring(err),
		})
		error(('fabric/%s: transport open failed: %s'):format(link_id, tostring(err)), 0)
	end

	publish_session({ status = 'opening' })

	svc:obs_log('info', {
		what    = 'link_up',
		link_id = link_id,
		peer_id = peer_id,
	})

	local hello_ok, hello_err = send_frame(protocol.hello(state.node_id, peer_id, {
		pub  = true,
		call = true,
	}, {
		sid = state.local_sid,
	}))
	if hello_ok ~= true then
		svc:obs_log('warn', {
			what    = 'hello_send_failed',
			link_id = link_id,
			err     = tostring(hello_err),
		})
	end

	start_export_publishers(conn, svc, transport, link_id, link_cfg.export, send_frame, mark_worker_ready)
	start_proxy_call_endpoints(conn, svc, transport, link_id, link_cfg.proxy_calls, pending, send_frame, mark_worker_ready)

	while true do
		local tnow = svc:now()
		local deadline = next_deadline(tnow)

		local arms = {
			recv = transport:recv_msg_op(),
		}

		if deadline < math.huge then
			local dt = deadline - tnow
			if dt < 0 then dt = 0 end
			arms.timer = sleep.sleep_op(dt):wrap(function() return true end)
		end

		local which, a, b = perform(named_choice(arms))

		if which == 'timer' then
			local now2 = svc:now()

			if state.last_rx_at ~= nil and (now2 - state.last_rx_at) >= ka.stale_after_s then
				pending:close_all('peer_stale')
				publish_link_state(conn, svc, link_id, {
					status      = 'down',
					ready       = false,
					established = state.established,
					peer_id     = peer_id,
					local_sid   = state.local_sid,
					peer_sid    = state.peer_sid,
					remote_id   = state.peer_node,
					kind        = ((link_cfg.transport or {}).kind) or 'uart',
					err         = 'peer_stale',
				})
				error(('fabric/%s: peer stale'):format(link_id), 0)
			end

			if not state.established then
				local ok2, err2 = send_frame(protocol.hello(state.node_id, peer_id, {
					pub  = true,
					call = true,
				}, {
					sid = state.local_sid,
				}))
				if ok2 ~= true then
					svc:obs_log('warn', {
						what    = 'hello_retry_failed',
						link_id = link_id,
						err     = tostring(err2),
					})
				end
			else
				local act = last_activity()
				if act ~= nil and (now2 - act) >= ka.idle_ping_s then
					local ok2, err2 = send_frame(protocol.ping({ sid = state.local_sid }))
					if ok2 ~= true then
						svc:obs_log('warn', {
							what    = 'ping_send_failed',
							link_id = link_id,
							err     = tostring(err2),
						})
					end
				end
			end

		else
			local msg, rerr = a, b
			if not msg then
				pending:close_all('transport_down')
				publish_link_state(conn, svc, link_id, {
					status      = 'down',
					ready       = false,
					established = state.established,
					peer_id     = peer_id,
					local_sid   = state.local_sid,
					peer_sid    = state.peer_sid,
					remote_id   = state.peer_node,
					kind        = ((link_cfg.transport or {}).kind) or 'uart',
					err         = tostring(rerr),
				})
				error(('fabric/%s: receive failed: %s'):format(link_id, tostring(rerr)), 0)
			end

			mark_rx(msg)

			if msg.t == 'hello' then
				note_peer_identity(msg, true)

				local ok2, err2 = send_frame(protocol.hello_ack(state.node_id, {
					sid = state.local_sid,
				}))
				if ok2 ~= true then
					svc:obs_log('warn', {
						what    = 'hello_ack_failed',
						link_id = link_id,
						err     = tostring(err2),
					})
				end

			elseif msg.t == 'hello_ack' then
				note_peer_identity(msg, false)

			elseif msg.t == 'ping' then
				local ok2, err2 = send_frame(protocol.pong({ sid = state.local_sid }))
				if ok2 ~= true then
					svc:obs_log('warn', {
						what    = 'pong_send_failed',
						link_id = link_id,
						err     = tostring(err2),
					})
				end

			elseif msg.t == 'pong' then
				-- mark_rx() already updated last_pong_at

			elseif msg.t == 'pub' then
				local _, derr = handle_incoming_pub(peer_conn, link_cfg, msg)
				if derr then
					svc:obs_log('warn', {
						what    = 'incoming_pub_dropped',
						link_id = link_id,
						err     = tostring(derr),
					})
				end

			elseif msg.t == 'unretain' then
				local _, derr = handle_incoming_unretain(peer_conn, link_cfg, msg)
				if derr then
					svc:obs_log('warn', {
						what    = 'incoming_unretain_dropped',
						link_id = link_id,
						err     = tostring(derr),
					})
				end

			elseif msg.t == 'call' then
				local ok_call, call_err = handle_incoming_call(peer_conn, send_frame, link_cfg, msg)
				if ok_call ~= true then
					svc:obs_log('warn', {
						what    = 'incoming_call_failed',
						link_id = link_id,
						err     = tostring(call_err),
					})
				end

			elseif msg.t == 'reply' then
				pending:deliver(msg.corr, msg)

			else
				svc:obs_log('warn', {
					what    = 'unknown_message_type',
					link_id = link_id,
					t       = tostring(msg.t),
				})
			end
		end
	end
end

return M
