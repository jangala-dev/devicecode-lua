-- services/fabric/transfer.lua
--
-- Session-aware transfer manager.

local fibers  = require 'fibers'
local mailbox = require 'fibers.mailbox'

local scoped_work     = require 'devicecode.support.scoped_work'
local queue           = require 'devicecode.support.queue'
local service_events = require 'devicecode.support.service_events'
local priority_event  = require 'devicecode.support.priority_event'
local model_mod       = require 'services.fabric.model'
local resource        = require 'devicecode.support.resource'
local session_mod     = require 'services.fabric.session'
local state_mod       = require 'services.fabric.state'
local transfer_sender = require 'services.fabric.transfer_sender'

local M = {}

local DEFAULT_DONE_QUEUE = 64
local DEFAULT_ATTEMPT_FRAME_QUEUE = 16

local Manager = {}
Manager.__index = Manager

local SlotLease = {}
SlotLease.__index = SlotLease

local function copy(t)
	local out = {}
	for k, v in pairs(t or {}) do out[k] = v end
	return out
end

local function ctx(v)
	return v and session_mod.copy_context(v) or nil
end

local function ev_ctx(ev)
	return session_mod.context_from_event(ev)
end

local function same_ctx(a, b)
	return session_mod.same_session(a, b)
end

local function require_ctx(v, where)
	local c = ctx(v)
	if type(c) ~= 'table' or type(c.session_generation) ~= 'number' then
		error(where .. ': session context required', 2)
	end
	if type(c.peer_sid) ~= 'string' or c.peer_sid == '' then
		error(where .. ': peer_sid required', 2)
	end
	return c
end

local function req_id(req)
	return req.request_id or req.id
end

local function req_gen(req)
	return req.request_generation or 1
end

local function copy_active(a)
	if not a then return nil end
	return {
		request_id = a.request_id,
		request_generation = a.request_generation,
		session = ctx(a.session),
		status = a.status,
		xfer_id = a.xfer_id,
		target = a.target,
		size = a.size,
		sent = a.sent,
	}
end

local function copy_done(c)
	if not c then return nil end
	local out = copy(c)
	if type(out.result) == 'table' then out.result = copy(out.result) end
	return out
end

local function stat_equal(a, b)
	local x, y = a or {}, b or {}
	for k, v in pairs(x) do if y[k] ~= v then return false end end
	for k in pairs(y) do if x[k] == nil then return false end end
	return true
end

local function snapshot_equal(a, b)
	if a == b then return true end
	if type(a) ~= 'table' or type(b) ~= 'table' then return false end
	if a.manager_id ~= b.manager_id then return false end

	local aa, ba = a.active, b.active
	if (aa == nil) ~= (ba == nil) then return false end
	if aa and ba then
		if aa.request_id ~= ba.request_id then return false end
		if aa.request_generation ~= ba.request_generation then return false end
		if aa.status ~= ba.status then return false end
		if aa.xfer_id ~= ba.xfer_id then return false end
		if aa.target ~= ba.target then return false end
		if aa.size ~= ba.size then return false end
		if aa.sent ~= ba.sent then return false end
		if not same_ctx(aa.session, ba.session) then return false end
	end

	local al, bl = a.last, b.last
	if (al == nil) ~= (bl == nil) then return false end
	if al and bl then
		if al.request_id ~= bl.request_id then return false end
		if al.request_generation ~= bl.request_generation then return false end
		if al.status ~= bl.status then return false end
		if al.primary ~= bl.primary then return false end
	end

	return stat_equal(a.stats, b.stats)
end

function M.new_state(opts)
	opts = opts or {}

	return {
		manager_id = opts.manager_id or 'transfer-manager',
		active = nil,
		last = nil,
		stats = {
			frames_received = 0,
			frames_routed = 0,
			accepted = 0,
			rejected_busy = 0,
			completed = 0,
			stale = 0,
			failed = 0,
			cancelled = 0,
			released = 0,
		},
	}
end

function M.snapshot(state)
	return {
		manager_id = state.manager_id,
		active = copy_active(state.active),
		last = copy_done(state.last),
		stats = copy(state.stats),
	}
end

