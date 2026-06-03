-- services/fabric/bridge.lua
--
-- RPC bridge coordinator.
--
-- The bridge owns:
--   * local/remote RPC and state routing
--   * imported retained state for the current peer session
--   * replay of local retained exports on new peer sessions
--   * scoped outbound calls
--   * scoped inbound local-bus calls
--   * reply routing by call id and session identity
--   * bridge diagnostics and state projection
--
-- It does not own transport, session establishment, local-bus feed adaptation,
-- device policy, update policy, or transfer policy.

local fibers  = require 'fibers'
local mailbox = require 'fibers.mailbox'
local sleep   = require 'fibers.sleep'

local scoped_work    = require 'devicecode.support.scoped_work'
local queue          = require 'devicecode.support.queue'
local priority_event = require 'devicecode.support.priority_event'
local request_owner  = require 'devicecode.support.request_owner'
local contracts      = require 'devicecode.support.contracts'
local validate       = require 'shared.validate'

local model_mod   = require 'services.fabric.model'
local protocol    = require 'services.fabric.protocol'
local topics      = require 'services.fabric.topics'
local session_mod = require 'services.fabric.session'
local state_mod   = require 'services.fabric.state'

local M = {}

local Bridge = {}
Bridge.__index = Bridge

local DEFAULT_DONE_QUEUE = 64
local DEFAULT_CALL_TIMEOUT = 1.0
local DEFAULT_MAX_PENDING_CALLS = 64
local DEFAULT_MAX_INBOUND_CALLS = 64

local copy_context       = session_mod.copy_context
local same_session       = session_mod.same_session
local context_from_event = session_mod.context_from_event

--------------------------------------------------------------------------------
-- Small helpers
--------------------------------------------------------------------------------

local function count_keys(t)
	local n = 0
	for _ in pairs(t or {}) do n = n + 1 end
	return n
end

local function require_params(params)
	if type(params) ~= 'table' then
		error('fabric.bridge.run: params table required', 3)
	end
	return params
end

local function require_rx(v, name, level)
	return contracts.require_rx(v, name, (level or 1) + 1)
end

local function require_outbound(v, name, level)
	if type(v) ~= 'table' or type(v.send_rpc_frame_now) ~= 'function' then
		error(name .. ' must be a fabric.session outbound gate', (level or 1) + 1)
	end
	return v
end

local function nonneg_int(v, name, level)
	return validate.non_negative_integer(v, name, (level or 1) + 1)
end

local function resolve_nonneg_int(v, default, name, level)
	if v == nil then return default end
	return nonneg_int(v, name, (level or 1) + 1)
end

local function positive_number(v, default, name, level)
	if v == nil then return default end
	if type(v) ~= 'number'
		or v <= 0
		or v ~= v
		or v == math.huge
		or v == -math.huge
	then
		error(name .. ' must be a positive finite number', (level or 1) + 1)
	end
	return v
end

local function fail_request(req, reason)
	if type(req) == 'table' and type(req.fail) == 'function' then
		return req:fail(reason)
	end
	return false
end

local function topic_string(topic)
	if type(topic) ~= 'table' then return nil end
	local out = {}
	for i = 1, #topic do out[i] = tostring(topic[i]) end
	return table.concat(out, '/')
end

