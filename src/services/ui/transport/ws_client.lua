local fibers    = require 'fibers'
local mailbox   = require 'fibers.mailbox'
local websocket = require 'http.websocket'
local cjson     = require 'cjson.safe'
local errors    = require 'services.ui.errors'

local perform = fibers.perform
local choice  = fibers.choice
local unpack  = rawget(table, 'unpack') or _G.unpack

local M = {}

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
	if data ~= nil then payload.data = data end
	if err ~= nil then
		local e = errors.from(err)
		payload.err = errors.message(e)
		payload.code = errors.code(e)
	end
	send_out(payload)
end

local function inbound_event_op(inbound_rx)
	return inbound_rx:recv_op():wrap(function (item, why)
		return {
			tag  = 'inbound',
			item = item,
			why  = why,
		}
	end)
end

local function watch_choice_op(watches)
	local ops = {}
	for watch_id, rec in pairs(watches) do
		ops[#ops + 1] = rec.watch:recv_op():wrap(function (ev, why)
			return {
				tag      = 'watch',
				watch_id = watch_id,
				ev       = ev,
				why      = why,
			}
		end)
	end
	if #ops == 0 then return nil end
	return choice(unpack(ops))
end

local function next_event(inbound_rx, watches)
	local winbound = inbound_event_op(inbound_rx)
	local wwatch = watch_choice_op(watches)
	if not wwatch then
		return perform(winbound)
	end

	-- Preserve the useful UI property that watch events already ready locally are
	-- delivered before we consume the next inbound client frame. This avoids a
	-- later logout/close frame racing ahead of a watch event that has already
	-- arrived. If no watch is immediately ready, fall back to a normal fair
	-- choice between inbound frames and watch events.
	local immediate = perform(wwatch:or_else(function () return nil end))
	if immediate ~= nil then
		return immediate
	end

	return perform(choice(wwatch, winbound))
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
	local watches = {}
	local alive = true
	local current_session = nil
	local current_rec = nil
	local user_conn = nil

	local function send_out(msg)
		local ok, ret = pcall(ws_send, ws, msg)
		if (not ok) or ret == nil or ret == false then
			alive = false
			return false
		end
		return true
	end

	local function close_watch(watch_id, reason)
		local rec = watches[watch_id]
		if not rec then return false end
		watches[watch_id] = nil
		pcall(function() rec.watch:close(reason or 'closed') end)
		return true
	end

	local function close_all_watches(reason)
		for id in pairs(watches) do close_watch(id, reason) end
	end

	local function clear_user_conn(reason)
		close_all_watches(reason or 'logout')
		if user_conn then pcall(function() user_conn:disconnect() end) end
		user_conn = nil
		current_session = nil
		current_rec = nil
	end

	local function adopt_session(session_id)
		if session_id == nil or session_id == '' then
			clear_user_conn('logout')
			return nil, errors.unauthorised('missing session')
		end
		local rec, err = require_session(session_id)
		if not rec then
			clear_user_conn('invalid_session')
			return nil, err
		end
		if current_session == rec.id and user_conn then
			current_rec = rec
			return rec, nil
		end
		clear_user_conn('session_change')
		local conn, cerr = open_user_conn(rec.principal, { ui = { transport = 'ws', session_id = rec.id } })
		if not conn then return nil, cerr or errors.unavailable('failed to open user connection') end
		user_conn = conn
		current_session = rec.id
		current_rec = rec
		return rec, nil
	end

	local function start_watch(watch_id, pattern, watch_opts)
		local rec, err = adopt_session(current_session)
		if not rec then return nil, err end
		close_watch(watch_id, 'replaced')
		local watch, werr2 = app.watch_open(rec.id, pattern, watch_opts)
		if not watch then return nil, werr2 end
		watches[watch_id] = { watch = watch }
		return { watch_id = watch_id }, nil
	end

	local sid = session_id_from_headers(req_headers)
	if sid then adopt_session(sid) end

	local ok_reader, reader_err = fibers.current_scope():spawn(function()
		while alive do
			local msg, opcode, err = ws:receive()
			if msg == nil then
				inbound_tx:send({ kind = 'socket_closed', err = tostring(err) })
				break
			end
			inbound_tx:send({ kind = 'frame', msg = msg, opcode = opcode })
		end
		pcall(function() inbound_tx:close('reader_done') end)
	end)
	if not ok_reader then error(reader_err, 0) end

	svc:obs_log('info', { what = 'ui_ws_connected' })
	while alive do
		local ev = next_event(inbound_rx, watches)
		if ev.tag == 'watch' then
			if ev.ev == nil then
				watches[ev.watch_id] = nil
				send_out({ op = 'watch_closed', watch_id = ev.watch_id, reason = tostring(ev.why or 'closed') })
			else
				send_out({ op = 'watch_event', watch_id = ev.watch_id, event = ev.ev })
			end
		else
			local item = ev.item
			if item == nil then
				break
			elseif item.kind == 'socket_closed' then
				svc:obs_log('info', { what = 'ui_ws_disconnected', err = tostring(item.err) })
				break
			elseif item.opcode ~= 'text' then
				send_reply(send_out, nil, false, nil, errors.bad_request('only text frames are supported'))
			else
				local obj, jerr = decode_json(item.msg)
				if not obj then
					send_reply(send_out, nil, false, nil, jerr)
				else
					local id = obj.id
					local op_name = obj.op
					local out, err
					if op_name == 'hello' then
						out = { service = svc.name }
					elseif op_name == 'session' then
						out, err = app.get_session(obj.session_id or current_session)
					elseif op_name == 'health' then
						out, err = app.health()
					elseif op_name == 'login' then
						out, err = app.login(obj.username, obj.password)
						if out and out.session_id then adopt_session(out.session_id) end
					elseif op_name == 'logout' then
						out, err = app.logout(obj.session_id or current_session)
						if out then clear_user_conn('logout') end
					elseif op_name == 'config_get' then
						out, err = app.config_get(obj.session_id or current_session, obj.service)
					elseif op_name == 'config_set' then
						out, err = app.config_set(obj.session_id or current_session, obj.service, obj.data, user_conn)
					elseif op_name == 'service_status' then
						out, err = app.service_status(obj.session_id or current_session, obj.service)
					elseif op_name == 'services_snapshot' then
						out, err = app.services_snapshot(obj.session_id or current_session)
					elseif op_name == 'fabric_status' then
						out, err = app.fabric_status(obj.session_id or current_session)
					elseif op_name == 'fabric_link_status' then
						out, err = app.fabric_link_status(obj.session_id or current_session, obj.link_id)
					elseif op_name == 'capability_snapshot' then
						out, err = app.capability_snapshot(obj.session_id or current_session)
					elseif op_name == 'model_exact' then
						out, err = app.model_exact(obj.session_id or current_session, obj.topic)
					elseif op_name == 'model_snapshot' then
						out, err = app.model_snapshot(obj.session_id or current_session, obj.pattern)
					elseif op_name == 'call' then
						out, err = app.call(obj.session_id or current_session, obj.topic, obj.payload, obj.timeout, user_conn)
					elseif op_name == 'watch_open' then
						out, err = start_watch(obj.watch_id, obj.pattern, { queue_len = obj.queue_len })
					elseif op_name == 'watch_close' then
						close_watch(obj.watch_id, 'client_stop')
						out = { watch_id = obj.watch_id }
					else
						err = errors.bad_request('unknown op: ' .. tostring(op_name))
					end
					send_reply(send_out, id, out ~= nil, out, err)
				end
			end
		end
	end

	clear_user_conn('socket_closed')
	pcall(function() inbound_tx:close('done') end)
	pcall(function() ws:close() end)
	on_closed()
end

return M