local function active_matches(state, ev)
	local a = state.active
	return a ~= nil
		and a.request_id == ev.request_id
		and a.request_generation == ev.request_generation
		and same_ctx(a.session, ev_ctx(ev))
end

function M.claim_slot(state, rec)
	if state.active ~= nil then
		state.stats.rejected_busy = state.stats.rejected_busy + 1
		return false, 'slot_busy'
	end

	local id = rec.request_id or rec.id
	if type(id) ~= 'string' or id == '' then
		error('transfer.claim_slot: request_id required', 2)
	end
	if type(rec.request_generation) ~= 'number' then
		error('transfer.claim_slot: request_generation required', 2)
	end

	state.active = {
		request_id = id,
		request_generation = rec.request_generation,
		session = require_ctx(rec.session, 'transfer.claim_slot'),
		status = rec.status or 'leased',
		xfer_id = rec.xfer_id,
		target = rec.target,
		size = rec.size,
		sent = 0,
		frame_tx = rec.frame_tx,
		lease = rec.lease,
	}
	state.stats.accepted = state.stats.accepted + 1

	return true, nil
end

function M.release_slot(state, ev)
	if not active_matches(state, ev) then
		state.stats.stale = state.stats.stale + 1
		return false, 'stale_slot_release'
	end

	local active = state.active
	state.last = {
		kind = ev.kind or 'transfer_slot_released',
		request_id = ev.request_id,
		request_generation = ev.request_generation,
		session = ctx(ev_ctx(ev)),
		status = 'released',
		primary = ev.primary or ev.reason,
	}
	state.active = nil
	state.stats.released = state.stats.released + 1

	return true, nil, active, state.last
end

function M.apply_attempt_done(state, ev)
	if not active_matches(state, ev) then
		state.stats.stale = state.stats.stale + 1
		return false, 'stale_attempt_completion'
	end

	local active = state.active
	state.last = {
		kind = ev.kind or 'transfer_attempt_done',
		request_id = ev.request_id,
		request_generation = ev.request_generation,
		session = ctx(ev_ctx(ev)),
		status = ev.status,
		report = ev.report,
		result = ev.result,
		primary = ev.primary,
	}
	state.active = nil
	state.stats.completed = state.stats.completed + 1

	if ev.status == 'failed' then
		state.stats.failed = state.stats.failed + 1
	elseif ev.status == 'cancelled' then
		state.stats.cancelled = state.stats.cancelled + 1
	end

	return true, nil, active, state.last
end

local function manager_snapshot(self)
	return M.snapshot(self._state)
end

local function emit_model(self, force)
	if not self._model then return end

	local snap = manager_snapshot(self)
	local changed = self._model:set_snapshot(snap)

	if (force or changed) and self._state_tx then
		state_mod.admit_component_snapshot_now(
			self._state_tx,
			self._link_id,
			self._link_generation,
			self._component_name,
			snap,
			'fabric_transfer_state_admit_failed'
		)
	end
end

local function close_feed(active, reason)
	if active and active.frame_tx and type(active.frame_tx.close) == 'function' then
		active.frame_tx:close(reason or 'transfer attempt closed')
	end
end

local function report(self, ev, label)
	if self._events_port and type(self._events_port.emit_required) == 'function' then
		return self._events_port:emit_required(ev, label or 'transfer_report_failed')
	end
	return queue.try_admit_required(self._done_tx, ev, label or 'transfer_report_failed')
end

local function attempt_identity(req)
	return {
		kind = 'transfer_attempt_done',
		request_id = req_id(req),
		request_generation = req_gen(req),
		session = ctx(req.session),
	}
end

local function release_identity(lease, reason)
	return {
		kind = 'transfer_slot_released',
		request_id = lease._request_id,
		request_generation = lease._request_generation,
		session = ctx(lease._session),
		xfer_id = lease._xfer_id,
		reason = reason,
		primary = reason,
	}
end