local function imported_retained_topic_strings(self)
	local out = {}
	for _, rec in pairs(self._imported_retained or {}) do
		local s = rec and topic_string(rec.topic)
		if s ~= nil then out[#out + 1] = s end
	end
	table.sort(out)
	return out
end

local function initial_snapshot(link_id, link_generation)
	return {
		link_id             = link_id,
		link_generation     = link_generation,
		state               = 'starting',
		imported_topics     = 0,
		imported_retained_count = 0,
		imported_retained_topics = {},
		pending_calls       = 0,
		inbound_calls       = 0,
		frames_sent         = 0,
		frames_received     = 0,
		last_err            = nil,
		session             = nil,
		session_generation  = nil,
		peer_sid            = nil,
		session_drop_reason = nil,
		last_imported_topic = nil,
		last_imported_at    = nil,
		last_clear_reason   = nil,
		last_clear_count    = 0,
		last_outbound_call  = nil,
	}
end

local function public_snapshot(self)
	return self._model:snapshot()
end

local function publish_state(self)
	if self._state_tx == nil then
		return true, nil
	end

	return state_mod.admit_component_snapshot_now(
		self._state_tx,
		self._link_id,
		self._link_generation,
		self._component_name,
		public_snapshot(self),
		'fabric_bridge_state_admit_failed'
	)
end

local function update_model(self, patch)
	local changed = self._model:update(function (s)
		for k, v in pairs(patch or {}) do
			s[k] = v
		end

		s.imported_topics = count_keys(self._imported_retained)
		s.imported_retained_count = s.imported_topics
		s.imported_retained_topics = imported_retained_topic_strings(self)
		s.pending_calls   = count_keys(self._pending_calls)
		s.inbound_calls   = count_keys(self._inbound_calls)
	end)

	if changed then publish_state(self) end
	return changed
end

local function next_call_id(self)
	self._next_call_seq = self._next_call_seq + 1
	return ('%s-call-%d'):format(self._link_id, self._next_call_seq)
end

local function current_session(self)
	return copy_context(self._session)
end

local function has_current_session(self)
	return type(self._session) == 'table'
		and type(self._session.session_generation) == 'number'
		and type(self._session.peer_sid) == 'string'
		and self._session.peer_sid ~= ''
end

local function scalar_payload_field(payload, key)
	if type(payload) ~= 'table' then return nil end
	local v = payload[key]
	local tv = type(v)
	if tv == 'string' or tv == 'number' or tv == 'boolean' then
		return tostring(v)
	end
	return nil
end

local function prepare_update_topic(topic)
	return type(topic) == 'table'
		and topic[#topic] == 'prepare-update'
		and topic[#topic - 1] == 'rpc'
end

local function trace_outbound_call_topic(local_topic, remote_topic)
	return prepare_update_topic(local_topic) or prepare_update_topic(remote_topic)
end

local function append_diag_print_field(parts, key, value)
	if value == nil or value == '' then return end
	parts[#parts + 1] = key
	parts[#parts + 1] = tostring(value)
end

local function print_outbound_call_diag(diag)
	local parts = { '[fabric-rpc]', 'ev', tostring(diag.event or 'unknown') }
	append_diag_print_field(parts, 'call_id', diag.call_id)
	append_diag_print_field(parts, 'local_topic', diag.local_topic)
	append_diag_print_field(parts, 'remote_topic', diag.remote_topic)
	append_diag_print_field(parts, 'job_id', diag.job_id)
	append_diag_print_field(parts, 'expected_image_id', diag.expected_image_id)
	append_diag_print_field(parts, 'peer_sid', diag.peer_sid)
	append_diag_print_field(parts, 'session_generation', diag.session_generation)
	if diag.frame_admitted ~= nil then
		append_diag_print_field(parts, 'frame_admitted', tostring(diag.frame_admitted))
	end
	if diag.frame_sent ~= nil then
		append_diag_print_field(parts, 'frame_sent', tostring(diag.frame_sent))
	end
	if diag.reply_routed ~= nil then
		append_diag_print_field(parts, 'reply_routed', tostring(diag.reply_routed))
	end
	if diag.ok ~= nil then
		append_diag_print_field(parts, 'ok', tostring(diag.ok))
	end
	append_diag_print_field(parts, 'reason', diag.reason)
	append_diag_print_field(parts, 'err', diag.err)
	print(table.concat(parts, ' '))
end

local function pick_bool(primary, fallback)
	if primary ~= nil then return not not primary end
	if fallback ~= nil then return not not fallback end
	return nil
end

local function record_outbound_call_diag(self, rec, event, extra)
	extra = extra or {}
	local local_topic = extra.local_topic or (rec and rec.local_topic)
	local remote_topic = extra.remote_topic or (rec and rec.remote_topic)
	if not trace_outbound_call_topic(local_topic, remote_topic) then
		return
	end

	local payload = extra.payload or (rec and rec.payload)
	local session = extra.session or (rec and rec.session) or current_session(self)
	local diag = {
		event = event,
		at = fibers.now(),
		link_id = self._link_id,
		link_generation = self._link_generation,
		call_id = extra.call_id or (rec and rec.id),
		local_topic = topic_string(local_topic),
		remote_topic = topic_string(remote_topic),
		job_id = scalar_payload_field(payload, 'job_id'),
		expected_image_id = scalar_payload_field(payload, 'expected_image_id'),
		peer_sid = session and session.peer_sid or nil,
		session_generation = session and session.session_generation or nil,
		frame_admitted = pick_bool(extra.frame_admitted, rec and rec.frame_admitted),
		frame_sent = pick_bool(extra.frame_sent),
		reply_routed = pick_bool(extra.reply_routed, rec and rec.reply_routed),
		ok = pick_bool(extra.ok),
		reason = extra.reason,
		err = extra.err,
	}

	update_model(self, { last_outbound_call = diag })
	print_outbound_call_diag(diag)
end

--------------------------------------------------------------------------------
-- Frame output
--------------------------------------------------------------------------------

local function admit_frame_now(outbound, session, frame, label)
	local checked, err = protocol.validate(frame)
	if not checked then
		return nil, (label or 'bridge_frame_invalid') .. ': ' .. tostring(err)
	end

	return outbound:send_rpc_frame_now(session, checked, label or 'bridge_frame_send_failed')
end

local function record_frame_sent(self)
	self._frames_sent = self._frames_sent + 1
	update_model(self, { frames_sent = self._frames_sent })
end

local function send_frame_now(self, frame, label, session)
	local ok, err = admit_frame_now(
		self._outbound,
		session or current_session(self),
		frame,
		label
	)

	if ok == true then
		record_frame_sent(self)
	end

	return ok, err
end

local function must_send_frame_now(self, frame, label, session)
	local ok, err = send_frame_now(self, frame, label, session)
	if ok ~= true then
		error(err or label or 'bridge_frame_send_failed', 0)
	end
end

local function make_bridge_caps(self, session)
	local ctx = copy_context(session) or current_session(self)

	return {
		link_id         = self._link_id,
		link_generation = self._link_generation,
		session         = copy_context(ctx),

		send_rpc_frame_now = function (frame, label)
			return admit_frame_now(self._outbound, ctx, frame, label)
		end,
	}
end

--------------------------------------------------------------------------------
-- Topic mapping
--------------------------------------------------------------------------------

local function map_or_passthrough(rules, topic, mapper)
	if #rules == 0 then
		return topics.copy(topic), nil
	end

	return mapper(rules, topic)
end

local function map_local_publish(self, topic, retain)
	if retain and #self._export_retained_rules > 0 then
		return map_or_passthrough(self._export_retained_rules, topic, topics.map_local_to_remote)
	end

	return map_or_passthrough(self._export_publish_rules, topic, topics.map_local_to_remote)
end

local function map_local_unretain(self, topic)
	return map_or_passthrough(self._export_retained_rules, topic, topics.map_local_to_remote)
end

local function map_local_call(self, topic)
	return map_or_passthrough(self._outbound_call_rules, topic, topics.map_local_call_to_remote)
end

local function map_remote_import(self, topic)
	return map_or_passthrough(self._import_rules, topic, topics.map_remote_to_local)
end

local function map_remote_call(self, topic)
	return map_or_passthrough(self._inbound_call_rules, topic, topics.map_remote_call_to_local)
end

--------------------------------------------------------------------------------
-- Local outbound events
--------------------------------------------------------------------------------

local function remember_local_retained_export(self, topic, payload)
	self._local_retained_exports[topics.key(topic)] = {
		topic   = topics.copy(topic),
		payload = payload,
	}
end

local function forget_local_retained_export(self, topic)
	self._local_retained_exports[topics.key(topic)] = nil
end

local function send_retained_export_now(self, rec)
	local remote_topic = map_local_publish(self, rec.topic, true)
	if not remote_topic then return true end

	must_send_frame_now(
		self,
		protocol.pub(remote_topic, rec.payload, true),
		'bridge_retained_replay_send_failed'
	)

	return true
end

local function replay_local_retained_exports(self)
	if not has_current_session(self) then
		return true
	end

	for _, rec in pairs(self._local_retained_exports) do
		send_retained_export_now(self, rec)
	end

	return true
end

local function handle_local_publish(self, ev)
	local checked_topic, err = protocol.validate_topic(ev.topic)
	if not checked_topic then
		error('bridge publish invalid topic: ' .. tostring(err), 0)
	end

	local remote_topic = map_local_publish(self, checked_topic, not not ev.retain)
	if not remote_topic then
		return
	end

	if ev.retain then
		remember_local_retained_export(self, checked_topic, ev.payload)
	end

	if not has_current_session(self) then
		return
	end

	must_send_frame_now(
		self,
		protocol.pub(remote_topic, ev.payload, not not ev.retain),
		'bridge_publish_send_failed'
	)
end

local function handle_local_unretain(self, ev)
	local checked_topic, err = protocol.validate_topic(ev.topic)
	if not checked_topic then
		error('bridge unretain invalid topic: ' .. tostring(err), 0)
	end

	local remote_topic = map_local_unretain(self, checked_topic)
	if not remote_topic then
		return
	end

	forget_local_retained_export(self, checked_topic)

	if not has_current_session(self) then
		return
	end

	must_send_frame_now(
		self,
		protocol.unretain(remote_topic),
		'bridge_unretain_send_failed'
	)
end

--------------------------------------------------------------------------------
-- Scoped work
--------------------------------------------------------------------------------

local function report_done_to(self, label)
	return function (ev)
		return queue.try_admit_required(self._done_tx, ev, label)
	end
end

local function start_bridge_work(self, identity, run, report_label, cancel_op)
	return scoped_work.start {
		lifetime_scope = self._scope,
		reaper_scope   = self._scope,
		report_scope   = self._scope,
		identity       = identity,
		run            = run,
		report         = report_done_to(self, report_label),
		cancel_op      = cancel_op,
	}
end

--------------------------------------------------------------------------------
-- Outbound calls
--------------------------------------------------------------------------------

local function run_outbound_call(call)
	return function (call_scope)
		call_scope:finally(function (_, status, primary)
			call.owner:finalise_unresolved(primary or status or 'outbound_call_closed')
			call.reply_tx:close(primary or status or 'outbound_call_closed')
		end)

		local ok, send_err = call.caps.send_rpc_frame_now(
			protocol.call(call.id, call.topic, call.payload),
			'bridge_outbound_call_send_failed'
		)

		if ok ~= true then
			call.owner:fail_once(send_err or 'send_failed')
			return {
				call_id    = call.id,
				ok         = false,
				err        = send_err or 'send_failed',
				frame_sent = false,
				event      = 'send_failed',
			}
		end

		call.mark_frame_admitted()
		call.report_diag({
			kind       = 'outbound_call_diag',
			call_id    = call.id,
			event      = 'sent',
			frame_sent = true,
			ok         = true,
		})

		if call.reply_policy == 'sent-is-accepted' then
			local payload = {
				accepted = true,
				frame_sent = true,
				call_id = call.id,
			}

			call.owner:reply_once(payload)

			return {
				call_id = call.id,
				ok = true,
				frame_sent = true,
				sent_is_accepted = true,
				event = 'sent_is_accepted',
			}
		end

		local which, reply, recv_err = fibers.perform(fibers.named_choice {
			reply   = call.reply_rx:recv_op(),
			timeout = sleep.sleep_op(call.timeout),
		})

		if which == 'timeout' then
			call.owner:fail_once('timeout')
			call_scope:cancel('timeout')
			return {
				call_id    = call.id,
				timed_out  = true,
				frame_sent = true,
				event      = 'timeout',
				err        = 'timeout',
			}
		end

		if reply == nil then
			local why = recv_err
				or (call.reply_rx.why and call.reply_rx:why())
				or 'closed'

			call.owner:fail_once(why)
			return {
				call_id    = call.id,
				closed     = true,
				err        = tostring(why),
				frame_sent = true,
				event      = 'closed',
			}
		end

		if reply.ok then
			call.owner:reply_once(reply.payload)

			return {
				call_id    = call.id,
				ok         = true,
				payload    = reply.payload,
				frame_sent = true,
				event      = 'reply_ok',
			}
		end

		local err = reply.err or 'remote_call_failed'
		call.owner:fail_once(err)

		return {
			call_id    = call.id,
			ok         = false,
			err        = err,
			frame_sent = true,
			event      = 'reply_error',
		}
	end
end

local function start_outbound_call(self, ev)
	local checked_topic, err = protocol.validate_topic(ev.topic)
	if not checked_topic then
		error('bridge call invalid topic: ' .. tostring(err), 0)
	end

	if not has_current_session(self) then
		record_outbound_call_diag(self, nil, 'not_admitted', {
			local_topic = checked_topic,
			payload = ev.payload,
			reason = 'no_session',
			frame_admitted = false,
			frame_sent = false,
		})
		fail_request(ev.request or ev, 'no_session')
		return
	end

	local remote_topic, rule = map_local_call(self, checked_topic)
	if not remote_topic then
		record_outbound_call_diag(self, nil, 'not_admitted', {
			local_topic = checked_topic,
			payload = ev.payload,
			reason = 'no_route',
			frame_admitted = false,
			frame_sent = false,
		})
		fail_request(ev.request or ev, 'no_route')
		return
	end

	local id = ev.id or next_call_id(self)
	if type(id) ~= 'string' or id == '' then
		error('bridge call id must be a non-empty string', 0)
	end

	if self._pending_calls[id] ~= nil then
		record_outbound_call_diag(self, nil, 'not_admitted', {
			call_id = id,
			local_topic = checked_topic,
			remote_topic = remote_topic,
			payload = ev.payload,
			reason = 'duplicate_call_id',
			frame_admitted = false,
			frame_sent = false,
		})
		fail_request(ev.request or ev, 'duplicate_call_id')
		error('bridge duplicate outbound call id: ' .. id, 0)
	end

	if count_keys(self._pending_calls) >= self._max_pending_calls then
		record_outbound_call_diag(self, nil, 'not_admitted', {
			call_id = id,
			local_topic = checked_topic,
			remote_topic = remote_topic,
			payload = ev.payload,
			reason = 'too_many_pending_calls',
			frame_admitted = false,
			frame_sent = false,
		})
		fail_request(ev.request or ev, 'too_many_pending_calls')
		return
	end

	local reply_tx, reply_rx = mailbox.new(1, { full = 'reject_newest' })
	local owner = request_owner.new(ev.request or ev)

	local rec = {
		id             = id,
		reply_tx       = reply_tx,
		reply_rx       = reply_rx,
		reply_routed   = false,
		frame_admitted = false,
		session        = current_session(self),
		local_topic    = topics.copy(checked_topic),
		remote_topic   = topics.copy(remote_topic),
		payload        = ev.payload,
	}

	local call = {
		id       = id,
		topic    = remote_topic,
		payload  = ev.payload,
		timeout  = ev.timeout or (rule and rule.timeout) or self._default_call_timeout,
		owner    = owner,
		reply_policy = ev.reply_policy or (rule and rule.reply_policy) or 'reply-required',
		caps     = make_bridge_caps(self, rec.session),
		reply_tx = reply_tx,
		reply_rx = reply_rx,
		report_diag = function (diag)
			return queue.try_admit_required(
				self._done_tx,
				diag,
				'bridge_outbound_call_diag_report_failed'
			)
		end,

		mark_frame_admitted = function ()
			rec.frame_admitted = true
			return true
		end,
	}

	self._pending_calls[id] = rec
	update_model(self)
	record_outbound_call_diag(self, rec, 'queued', {
		frame_admitted = false,
		frame_sent = false,
	})

	local handle, start_err = start_bridge_work(
		self,
		{
			kind            = 'outbound_call_done',
			link_id         = self._link_id,
			link_generation = self._link_generation,
			call_id         = id,
		},
		run_outbound_call(call),
		'bridge_outbound_call_completion_report_failed',
		owner:caller_cancel_op()
	)

	if not handle then
		self._pending_calls[id] = nil
		reply_tx:close('outbound_call_start_failed')
		update_model(self)
		record_outbound_call_diag(self, rec, 'not_admitted', {
			reason = start_err or 'outbound_call_start_failed',
			frame_admitted = false,
			frame_sent = false,
		})

		owner:fail_once(start_err or 'outbound_call_start_failed')
		error(start_err or 'outbound_call_start_failed', 0)
	end

	rec.handle = handle
end

--------------------------------------------------------------------------------
-- Local bus command surface
--------------------------------------------------------------------------------

local function admit_bus_command(self, cmd, label)
	if self._bus_tx == nil then
		return nil, tostring(label or 'bridge_bus_command_failed') .. ': no_local_bus'
	end

	return queue.try_admit_required(
		self._bus_tx,
		cmd,
		label or 'bridge_bus_command_failed'
	)
end

local function bus_publish_import(self, topic, payload, frame, session)
	return admit_bus_command(self, {
		kind        = frame and frame.retain and 'retain' or 'publish',
		topic       = topic,
		payload     = payload,
		frame       = frame,
		session     = copy_context(session),
		origin_kind = frame and frame.retain and 'remote_retain' or 'remote_publish',
	}, 'bridge_bus_publish_import_failed')
end

local function bus_unretain_import(self, topic, frame, session)
	return admit_bus_command(self, {
		kind        = 'unretain',
		topic       = topic,
		frame       = frame,
		session     = copy_context(session),
		origin_kind = 'remote_unretain',
	}, 'bridge_bus_unretain_import_failed')
end

local function perform_bus_call(call_scope, self, frame, session, timeout)
	if self._bus_tx == nil then
		return { ok = false, err = 'no_local_bus' }
	end

	local reply_tx, reply_rx = mailbox.new(1, { full = 'reject_newest' })

	call_scope:finally(function (_, status, primary)
		reply_tx:close(primary or status or 'bus_call_closed')
	end)

	local ok, err = admit_bus_command(self, {
		kind        = 'call',
		topic       = frame.topic,
		payload     = frame.payload,
		frame       = frame,
		session     = copy_context(session),
		timeout     = timeout,
		reply_tx    = reply_tx,
		origin_kind = 'remote_call',
	}, 'bridge_bus_call_admit_failed')

	if ok ~= true then
		reply_tx:close(err or 'bus_call_admit_failed')
		return { ok = false, err = err or 'bus_call_admit_failed' }
	end

	local which, reply, recv_err = fibers.perform(fibers.named_choice {
		reply   = reply_rx:recv_op(),
		timeout = sleep.sleep_op(timeout),
	})

	if which == 'timeout' then
		return { ok = false, err = 'timeout' }
	end

	if reply == nil then
		return {
			ok  = false,
			err = recv_err
				or (reply_rx.why and reply_rx:why())
				or 'bus_call_closed',
		}
	end

	return reply
end

--------------------------------------------------------------------------------
-- Session and remote frames
--------------------------------------------------------------------------------

local cancel_pending_calls
local cancel_inbound_calls

local function clear_imported_retained(self, reason)
	local count = 0
	for key, rec in pairs(self._imported_retained) do
		self._imported_retained[key] = nil
		count = count + 1

		if rec and rec.topic then
			local frame = protocol.unretain(rec.topic)
			local ok, err = bus_unretain_import(self, rec.topic, frame, rec.session)
			if ok ~= true then
				error(err or 'bridge_clear_imported_unretain_failed', 0)
			end
		end
	end
	self._last_clear_reason = reason
	self._last_clear_count = count
	return count
end

local function clear_peer_session(self, reason, session, opts)
	opts = opts or {}

	if session ~= nil
		and self._session ~= nil
		and not same_session(self._session, session)
	then
		return
	end

	local had_session_state = self._session ~= nil
		or count_keys(self._imported_retained) > 0

	if not had_session_state and self._session_drop_reason ~= nil then
		return
	end

	clear_imported_retained(self, reason or 'session_dropped')

	if opts.cancel_calls ~= false then
		cancel_pending_calls(self, reason or 'session_dropped')
		cancel_inbound_calls(self, reason or 'session_dropped', false)
	end

	self._session = nil
	self._session_drop_reason = reason

	update_model(self, {
		session = nil,
		session_generation = nil,
		peer_sid = nil,
		session_drop_reason = self._session_drop_reason,
		last_clear_reason = self._last_clear_reason,
		last_clear_count = self._last_clear_count,
	})
end

local function require_session_context(ev, kind)
	local ctx = context_from_event(ev)

	if type(ctx) ~= 'table' or type(ctx.session_generation) ~= 'number' then
		error('bridge ' .. kind .. ' missing session context generation', 0)
	end

	if type(ctx.peer_sid) ~= 'string' or ctx.peer_sid == '' then
		error('bridge ' .. kind .. ' missing peer_sid', 0)
	end

	return ctx
end

local function handle_peer_session(self, ev)
	local ctx = require_session_context(ev, 'peer_session')

	if self._session ~= nil and not same_session(self._session, ctx) then
		clear_peer_session(self, 'new_peer_session')
	end

	self._session = copy_context(ctx)
	self._session_drop_reason = nil

	update_model(self, {
		session = copy_context(self._session),
		session_generation = self._session.session_generation,
		peer_sid = self._session.peer_sid,
		session_drop_reason = nil,
	})

	replay_local_retained_exports(self)
end

local function handle_peer_session_dropped(self, ev)
	local ctx = require_session_context(ev, 'peer_session_dropped')

	if not same_session(self._session, ctx) then
		return
	end

	clear_peer_session(self, ev.reason or 'session_dropped', ctx)
end

local function apply_remote_publish(self, frame, session)
	local local_topic = map_remote_import(self, frame.topic)
	if not local_topic then
		return
	end

	local local_frame = protocol.pub(local_topic, frame.payload, not not frame.retain)

	if frame.retain then
		self._imported_retained[topics.key(local_topic)] = {
			topic   = topics.copy(local_topic),
			payload = frame.payload,
			session = copy_context(session),
		}
		self._last_imported_topic = topic_string(local_topic)
		self._last_imported_at = fibers.now()
	end

	local ok, err = bus_publish_import(self, local_topic, frame.payload, local_frame, session)
	if ok ~= true then
		error(err or 'bridge_bus_publish_import_failed', 0)
	end

	update_model(self, {
		last_imported_topic = self._last_imported_topic,
		last_imported_at = self._last_imported_at,
	})
end

local function apply_remote_unretain(self, frame, session)
	local local_topic = map_remote_import(self, frame.topic)
	if not local_topic then
		return
	end

	local local_frame = protocol.unretain(local_topic)
	self._imported_retained[topics.key(local_topic)] = nil

	local ok, err = bus_unretain_import(self, local_topic, local_frame, session)
	if ok ~= true then
		error(err or 'bridge_bus_unretain_import_failed', 0)
	end

	update_model(self)
end

local function route_remote_reply(self, frame, session)
	local rec = self._pending_calls[frame.id]

	if not rec or rec.reply_routed or not same_session(rec.session, session) then
		return
	end

	local routed = {}
	for k, v in pairs(frame) do routed[k] = v end
	routed.session = copy_context(session)

	local ok, err = queue.try_admit_required(
		rec.reply_tx,
		routed,
		'bridge_reply_route_failed'
	)

	if ok == true then
		rec.reply_routed = true
		record_outbound_call_diag(self, rec, 'reply_routed', {
			reply_routed = true,
			frame_sent = true,
			ok = frame.ok,
			err = frame.err,
		})
		return
	end

	if type(err) == 'string' and err:match('closed') then
		return
	end

	error(err or 'bridge_reply_route_failed', 0)
end

local function start_inbound_call(self, frame, session)
	local id = frame.id
	local local_topic, rule = map_remote_call(self, frame.topic)

	if not local_topic then
		must_send_frame_now(
			self,
			protocol.reply(id, false, nil, 'no_route'),
			'bridge_no_route_inbound_reply_failed',
			session
		)
		return
	end

	if self._inbound_calls[id] ~= nil then
		must_send_frame_now(
			self,
			protocol.reply(id, false, nil, 'duplicate_call_id'),
			'bridge_duplicate_inbound_reply_failed',
			session
		)
		return
	end

	if count_keys(self._inbound_calls) >= self._max_inbound_calls then
		must_send_frame_now(
			self,
			protocol.reply(id, false, nil, 'too_many_inbound_calls'),
			'bridge_inbound_busy_reply_failed',
			session
		)
		return
	end

	local local_frame = protocol.call(id, local_topic, frame.payload)
	local timeout = rule and rule.timeout or self._default_call_timeout

	self._inbound_calls[id] = {
		id      = id,
		session = copy_context(session),
	}

	update_model(self)

	local handle, err = start_bridge_work(
		self,
		{
			kind            = 'inbound_call_done',
			link_id         = self._link_id,
			link_generation = self._link_generation,
			remote_call_id  = id,
		},
		function (call_scope)
			local reply = perform_bus_call(call_scope, self, local_frame, session, timeout)

			if type(reply) ~= 'table' then
				return { ok = false, err = 'local_call_failed' }
			end

			if reply.ok == true then
				return { ok = true, payload = reply.payload }
			end

			return { ok = false, err = reply.err or 'local_call_failed' }
		end,
		'bridge_inbound_call_completion_report_failed'
	)

	if not handle then
		self._inbound_calls[id] = nil
		update_model(self)

		must_send_frame_now(
			self,
			protocol.reply(id, false, nil, tostring(err or 'inbound_call_start_failed')),
			'bridge_inbound_start_failure_reply_failed',
			session
		)

		error(err or 'inbound_call_start_failed', 0)
	end

	self._inbound_calls[id].handle = handle
end

local function handle_frame(self, ev)
	local frame = ev.frame or ev
	local session = context_from_event(ev)

	local checked, err = protocol.validate(frame)
	if not checked then
		error('bridge invalid frame: ' .. tostring(err), 0)
	end

	if protocol.dispatch_lane(checked) ~= 'rpc' then
		return
	end

	self._frames_received = self._frames_received + 1
	update_model(self, { frames_received = self._frames_received })

	if checked.type == 'pub' then
		apply_remote_publish(self, checked, session)

	elseif checked.type == 'unretain' then
		apply_remote_unretain(self, checked, session)

	elseif checked.type == 'reply' then
		route_remote_reply(self, checked, session)

	elseif checked.type == 'call' then
		start_inbound_call(self, checked, session)

	else
		error('bridge unknown rpc frame type: ' .. tostring(checked.type), 0)
	end
end

local function session_frame_matches(self, ev)
	if type(ev) ~= 'table' then
		error('bridge session frame event must be a table', 0)
	end

	if ev.kind ~= 'session_frame' then
		error('bridge expected session_frame event', 0)
	end

	if ev.lane ~= 'rpc' then
		error('bridge received non-rpc session frame: ' .. tostring(ev.lane), 0)
	end

	local ctx = require_session_context(ev, 'session_frame')

	return has_current_session(self) and same_session(self._session, ctx)
end

local function handle_frame_event(self, ev)
	if session_frame_matches(self, ev) then
		handle_frame(self, ev)
	end
end

--------------------------------------------------------------------------------
-- Completion handling
--------------------------------------------------------------------------------

local function handle_outbound_call_done(self, ev)
	local rec = self._pending_calls[ev.call_id]
	if not rec then return end

	self._pending_calls[ev.call_id] = nil
	rec.reply_tx:close('outbound_call_done')

	if rec.frame_admitted then
		record_frame_sent(self)
	end

	local result = ev.result or {}
	record_outbound_call_diag(self, rec, result.event or 'done', {
		frame_admitted = rec.frame_admitted,
		frame_sent = result.frame_sent,
		reply_routed = rec.reply_routed,
		ok = result.ok,
		err = result.err,
		reason = result.err,
	})
	update_model(self)
end

local function handle_outbound_call_diag(self, ev)
	local rec = self._pending_calls[ev.call_id]
	if not rec then return end
	record_outbound_call_diag(self, rec, ev.event or 'diag', {
		frame_admitted = rec.frame_admitted,
		frame_sent = ev.frame_sent,
		reply_routed = rec.reply_routed,
		ok = ev.ok,
		err = ev.err,
		reason = ev.reason,
	})
end

local function inbound_reply_frame(ev)
	local remote_id = ev.remote_call_id

	if ev.status ~= 'ok' then
		return protocol.reply(
			remote_id,
			false,
			nil,
			tostring(ev.primary or ev.status or 'local_call_failed')
		)
	end

	local result = ev.result or {}

	if result.ok == false then
		return protocol.reply(
			remote_id,
			false,
			nil,
			tostring(result.err or 'local_call_failed')
		)
	end

	local payload = result.payload
	if payload == nil then payload = result.result end

	return protocol.reply(remote_id, true, payload, nil)
end

local function handle_inbound_call_done(self, ev)
	local rec = self._inbound_calls[ev.remote_call_id]
	if rec == nil then return end

	must_send_frame_now(
		self,
		inbound_reply_frame(ev),
		'bridge_inbound_reply_send_failed',
		rec.session
	)

	self._inbound_calls[ev.remote_call_id] = nil
	update_model(self)
end

local function handle_done(self, ev)
	if ev.kind == 'outbound_call_done' then
		handle_outbound_call_done(self, ev)

	elseif ev.kind == 'outbound_call_diag' then
		handle_outbound_call_diag(self, ev)

	elseif ev.kind == 'inbound_call_done' then
		handle_inbound_call_done(self, ev)

	else
		error('fabric.bridge: unknown completion kind: ' .. tostring(ev.kind), 0)
	end
end

--------------------------------------------------------------------------------
-- Event selection
--------------------------------------------------------------------------------

local function normalise_local_item(item)
	return item or { kind = 'local_closed' }
end

local function normalise_session_item(item)
	if item == nil then
		return { kind = 'session_closed' }
	end

	if type(item) ~= 'table' then
		error('bridge expected session event', 0)
	end

	return item
end

local function done_event_from_recv(ev)
	return ev or { kind = 'done_queue_closed' }
end

local function try_done_now(self)
	local ev, err = queue.try_recv_now(self._done_rx)

	if ev ~= nil then return done_event_from_recv(ev) end
	if err ~= 'not_ready' then return done_event_from_recv(nil) end

	return nil
end

local function try_local_now(self)
	if self._stopping or self._local_closed then
		return nil
	end

	local item, err = queue.try_recv_now(self._local_rx)

	if item ~= nil then return normalise_local_item(item) end
	if err ~= 'not_ready' then return normalise_local_item(nil) end

	return nil
end

local function try_session_now(self)
	if self._stopping or self._session_closed then
		return nil
	end

	local item, err = queue.try_recv_now(self._session_rx)

	if item ~= nil then return normalise_session_item(item) end
	if err ~= 'not_ready' then return normalise_session_item(nil) end

	return nil
end

local function next_event_op(self)
	return priority_event.sources_op {
		label   = 'fabric.bridge',
		pending = self._event_pending,
		sources = {
			{
				name = 'session',
				enabled = function ()
					return not self._stopping and not self._session_closed
				end,
				try_now = function ()
					return try_session_now(self)
				end,
				recv_op = function ()
					return self._session_rx:recv_op():wrap(normalise_session_item)
				end,
			},
			{
				name = 'done',
				try_now = function ()
					return try_done_now(self)
				end,
				recv_op = function ()
					return self._done_rx:recv_op():wrap(done_event_from_recv)
				end,
			},
			{
				name = 'local_event',
				enabled = function ()
					return not self._stopping and not self._local_closed
				end,
				try_now = function ()
					return try_local_now(self)
				end,
				recv_op = function ()
					return self._local_rx:recv_op():wrap(normalise_local_item)
				end,
			},
		},
	}
end

--------------------------------------------------------------------------------
-- Cancellation and shutdown
--------------------------------------------------------------------------------

cancel_pending_calls = function (self, reason, prune)
	for id, rec in pairs(self._pending_calls) do
		if rec.handle and rec.handle.cancel then
			rec.handle:cancel(reason)
		end

		if rec.reply_tx and type(rec.reply_tx.close) == 'function' then
			rec.reply_tx:close(reason)
		end

		if prune then
			self._pending_calls[id] = nil
		end
	end

	update_model(self)
end

cancel_inbound_calls = function (self, reason, reply_remote)
	for id, rec in pairs(self._inbound_calls) do
		if reply_remote and has_current_session(self) then
			must_send_frame_now(
				self,
				protocol.reply(id, false, nil, tostring(reason or 'cancelled')),
				'bridge_inbound_cancel_reply_send_failed',
				self._session
			)
		end

		if rec.handle and rec.handle.cancel then
			rec.handle:cancel(reason)
		end

		self._inbound_calls[id] = nil
	end

	update_model(self)
end

local function should_finish(self)
	if self._stopping then
		return count_keys(self._pending_calls) == 0
			and count_keys(self._inbound_calls) == 0
	end

	if not (self._local_closed and self._session_closed) then
		return false
	end

	return count_keys(self._pending_calls) == 0
		and count_keys(self._inbound_calls) == 0
end

--------------------------------------------------------------------------------
-- Coordinator
--------------------------------------------------------------------------------

local function handle_event(self, ev)
	if ev.kind == 'done_queue_closed' then
		error('fabric.bridge completion queue closed', 0)

	elseif ev.kind == 'local_closed' then
		self._local_closed = true
		update_model(self)

	elseif ev.kind == 'session_closed' then
		self._session_closed = true
		self._local_closed = true
		clear_peer_session(self, 'session_closed')
		update_model(self)

	elseif ev.kind == 'peer_session' then
		handle_peer_session(self, ev)

	elseif ev.kind == 'peer_session_dropped' then
		handle_peer_session_dropped(self, ev)

	elseif ev.kind == 'stop' then
		local reason = ev.reason or 'stopped'

		self._stopping = true
		self._local_closed = true

		cancel_pending_calls(self, reason)
		cancel_inbound_calls(self, reason, true)
		clear_peer_session(self, reason, nil, { cancel_calls = false })

		update_model(self, {
			state  = 'stopping',
			reason = reason,
		})

	elseif ev.kind == 'publish' then
		handle_local_publish(self, ev)

	elseif ev.kind == 'unretain' then
		handle_local_unretain(self, ev)

	elseif ev.kind == 'call' then
		start_outbound_call(self, ev)

	elseif ev.kind == 'session_frame' then
		handle_frame_event(self, ev)

	elseif ev.kind == 'outbound_call_done'
		or ev.kind == 'outbound_call_diag'
		or ev.kind == 'inbound_call_done'
	then
		handle_done(self, ev)

	else
		error('fabric.bridge: unknown event kind: ' .. tostring(ev.kind), 0)
	end
end

local function coordinator_loop(self)
	update_model(self, { state = 'running' })

	while not should_finish(self) do
		handle_event(self, fibers.perform(next_event_op(self)))
	end

	update_model(self, { state = 'completed' })

	return {
		role            = 'rpc_bridge',
		link_id         = self._link_id,
		link_generation = self._link_generation,
		snapshot        = public_snapshot(self),
	}
end

--------------------------------------------------------------------------------
-- Public API
--------------------------------------------------------------------------------

function M.run(scope, params)
	if type(scope) ~= 'table' then
		error('fabric.bridge.run: scope required', 2)
	end

	params = require_params(params)

	local link_id = params.link_id or 'link'
	local link_generation = params.link_generation or 1

	if type(link_id) ~= 'string' or link_id == '' then
		error('fabric.bridge.run: link_id must be a non-empty string', 2)
	end

	local model = model_mod.new(initial_snapshot(link_id, link_generation), {
		label = 'fabric.bridge',
	})

	scope:finally(function (_, status, primary)
		model:terminate(primary or status or 'fabric bridge closed')
	end)

	local done_tx, done_rx = mailbox.new(
		params.done_queue_len or DEFAULT_DONE_QUEUE,
		{ full = 'reject_newest' }
	)

	scope:finally(function ()
		done_tx:close('fabric bridge closed')
	end)

	local self = setmetatable({
		_scope                 = scope,
		_link_id               = link_id,
		_link_generation       = link_generation,
		_component_name        = params.component_name or 'rpc_bridge',
		_model                 = model,

		_local_rx              = require_rx(params.local_rx, 'bridge: local_rx', 2),
		_session_rx            = require_rx(params.session_rx, 'bridge: session_rx', 2),
		_outbound              = require_outbound(params.outbound, 'bridge: outbound', 2),
		_bus_tx                = params.bus_tx,
		_state_tx              = params.state_tx,
		_done_tx               = done_tx,
		_done_rx               = done_rx,

		_default_call_timeout  = positive_number(params.call_timeout_s, DEFAULT_CALL_TIMEOUT, 'bridge.call_timeout_s', 2),
		_max_pending_calls     = resolve_nonneg_int(
			params.max_pending_calls,
			DEFAULT_MAX_PENDING_CALLS,
			'bridge.max_pending_calls',
			2
		),
		_max_inbound_calls     = resolve_nonneg_int(
			params.max_inbound_calls,
			DEFAULT_MAX_INBOUND_CALLS,
			'bridge.max_inbound_calls',
			2
		),

		_import_rules          = params.import_rules or {},
		_export_publish_rules  = params.export_publish_rules or {},
		_export_retained_rules = params.export_retained_rules or {},
		_outbound_call_rules   = params.outbound_call_rules or {},
		_inbound_call_rules    = params.inbound_call_rules or {},

		_imported_retained     = {},
		_local_retained_exports = {},
		_pending_calls         = {},
		_inbound_calls         = {},

		_local_closed          = false,
		_session_closed        = false,
		_stopping              = false,
		_session               = nil,
		_session_drop_reason   = nil,

		_frames_sent           = 0,
		_frames_received       = 0,
		_last_imported_topic   = nil,
		_last_imported_at      = nil,
		_last_clear_reason     = nil,
		_last_clear_count      = 0,
		_event_pending         = {},
		_next_call_seq         = 0,
	}, Bridge)

	publish_state(self)

	scope:finally(function (_, status, primary)
		local reason = primary or status or 'fabric bridge closed'

		clear_peer_session(self, reason, nil, { cancel_calls = false })
		cancel_pending_calls(self, reason, true)
		cancel_inbound_calls(self, reason, false)
	end)

	return coordinator_loop(self)
end

M.make_bridge_caps = make_bridge_caps
M.RequestOwner = request_owner.RequestOwner
M.Bridge = Bridge

return M
