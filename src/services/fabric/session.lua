-- services/fabric/session.lua
--
-- One fabric session per configured link.
--
-- First-pass features:
--   * UART transport
--   * local export publish forwarding
--   * remote import publish forwarding
--   * local proxy calls -> remote calls
--   * remote calls -> local calls
--
-- Deliberate omissions:
--   * transfer streams
--   * retained local->remote unretain propagation
--   * reconnect backoff policy sophistication
--   * wire auth

local fibers   = require 'fibers'
local sleep    = require 'fibers.sleep'
local mailbox  = require 'fibers.mailbox'
local authz    = require 'devicecode.authz'

local protocol = require 'services.fabric.protocol'
local topicmap = require 'services.fabric.topicmap'
local uart_tx  = require 'services.fabric.transport_uart'

local perform = fibers.perform
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

local function start_export_publishers(conn, svc, transport, link_id, export_cfg)
	for i = 1, #(export_cfg.publish or {}) do
		local rule = export_cfg.publish[i]
		fibers.spawn(function()
			local sub = conn:subscribe(rule.local_topic, {
				queue_len = rule.queue_len or 50,
				full      = 'drop_oldest',
			})

			svc:obs_log('info', {
				what    = 'export_publish_started',
				link_id = link_id,
				local_t = topic_s(rule.local_topic),
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
					local ok, serr = perform(transport:send_msg_op(
						protocol.pub(remote_topic, msg.payload, rule.retain)
					))
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

	function store:close(id)
		local rec = by_id[id]
		if not rec then return false end
		rec.tx:close('closed')
		by_id[id] = nil
		return true
	end

	return store
end

local function remote_call(transport, pending, remote_topic, payload, timeout_s)
	local id = protocol.next_id()
	local rx = pending:open(id)

	local ok, serr = perform(transport:send_msg_op(
		protocol.call(id, remote_topic, payload, math.floor((timeout_s or 5.0) * 1000))
	))
	if ok ~= true then
		pending:close(id)
		return nil, tostring(serr)
	end

	local which, a, b = perform(named_choice {
		reply = rx:recv_op(),
		timer = sleep.sleep_op(timeout_s or 5.0):wrap(function() return true end),
	})

	if which == 'timer' then
		pending:close(id)
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

local function start_proxy_call_endpoints(conn, svc, transport, link_id, proxy_rules, pending)
	for i = 1, #(proxy_rules or {}) do
		local rule = proxy_rules[i]
		fibers.spawn(function()
			local ep = conn:bind(rule.local_topic, { queue_len = rule.queue_len or 8 })

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

local function handle_incoming_call(peer_conn, transport, link_cfg, msg)
	local local_topic = topicmap.apply_first(link_cfg.import.call, msg.topic, 'remote_topic', 'local_topic')
	if not local_topic then
		return perform(transport:send_msg_op(protocol.reply_err(msg.id, 'no_route')))
	end

	local payload, err = peer_conn:call(local_topic, msg.payload, {
		timeout = (type(msg.timeout_ms) == 'number' and msg.timeout_ms > 0) and (msg.timeout_ms / 1000.0) or 5.0,
	})

	if payload ~= nil then
		return perform(transport:send_msg_op(protocol.reply_ok(msg.id, payload)))
	else
		return perform(transport:send_msg_op(protocol.reply_err(msg.id, err or 'call failed')))
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

	local ok, err = transport:open()
	if ok ~= true then
		publish_link_state(conn, svc, link_id, {
			status  = 'down',
			peer_id = peer_id,
			err     = tostring(err),
		})
		error(('fabric/%s: transport open failed: %s'):format(link_id, tostring(err)), 0)
	end

	publish_link_state(conn, svc, link_id, {
		status  = 'up',
		peer_id = peer_id,
		kind    = ((link_cfg.transport or {}).kind) or 'uart',
	})

	svc:obs_log('info', {
		what    = 'link_up',
		link_id = link_id,
		peer_id = peer_id,
	})

	local hello_ok, hello_err = perform(transport:send_msg_op(
		protocol.hello('cm5-local', peer_id, {
			pub  = true,
			call = true,
		})
	))
	if hello_ok ~= true then
		svc:obs_log('warn', {
			what    = 'hello_send_failed',
			link_id = link_id,
			err     = tostring(hello_err),
		})
	end

	start_export_publishers(conn, svc, transport, link_id, link_cfg.export)
	start_proxy_call_endpoints(conn, svc, transport, link_id, link_cfg.proxy_calls, pending)

	fibers.spawn(function()
		while true do
			perform(sleep.sleep_op(15.0))
			perform(transport:send_msg_op(protocol.ping()))
		end
	end)

	while true do
		local msg, rerr = perform(transport:recv_msg_op())
		if not msg then
			publish_link_state(conn, svc, link_id, {
				status  = 'down',
				peer_id = peer_id,
				err     = tostring(rerr),
			})
			error(('fabric/%s: receive failed: %s'):format(link_id, tostring(rerr)), 0)
		end

		if msg.t == 'hello' then
			perform(transport:send_msg_op(protocol.hello_ack('cm5-local')))
			publish_link_state(conn, svc, link_id, {
				status    = 'up',
				peer_id   = peer_id,
				remote_id = msg.node,
				last_hello = svc:now(),
			})

		elseif msg.t == 'hello_ack' then
			publish_link_state(conn, svc, link_id, {
				status    = 'up',
				peer_id   = peer_id,
				last_hello = svc:now(),
			})

		elseif msg.t == 'ping' then
			perform(transport:send_msg_op(protocol.pong()))

		elseif msg.t == 'pong' then
			-- no-op for first pass

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
			local ok_call, call_err = handle_incoming_call(peer_conn, transport, link_cfg, msg)
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

return M