local function attempt_caps(self, frame_rx, session)
	local c = ctx(session or self._session)
	local outbound = self._outbound

	return {
		manager_id = self._state.manager_id,
		frame_rx = frame_rx,
		session = ctx(c),
		chunk_size = self._chunk_size,
		timeout_s = self._timeout_s,

		send_control_frame_now = function (frame, label)
			return outbound:send_transfer_control_frame_now(c, frame, label)
		end,

		send_bulk_frame_now = function (frame, label)
			return outbound:send_transfer_bulk_frame_now(c, frame, label)
		end,

		transfer_quiet_begin = function (xfer_id)
			if type(outbound.begin_transfer) == 'function' then
				return outbound:begin_transfer(c, xfer_id)
			end
			return true, nil
		end,

		transfer_quiet_end = function (xfer_id, reason)
			if type(outbound.end_transfer) == 'function' then
				return outbound:end_transfer(c, xfer_id, reason)
			end
			return true, nil
		end,
	}
end

local function run_attempt(scope, req, caps)
	local owner = req.source_owner
	if type(owner) ~= 'table' or type(owner.handoff) ~= 'function' then
		error('transfer attempt requires source_owner', 0)
	end

	local source, err = owner:handoff(function (value)
		scope:finally(function (_, status, primary)
			resource.terminate_checked(
				value,
				primary or status or 'transfer attempt closed',
				'transfer source cleanup failed'
			)
		end)
		return true
	end)
	if source == nil then error(err or 'source handoff failed', 0) end

	local worker_req = copy(req)
	worker_req.source = source
	worker_req.source_owner = nil

	local quiet_started = false
	if type(caps.transfer_quiet_begin) == 'function' then
		local ok = caps.transfer_quiet_begin(worker_req.xfer_id)
		if ok == true then
			quiet_started = true
		end
	end

	scope:finally(function (_, status, primary)
		if quiet_started and type(caps.transfer_quiet_end) == 'function' then
			caps.transfer_quiet_end(
				worker_req.xfer_id,
				primary or status or 'transfer_attempt_closed'
			)
		end
	end)

	local result = transfer_sender.run(scope, worker_req, caps)
	if type(result) ~= 'table' then error('transfer attempt must return a result table', 0) end
	return result
end

function SlotLease:release(reason)
	if self._released then return true, nil end

	self._released = true
	if self._frame_tx then self._frame_tx:close(reason or 'transfer slot released') end

	local manager = self._manager
	if not manager or not manager._done_tx then return true, nil end

	local ok, err = report(manager, release_identity(self, reason or 'transfer slot released'),
		'transfer_slot_release_report_failed')

	if ok == true then return true, nil end
	if type(err) == 'string' and err:match('closed') then return true, nil end
	return nil, err
end

function SlotLease:terminate(reason)
	return self:release(reason)
end

function SlotLease:_poison(reason)
	if self._released then return true, nil end

	self._released = true
	self._invalid_reason = reason or 'transfer slot no longer active'
	if self._frame_tx then self._frame_tx:close(self._invalid_reason) end

	return true, nil
end

local function lease_active(lease)
	local active = lease._manager and lease._manager._state and lease._manager._state.active
	return active ~= nil
		and active.request_id == lease._request_id
		and active.request_generation == lease._request_generation
		and same_ctx(active.session, lease._session)
end

function SlotLease:start_attempt(request_scope, req)
	if self._invalid_reason then return nil, self._invalid_reason end
	if self._released then return nil, 'transfer slot lease already released' end
	if self._attempt_started then return nil, 'transfer slot lease already used' end
	if not lease_active(self) then return nil, 'transfer slot lease no longer active' end

	self._attempt_started = true

	local manager = self._manager
	local local_tx, local_rx = mailbox.new(1, { full = 'reject_newest' })
	local attempt_req = copy(req or {})

	attempt_req.request_id = self._request_id
	attempt_req.request_generation = self._request_generation
	attempt_req.session = ctx(self._session)
	attempt_req.xfer_id = self._xfer_id

	request_scope:finally(function (_, status, primary)
		local_tx:close(primary or status or 'transfer attempt observer closed')
	end)

	local send_attempt_result = function (ev)
		local ok, rerr = report(manager, ev, 'transfer_attempt_report_failed')
		if ok ~= true then return nil, rerr end
		queue.try_send_now(local_tx, ev)
		return true, nil
	end

	local raw, err = scoped_work.start {
		lifetime_scope = request_scope,
		reaper_scope = request_scope,
		report_scope = manager._scope,
		identity = attempt_identity(attempt_req),

		run = function (scope)
			return run_attempt(scope, attempt_req, attempt_caps(manager, self._frame_rx, self._session))
		end,

		report = send_attempt_result,
	}

	if not raw then
		self._attempt_started = false
		local_tx:close(err or 'transfer attempt start failed')
		return nil, err
	end

	return {
		cancel = function (_, reason) return raw:cancel(reason) end,
		outcome = function () return raw:outcome() end,
		identity = function () return raw:identity() end,

		outcome_op = function ()
			return local_rx:recv_op():wrap(function (ev, recv_err)
				if ev ~= nil then return ev end

				return {
					kind = 'transfer_attempt_done',
					request_id = attempt_req.request_id,
					request_generation = attempt_req.request_generation,
					session = ctx(attempt_req.session),
					status = 'failed',
					primary = recv_err or 'transfer attempt observer closed',
				}
			end)
		end,
	}, nil
