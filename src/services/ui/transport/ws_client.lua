-- services/ui/transport/ws_client.lua
--
-- One websocket client session.
--
-- Responsibilities:
--   * upgrade one HTTP stream into a websocket
--   * maintain one authenticated user connection for the current session
--   * multiplex inbound client frames with local UI model watch events
--   * forward replies/events using a small JSON message protocol
--
-- Design notes:
--   * next_event_op(...) is a pure op constructor
--   * the shell loop is the only place that performs event ops
--   * already-ready watch events are drained before blocking on the combined
--     event choice so local model traffic is not needlessly delayed behind a
--     later inbound frame

local fibers    = require 'fibers'
local mailbox   = require 'fibers.mailbox'
local websocket = require 'http.websocket'
local cjson     = require 'cjson.safe'
local errors    = require 'services.ui.errors'
local safe      = require 'coxpcall'

local perform = fibers.perform
local choice  = fibers.choice
local unpack  = rawget(table, 'unpack') or _G.unpack

local M = {}

local NO_READY = {}

local function ws_send(ws, obj)
	local txt = cjson.encode(obj or {}) or '{"ok":false,"err":"json_encode_failed"}'
	return ws:send(txt)
end

local function decode_json(text)
	local obj, err = cjson.decode(text)
	if obj == nil or type(obj) ~= 'table' then
		return nil, errors.bad_request('invalid_json: ' .. tostring(err))
	end
	return obj, nil
end

local function send_reply(send_out, id, ok, data, err)
	local payload = { id = id, ok = ok == true }
	if data ~= nil then
		payload.data = data
	end
	if err ~= nil then
		local e = errors.from(err)
		payload.err = errors.message(e)
		payload.code = errors.code(e)
	end
	send_out(payload)
end

local function inbound_event_op(inbound_rx)
	return inbound_rx:recv_op():wrap(function(item, why)
		return {
			tag = 'inbound',
			item = item,
			why = why,
		}
	end)
end

local function watch_choice_op(watches)
	local ops = {}
	for watch_id, rec in pairs(watches) do
		ops[#ops + 1] = rec.watch:recv_op():wrap(function(ev, why)
			return {
				tag = 'watch',
				watch_id = watch_id,
				ev = ev,
				why = why,
			}
		end)
	end
	if #ops == 0 then return nil end
	return choice(unpack(ops))
end

-- Pure combined event op.
--
-- This is the blocking event choice used once no watch event is already ready.
local function next_event_op(inbound_rx, watches)
	local winbound = inbound_event_op(inbound_rx)
	local wwatch = watch_choice_op(watches)
	if not wwatch then
		return winbound
	end
	return choice(wwatch, winbound)
end

-- Non-blocking probe for already-ready watch traffic.
--
-- This preserves the previous UI property that locally ready watch events are
-- delivered before we block waiting for the next inbound client frame.
local function take_ready_watch_event(watches)
	local wwatch = watch_choice_op(watches)
	if not wwatch then
		return nil
	end

	local ev = perform(wwatch:or_else(function()
		return NO_READY
	end))

	if ev == NO_READY then
		return nil
	end

	return ev
end

local function valid_watch_id(watch_id)
	return type(watch_id) == 'string' and watch_id ~= ''
end

local function close_watch(state, watch_id, reason)
	local rec = state.watches[watch_id]
	if not rec then return false end
	state.watches[watch_id] = nil
	rec.watch:close(reason or 'closed')
	return true
end

local function close_all_watches(state, reason)
	for id in pairs(state.watches) do
		close_watch(state, id, reason)
	end
end

local function clear_user_conn(state, reason)
	close_all_watches(state, reason or 'logout')
	if state.user_conn then
		state.user_conn:disconnect()
	end
	state.user_conn = nil
	state.current_session = nil
end

local function adopt_session(state, session_id)
	if session_id == nil or session_id == '' then
		clear_user_conn(state, 'logout')
		return nil, errors.unauthorised('missing session')
	end

	local rec, err = state.require_session(session_id)
	if not rec then
		clear_user_conn(state, 'invalid_session')
		return nil, err
	end

	if state.current_session == rec.id and state.user_conn then
		return rec, nil
	end

	clear_user_conn(state, 'session_change')

	local conn, cerr = state.open_user_conn(rec.principal, {
		ui = { transport = 'ws', session_id = rec.id },
	})
	if not conn then
		return nil, cerr or errors.unavailable('failed to open user connection')
	end

	state.user_conn = conn
	state.current_session = rec.id
	return rec, nil
end

local function start_watch(state, app, watch_id, pattern, watch_opts)
	if not valid_watch_id(watch_id) then
		return nil, errors.bad_request('watch_id must be a non-empty string')
	end

	local rec, err = adopt_session(state, state.current_session)
	if not rec then return nil, err end

	close_watch(state, watch_id, 'replaced')

	local watch, werr = app.watch_open(rec.id, pattern, watch_opts)
	if not watch then return nil, werr end

	state.watches[watch_id] = { watch = watch }
	return { watch_id = watch_id }, nil
end