end

local function new_lease(self, rec)
	local c = ctx(rec.session)

	return setmetatable({
		request_id = rec.request_id,
		request_generation = rec.request_generation,
		session = ctx(c),
		xfer_id = rec.xfer_id,

		_manager = self,
		_request_id = rec.request_id,
		_request_generation = rec.request_generation,
		_session = ctx(c),
		_xfer_id = rec.xfer_id,
		_frame_tx = rec.frame_tx,
		_frame_rx = rec.frame_rx,
		_released = false,
		_attempt_started = false,
	}, SlotLease)
end

function M.start_attempt(request_scope, lease, req)
	if type(lease) ~= 'table' or type(lease.start_attempt) ~= 'function' then
		return nil, 'transfer.start_attempt: lease required'
	end
	return lease:start_attempt(request_scope, req)
end

local function reply_slot(req, value)
	if type(req.reply) ~= 'function' then return nil, 'slot request has no reply method' end
	return req:reply(value)
end

local function fail_slot(req, reason)
	if type(req.fail) ~= 'function' then return nil, 'slot request has no fail method' end
	return req:fail(reason)
end

local function handle_slot_request(self, req)
	local id = req_id(req)
	if type(id) ~= 'string' or id == '' then
		error('transfer slot request requires request_id', 2)
	end

	if self._session == nil then
		fail_slot(req, 'no_session')
		emit_model(self)
		return
	end

	local frame_tx, frame_rx = mailbox.new(self._attempt_frame_queue_len, { full = 'reject_newest' })
	local rec = {
		request_id = id,
		request_generation = req_gen(req),
		session = ctx(self._session),
		xfer_id = req.xfer_id or id,
		target = req.target,
		size = req.size,
		frame_tx = frame_tx,
		frame_rx = frame_rx,
	}

	local ok, reason = M.claim_slot(self._state, rec)
	if not ok then
		frame_tx:close(reason or 'slot_busy')
		fail_slot(req, reason or 'slot_busy')
		emit_model(self)
		return
	end

	local lease = new_lease(self, rec)
	self._state.active.lease = lease

	local replied, err = reply_slot(req, { ok = true, lease = lease })
	if replied ~= true then
		lease:release(err or 'slot admission reply failed')
	end

	emit_model(self)
end

local function active_done(self, reason, session)
	local active = self._state.active

	if session ~= nil and active ~= nil and not same_ctx(active.session, session) then
		return
	end

	if active ~= nil then
		if active.lease and type(active.lease._poison) == 'function' then
			active.lease:_poison(reason or 'session_dropped')
		else
			close_feed(active, reason or 'session_dropped')
		end

		self._state.last = {
			kind = 'transfer_session_dropped',
			request_id = active.request_id,
			request_generation = active.request_generation,
			session = ctx(active.session),
			status = 'cancelled',
			primary = reason or 'session_dropped',
		}

		self._state.active = nil
		self._state.stats.cancelled = self._state.stats.cancelled + 1
	end

	emit_model(self)
end

local function handle_attempt_done(self, ev)
	local accepted, _, active = M.apply_attempt_done(self._state, ev)
	if accepted then close_feed(active, 'transfer attempt completed') end
	emit_model(self)
end

local function handle_slot_released(self, ev)
	local accepted, _, active = M.release_slot(self._state, ev)
	if accepted then close_feed(active, ev.reason or 'transfer slot released') end
	emit_model(self)
end

local function handle_frame(self, ev)
	self._state.stats.frames_received = self._state.stats.frames_received + 1

	local active = self._state.active
	local frame = ev.frame
	local frame_type = type(frame) == 'table' and frame.type or nil

	if not active
		or type(frame) ~= 'table'
		or frame.xfer_id ~= active.xfer_id
		or not same_ctx(active.session, ev_ctx(ev))
	then
		self._state.stats.stale = self._state.stats.stale + 1
		emit_model(self)
		return
	end

	if frame_type == 'xfer_ready' then
		active.status = 'ready'
	elseif frame_type == 'xfer_need' and type(frame.next) == 'number' then
		active.status = 'sending'
		active.sent = frame.next
	elseif frame_type == 'xfer_done' then
		active.status = 'done'
		active.sent = active.size or active.sent
	elseif frame_type == 'xfer_abort' then
		active.status = 'aborted'
	end

	local ok, err = queue.try_admit_required(active.frame_tx, ev,
		'transfer_attempt_frame_admission_failed')
	if ok ~= true then error(err or 'transfer_attempt_frame_admission_failed', 0) end

	self._state.stats.frames_routed = self._state.stats.frames_routed + 1
	emit_model(self)
end

local function handle_peer_session(self, ev)
	local c = require_ctx(ev_ctx(ev), 'transfer peer_session')

	if self._session ~= nil and not same_ctx(self._session, c) then
		active_done(self, 'new_peer_session')
	end

	self._session = ctx(c)
	emit_model(self)
end

local function handle_peer_session_dropped(self, ev)
	local c = require_ctx(ev_ctx(ev), 'transfer peer_session_dropped')
	if not same_ctx(self._session, c) then return end

	active_done(self, ev.reason or 'session_dropped', c)
	self._session = nil
	emit_model(self)
end

local function map_done(ev)
	return ev or { kind = 'done_queue_closed' }
end

local function map_admission(req)
	if req == nil then return { kind = 'admission_queue_closed' } end
	return { kind = 'slot_request', req = req }
end

local function map_session(item)
	if item == nil then return { kind = 'session_queue_closed' } end
	if type(item) ~= 'table' then error('transfer expected session event', 0) end

	if item.kind == 'peer_session' or item.kind == 'peer_session_dropped' then
		require_ctx(ev_ctx(item), 'transfer session event')
		return item
	end

	if item.kind ~= 'session_frame' then error('transfer expected session event', 0) end
	if item.lane ~= 'transfer' then
		error('transfer received non-transfer session frame: ' .. tostring(item.lane), 0)
	end
	if type(item.frame) ~= 'table' then error('transfer session_frame missing frame', 0) end

	return {
		kind = 'transfer_frame',
		frame = item.frame,
		at = item.at,
		session = require_ctx(ev_ctx(item), 'transfer session_frame'),
	}
end

local function try_rx(open, rx, mapper)
	if not open or rx == nil then return nil end

	local item, err = queue.try_recv_now(rx)
	if item ~= nil then return mapper(item) end
	if err ~= 'not_ready' then return mapper(nil) end
	return nil
end

local function next_event_op(self)
	return priority_event.sources_op {
		label = 'fabric.transfer.manager',
		pending = self._event_pending,
		sources = {
			{
				name = 'done',
				try_now = function () return try_rx(true, self._done_rx, map_done) end,
				recv_op = function () return self._done_rx:recv_op():wrap(map_done) end,
			},
			{
				name = 'session',
				enabled = function () return self._session_open end,
				try_now = function () return try_rx(self._session_open, self._session_rx, map_session) end,
				recv_op = function () return self._session_rx:recv_op():wrap(map_session) end,
			},
			{
				name = 'admission',
				enabled = function () return self._admission_open end,
				try_now = function () return try_rx(self._admission_open, self._admission_rx, map_admission) end,
				recv_op = function () return self._admission_rx:recv_op():wrap(map_admission) end,
			},
		},
	}
end