local function build_ops(state, app)
	return {
		hello = function(_obj)
			return { service = state.svc.name }, nil
		end,

		session = function(obj)
			return app.get_session(obj.session_id or state.current_session)
		end,

		health = function(_obj)
			return app.health()
		end,

		login = function(obj)
			local out, err = app.login(obj.username, obj.password)
			if out and out.session_id then
				adopt_session(state, out.session_id)
			end
			return out, err
		end,

		logout = function(obj)
			local out, err = app.logout(obj.session_id or state.current_session)
			if out then
				clear_user_conn(state, 'logout')
			end
			return out, err
		end,

		config_get = function(obj)
			return app.config_get(obj.session_id or state.current_session, obj.service)
		end,

		config_set = function(obj)
			return app.config_set(obj.session_id or state.current_session, obj.service, obj.data, state.user_conn)
		end,

		service_status = function(obj)
			return app.service_status(obj.session_id or state.current_session, obj.service)
		end,

		services_snapshot = function(obj)
			return app.services_snapshot(obj.session_id or state.current_session)
		end,

		fabric_status = function(obj)
			return app.fabric_status(obj.session_id or state.current_session)
		end,

		fabric_link_status = function(obj)
			return app.fabric_link_status(obj.session_id or state.current_session, obj.link_id)
		end,

		capability_snapshot = function(obj)
			return app.capability_snapshot(obj.session_id or state.current_session)
		end,

		model_exact = function(obj)
			return app.model_exact(obj.session_id or state.current_session, obj.topic)
		end,

		model_snapshot = function(obj)
			return app.model_snapshot(obj.session_id or state.current_session, obj.pattern)
		end,

		call = function(obj)
			return app.call(obj.session_id or state.current_session, obj.topic, obj.payload, obj.timeout, state.user_conn)
		end,

		watch_open = function(obj)
			return start_watch(state, app, obj.watch_id, obj.pattern, { queue_len = obj.queue_len })
		end,

		watch_close = function(obj)
			if not valid_watch_id(obj.watch_id) then
				return nil, errors.bad_request('watch_id must be a non-empty string')
			end
			close_watch(state, obj.watch_id, 'client_stop')
			return { watch_id = obj.watch_id }, nil
		end,
	}
end

local function handle_watch_event(state, send_out, ev)
	if ev.ev == nil then
		state.watches[ev.watch_id] = nil
		send_out({
			op = 'watch_closed',
			watch_id = ev.watch_id,
			reason = tostring(ev.why or 'closed'),
		})
	else
		send_out({
			op = 'watch_event',
			watch_id = ev.watch_id,
			event = ev.ev,
		})
	end
end

local function handle_inbound_item(state, send_out, ops, item)
	if item == nil then
		return false
	end

	if item.kind == 'socket_closed' then
		state.svc:obs_log('info', {
			what = 'ui_ws_disconnected',
			err = tostring(item.err),
		})
		return false
	end

	if item.opcode ~= 'text' then
		send_reply(send_out, nil, false, nil, errors.bad_request('only text frames are supported'))
		return true
	end

	local obj, jerr = decode_json(item.msg)
	if not obj then
		send_reply(send_out, nil, false, nil, jerr)
		return true
	end

	local id = obj.id
	local op_name = obj.op
	local handler = ops[op_name]
	local out, err

	if not handler then
		err = errors.bad_request('unknown op: ' .. tostring(op_name))
	else
		out, err = handler(obj)
	end

	send_reply(send_out, id, out ~= nil, out, err)
	return true
end

function M.run(svc, app, stream, req_headers, opts)
	opts = opts or {}
	local session_id_from_headers = assert(opts.session_id_from_headers, 'ws_client requires session_id_from_headers')
	local on_opened = opts.on_opened or function() end
	local on_closed = opts.on_closed or function() end
	local open_user_conn = assert(opts.open_user_conn, 'ws_client requires open_user_conn')
	local require_session = assert(opts.require_session, 'ws_client requires require_session')

	local ws, werr = websocket.new_from_stream(stream, req_headers)
	if not ws then
		local http_headers = require 'http.headers'
		local h = http_headers.new()
		h:append(':status', '400')
		h:append('content-type', 'text/plain; charset=utf-8')
		stream:write_headers(h, false)
		stream:write_chunk('websocket upgrade failed: ' .. tostring(werr) .. '\n', true)
		return
	end

	assert(ws:accept())
	on_opened()

	local inbound_tx, inbound_rx = mailbox.new(64, { full = 'reject_newest' })

	local state = {
		svc = svc,
		alive = true,
		watches = {},
		current_session = nil,
		user_conn = nil,
		open_user_conn = open_user_conn,
		require_session = require_session,
	}
	local ops = build_ops(state, app)

	local function send_out(msg)
		local ok, ret = safe.pcall(ws_send, ws, msg)
		if (not ok) or ret == nil or ret == false then
			state.alive = false
			return false
		end
		return true
	end

	local sid = session_id_from_headers(req_headers)
	if sid then
		adopt_session(state, sid)
	end

	local ok_reader, reader_err = fibers.current_scope():spawn(function()
		while state.alive do
			local msg, opcode, err = ws:receive()
			if msg == nil then
				local ok = inbound_tx:send({ kind = 'socket_closed', err = tostring(err) })
				if ok ~= true then
					state.alive = false
				end
				break
			end

			local ok = inbound_tx:send({ kind = 'frame', msg = msg, opcode = opcode })
			if ok ~= true then
				state.alive = false
				break
			end
		end
		inbound_tx:close('reader_done')
	end)
	if not ok_reader then
		error(reader_err, 0)
	end

	svc:obs_log('info', { what = 'ui_ws_connected' })

	while state.alive do
		local ev = take_ready_watch_event(state.watches)
		if ev == nil then
			ev = perform(next_event_op(inbound_rx, state.watches))
		end

		if ev.tag == 'watch' then
			handle_watch_event(state, send_out, ev)
		else
			if not handle_inbound_item(state, send_out, ops, ev.item) then
				break
			end
		end
	end

	clear_user_conn(state, 'socket_closed')
	inbound_tx:close('done')
	ws:close()
	on_closed()
end

return M