local function dispatch(self, ev)
	if ev.kind == 'peer_session' then
		handle_peer_session(self, ev)

	elseif ev.kind == 'peer_session_dropped' then
		handle_peer_session_dropped(self, ev)

	elseif ev.kind == 'slot_request' then
		handle_slot_request(self, ev.req)

	elseif ev.kind == 'admission_queue_closed' then
		self._admission_open = false

	elseif ev.kind == 'session_queue_closed' then
		self._session_open = false
		active_done(self, 'session_closed')
		self._session = nil

	elseif ev.kind == 'transfer_frame' then
		handle_frame(self, ev)

	elseif ev.kind == 'transfer_attempt_done' then
		handle_attempt_done(self, ev)

	elseif ev.kind == 'transfer_slot_released' then
		handle_slot_released(self, ev)

	elseif ev.kind == 'done_queue_closed' then
		error('transfer manager done queue closed', 0)

	else
		error('transfer manager unknown event kind: ' .. tostring(ev.kind), 0)
	end
end

local function should_finish(self)
	return not self._admission_open
		and not self._session_open
		and self._state.active == nil
end

local function cancel_active(self, reason)
	local active = self._state.active
	if active and active.lease and type(active.lease._poison) == 'function' then
		active.lease:_poison(reason or 'transfer manager closing')
	else
		close_feed(active, reason or 'transfer manager closing')
	end
end

local function coordinator_loop(self)
	while not should_finish(self) do
		dispatch(self, fibers.perform(next_event_op(self)))
	end

	return {
		role = 'transfer_manager',
		manager_id = self._state.manager_id,
		snapshot = manager_snapshot(self),
	}
end

function M.run(scope, params)
	if type(scope) ~= 'table' then error('transfer.run: scope required', 2) end
	if type(params) ~= 'table' then error('transfer.run: params table required', 2) end
	if not params.admission_rx then error('transfer.run: admission_rx required', 2) end
	if not params.session_rx then error('transfer.run: session_rx required', 2) end

	local outbound = params.outbound or params.outbound_gate
	if type(outbound) ~= 'table'
		or type(outbound.send_transfer_control_frame_now) ~= 'function'
		or type(outbound.send_transfer_bulk_frame_now) ~= 'function'
	then
		error('transfer.run: fabric.session outbound gate required', 2)
	end

	local state = M.new_state { manager_id = params.manager_id }
	local model = model_mod.new(M.snapshot(state), {
		copy = M.snapshot,
		equals = snapshot_equal,
		label = 'fabric.transfer',
	})

	scope:finally(function (_, status, primary)
		model:terminate(primary or status or 'transfer manager closed')
	end)

	local done_tx, done_rx = mailbox.new(params.done_queue_len or DEFAULT_DONE_QUEUE,
		{ full = 'reject_newest' })

	scope:finally(function ()
		done_tx:close('transfer manager closed')
	end)

	local self = setmetatable({
		_scope = scope,
		_state = state,
		_model = model,
		_state_tx = params.state_tx,
		_component_name = params.component_name or 'transfer_manager',
		_link_id = params.link_id,
		_link_generation = params.link_generation,

		_admission_rx = params.admission_rx,
		_session_rx = params.session_rx,
		_admission_open = true,
		_session_open = true,

		_done_tx = done_tx,
		_done_rx = done_rx,
		_events_port = service_events.port(done_tx, {
			source = 'fabric_transfer',
			source_id = params.manager_id or params.link_id or 'transfer_manager',
			link_id = params.link_id,
			link_generation = params.link_generation,
		}, { label = 'fabric_transfer_event_report_failed' }),
		_outbound = outbound,
		_attempt_frame_queue_len = params.attempt_frame_queue_len or DEFAULT_ATTEMPT_FRAME_QUEUE,
		_chunk_size = params.chunk_size,
		_timeout_s = params.timeout_s,
		_session = nil,
		_event_pending = {},
	}, Manager)

	emit_model(self, true)

	scope:finally(function (_, status, primary)
		cancel_active(self, primary or status or 'transfer manager closed')
	end)

	return coordinator_loop(self)
end

M.make_attempt_caps = attempt_caps
M.SlotLease = SlotLease
M.Manager = Manager

return M
