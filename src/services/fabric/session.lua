-- services/fabric/session.lua
-- Fabric session owner. Reader/link policy owns wire-error budgeting.
local fibers = require 'fibers'
local sleep  = require 'fibers.sleep'
local uuid   = require 'uuid'
local queue          = require 'devicecode.support.queue'
local priority_event = require 'devicecode.support.priority_event'
local model_mod      = require 'services.fabric.model'
local protocol       = require 'services.fabric.protocol'
local contracts      = require 'devicecode.support.contracts'
local validate       = require 'shared.validate'

local M = {}

local Session = {}
Session.__index = Session

local OutboundGate = {}
OutboundGate.__index = OutboundGate

local DEFAULT_HELLO_INTERVAL = 1.0
local DEFAULT_PING_INTERVAL = 5.0
local DEFAULT_LIVENESS_TIMEOUT = 15.0
local DEFAULT_BAD_FRAME_LIMIT = 5
local DEFAULT_BAD_FRAME_WINDOW_S = 10.0

local function require_rx(v, name, level)
	return contracts.require_rx(v, name, (level or 1) + 1)
end

local function require_tx(v, name, level)
	return contracts.require_tx(v, name, (level or 1) + 1)
end

local function positive_number(v, fallback, name)
	if v == nil then return fallback end
	if type(v) ~= 'number' or v ~= v or v == math.huge or v == -math.huge or v <= 0 then
		error('fabric.session: ' .. name .. ' must be a positive finite number', 3)
	end
	return v
end

local function positive_integer(v, fallback, name)
	if v == nil then return fallback end
	return validate.positive_integer(v, 'fabric.session: ' .. name, 2)
end

function M.new_session_context(args)
	if type(args) ~= 'table' then
		error('fabric.session.new_session_context: args table required', 2)
	end
	return {
		proto              = args.proto,
		link_id            = args.link_id,
		link_generation    = args.link_generation,
		session_generation = args.session_generation,
		local_node         = args.local_node,
		local_sid          = args.local_sid,
		peer_node          = args.peer_node,
		peer_sid           = args.peer_sid,
		identity_claim     = protocol.copy_reserved_claim(args.identity_claim),
		auth_claim         = protocol.copy_reserved_claim(args.auth_claim),
		auth_state         = args.auth_state or 'unauthenticated',
		authenticated      = args.authenticated == true,
		established_at     = args.established_at,
	}
end

function M.copy_context(ctx)
	if type(ctx) ~= 'table' then return nil end
	return M.new_session_context(ctx)
end

function M.context_from_event(ev)
	if type(ev) ~= 'table' or type(ev.session) ~= 'table' then return nil end
	return M.copy_context(ev.session)
end

function M.same_session(a, b)
	return type(a) == 'table'
		and type(b) == 'table'
		and a.link_id == b.link_id
		and a.link_generation == b.link_generation
		and a.session_generation == b.session_generation
		and a.peer_sid == b.peer_sid
end

local function context_from_snapshot(self, cur, at)
	return M.new_session_context {
		proto              = cur.proto,
		link_id            = self._link_id,
		link_generation    = self._link_generation,
		session_generation = cur.session_generation,
		local_node         = cur.local_node,
		local_sid          = cur.local_sid,
		peer_node          = cur.peer_node,
		peer_sid           = cur.peer_sid,
		identity_claim     = cur.peer_identity_claim,
		auth_claim         = cur.peer_auth_claim,
		auth_state         = cur.auth_state,
		authenticated      = cur.authenticated,
		established_at     = at,
	}
end

local function context_from_peer_frame(self, frame, generation, at)
	local cur = self._session_model:snapshot()
	return M.new_session_context {
		proto              = frame.proto,
		link_id            = self._link_id,
		link_generation    = self._link_generation,
		session_generation = generation,
		local_node         = cur.local_node,
		local_sid          = cur.local_sid,
		peer_node          = frame.node,
		peer_sid           = frame.sid,
		identity_claim     = protocol.normalise_reserved_claim(frame.identity),
		auth_claim         = protocol.normalise_reserved_claim(frame.auth),
		auth_state         = self._auth_state,
		authenticated      = self._authenticated,
		established_at     = at,
	}
end

local function close_unique_txs(txs, reason)
	local seen = {}
	for _, tx in pairs(txs or {}) do
		if tx ~= nil and not seen[tx] then
			seen[tx] = true
			if type(tx.close) == 'function' then tx:close(reason) end
		end
	end
end

function OutboundGate:bind(ctx)
	self._session = M.copy_context(ctx)
	self._drop_reason = nil
	return true, nil
end

function OutboundGate:drop(reason)
	self._session = nil
	self._drop_reason = reason or 'no_session'
	return true, nil
end

function OutboundGate:session()
	return M.copy_context(self._session)
end

function OutboundGate:terminate(reason)
	if self._closed then return true, nil end
	self._closed = true
	self._session = nil
	self._drop_reason = reason or 'session_outbound_closed'
	close_unique_txs(self._lane_txs, self._drop_reason)
	return true, nil
end

function OutboundGate:_admit(ctx, frame, expected_lane, label)
	if self._closed then
		return nil, tostring(label or 'session_outbound_closed') .. ': closed'
	end
	local checked, err = protocol.validate(frame)
	if not checked then
		return nil, tostring(label or 'session_outbound_invalid') .. ': ' .. tostring(err)
	end
	local lane, lerr = protocol.writer_lane(checked)
	if not lane then
		return nil, tostring(label or 'session_outbound_invalid_lane') .. ': ' .. tostring(lerr)
	end
	if expected_lane ~= nil and lane ~= expected_lane then
		return nil, tostring(label or 'session_outbound_wrong_lane') .. ': ' .. tostring(lane)
	end
	local current = self._session
	if not current then
		return nil, tostring(label or 'session_outbound_no_session') .. ': ' .. tostring(self._drop_reason or 'no_session')
	end
	if not M.same_session(current, ctx) then
		return nil, tostring(label or 'session_outbound_stale_session') .. ': stale_session'
	end
	local tx = self._lane_txs and self._lane_txs[lane]
	if tx == nil then
		return nil, tostring(label or 'session_outbound_missing_lane') .. ': ' .. tostring(lane)
	end
	return queue.try_admit_required(tx, {
		kind    = 'send_frame',
		lane    = lane,
		frame   = checked,
		session = M.copy_context(current),
	}, label or 'session_outbound_send_failed')
end

function OutboundGate:send_frame_now(ctx, frame, label)
	return self:_admit(ctx, frame, nil, label)
end

function OutboundGate:send_rpc_frame_now(ctx, frame, label)
	return self:_admit(ctx, frame, 'rpc', label)
end

function OutboundGate:send_transfer_control_frame_now(ctx, frame, label)
	return self:_admit(ctx, frame, 'control', label)
end

function OutboundGate:send_transfer_bulk_frame_now(ctx, frame, label)
	return self:_admit(ctx, frame, 'bulk', label)
end

function M.new_outbound_gate(params)
	params = params or {}
	return setmetatable({
		_lane_txs = {
			control = require_tx(params.tx_control, 'fabric.session.outbound_gate: tx_control', 2),
			rpc     = require_tx(params.tx_rpc,     'fabric.session.outbound_gate: tx_rpc', 2),
			bulk    = require_tx(params.tx_bulk,    'fabric.session.outbound_gate: tx_bulk', 2),
		},
		_session = nil,
		_drop_reason = 'no_session',
		_closed = false,
	}, OutboundGate)
end

local function session_equal(a, b)
	if a == b then return true end
	if type(a) ~= 'table' or type(b) ~= 'table' then return false end
	for k, v in pairs(a) do if b[k] ~= v then return false end end
	for k in pairs(b) do if a[k] == nil then return false end end
	return true
end

local function session_snapshot(self)
	return self._session_model:snapshot()
end

local function publish_state(self)
	if self._state_tx == nil then return true, nil end
	local state_mod = require 'services.fabric.state'
	return state_mod.admit_component_snapshot_now(
		self._state_tx,
		self._link_id,
		self._link_generation,
		self._component_name,
		session_snapshot(self),
		'fabric_session_state_admit_failed'
	)
end

local function update_session(self, mutator)
	local changed, err = self._session_model:update(function (cur)
		mutator(cur)
		return cur
	end)
	if changed == true then
		local ok, perr = publish_state(self)
		if ok ~= true then error(perr or 'fabric_session_state_admit_failed', 0) end
	end
	return changed, err
end

local function admit_control_frame_now(tx, frame, label)
	local checked, err = protocol.validate(frame)
	if not checked then
		return nil, tostring(label or 'session_control_invalid') .. ': ' .. tostring(err)
	end
	return queue.try_admit_required(tx, {
		kind  = 'send_frame',
		frame = checked,
	}, label or 'session_control_send_failed')
end

local function must_admit_control_frame_now(tx, frame, label)
	local ok, err = admit_control_frame_now(tx, frame, label)
	if ok ~= true then error(err or label or 'session_control_send_failed', 0) end
	return true
end

local function session_event(self, kind, ctx, extra, at)
	local ev = { kind = kind, session = M.copy_context(ctx), at = at or fibers.now() }
	for k, v in pairs(extra or {}) do ev[k] = v end
	return ev
end

local function peer_session_event(self, ctx, at)
	return session_event(self, 'peer_session', ctx, nil, at)
end

local function peer_session_dropped_event(self, ctx, reason, at)
	return session_event(self, 'peer_session_dropped', ctx, { reason = reason or 'session_dropped' }, at)
end

local function session_frame_event(self, lane, frame, at)
	return session_event(self, 'session_frame', context_from_snapshot(self, session_snapshot(self), at), {
		lane = lane,
		frame = frame,
	}, at)
end

local function publish_to(tx, ev, label)
	if tx == nil then return true, nil end
	return queue.try_admit_required(tx, ev, label or 'session_event_admit_failed')
end

local function must_publish_to(tx, ev, label)
	local ok, err = publish_to(tx, ev, label)
	if ok ~= true then error(err or label or 'session_event_admit_failed', 0) end
	return true
end

local function publish_lifecycle(self, ev)
	must_publish_to(self._rpc_tx, ev, 'session_rpc_lifecycle_admit_failed')
	must_publish_to(self._transfer_tx, ev, 'session_transfer_lifecycle_admit_failed')
	return true
end

local function publish_session_drop(self, cur, reason, at)
	if not cur or cur.established ~= true or cur.peer_sid == nil then return true, nil end
	return publish_lifecycle(
		self,
		peer_session_dropped_event(self, context_from_snapshot(self, cur, at), reason, at)
	)
end

local function same_peer(cur, frame)
	return type(frame.sid) == 'string'
		and cur.peer_sid ~= nil
		and frame.sid == cur.peer_sid
end

local function establish_from_peer(self, frame, at)
	at = at or fibers.now()
	local cur = session_snapshot(self)
	local first = cur.established ~= true
	local sid_changed = cur.peer_sid ~= frame.sid
	local generation = cur.session_generation or 0
	if first or sid_changed then generation = generation + 1 end
	if sid_changed and cur.established == true then
		publish_session_drop(self, cur, 'peer_sid_changed', at)
	end
	local ctx = context_from_peer_frame(self, frame, generation, at)
	update_session(self, function (s)
		s.phase = 'established'
		s.established = true
		s.peer_sid = frame.sid
		s.peer_node = frame.node
		s.peer_identity_claim = protocol.normalise_reserved_claim(frame.identity)
		s.peer_auth_claim = protocol.normalise_reserved_claim(frame.auth)
		s.auth_state = self._auth_state
		s.authenticated = self._authenticated
		s.proto = frame.proto
		s.why = nil
		if first or sid_changed then s.session_generation = generation end
	end)
	self._outbound:bind(ctx)
	self._last_peer_at = at
	self._next_ping_at = at + self._ping_interval
	if first or sid_changed then
		publish_lifecycle(self, peer_session_event(self, ctx, at))
	end
end

local function refresh_peer(self, frame, at)
	update_session(self, function (s)
		if frame.node ~= nil then s.peer_node = frame.node end
		if frame.identity ~= nil then s.peer_identity_claim = protocol.normalise_reserved_claim(frame.identity) end
		if frame.auth ~= nil then s.peer_auth_claim = protocol.normalise_reserved_claim(frame.auth) end
	end)
	self._last_peer_at = at or fibers.now()
end

local function reset_to_hello(self, reason, now)
	now = now or fibers.now()
	local cur = session_snapshot(self)
	publish_session_drop(self, cur, reason, now)
	self._outbound:drop(reason or 'session_dropped')
	update_session(self, function (s)
		s.phase = 'hello'
		s.local_sid = tostring(uuid.new())
		s.peer_sid = nil
		s.peer_node = nil
		s.peer_identity_claim = nil
		s.peer_auth_claim = nil
		s.auth_state = self._auth_state
		s.authenticated = self._authenticated
		s.proto = nil
		s.established = false
		s.why = reason
	end)
	self._last_peer_at = nil
	self._next_hello_at = now
	self._next_ping_at = math.huge
end

local function send_hello(self)
	local cur = session_snapshot(self)
	must_admit_control_frame_now(
		self._tx_control,
		assert(protocol.hello(cur.local_sid, self._local_node, self._identity_claim, self._auth_claim)),
		'session_hello_send_failed'
	)
	self._next_hello_at = fibers.now() + self._hello_interval
end

local function send_hello_ack(self)
	local cur = session_snapshot(self)
	must_admit_control_frame_now(
		self._tx_control,
		assert(protocol.hello_ack(cur.local_sid, self._local_node, self._identity_claim, self._auth_claim)),
		'session_hello_ack_send_failed'
	)
end

local function send_ping(self)
	local cur = session_snapshot(self)
	must_admit_control_frame_now(self._tx_control, assert(protocol.ping(cur.local_sid)), 'session_ping_send_failed')
	self._next_ping_at = fibers.now() + self._ping_interval
end

local function send_pong(self)
	local cur = session_snapshot(self)
	must_admit_control_frame_now(self._tx_control, assert(protocol.pong(cur.local_sid)), 'session_pong_send_failed')
end

local function session_next_deadline(self)
	local cur = session_snapshot(self)
	local now = fibers.now()
	if cur.established ~= true then
		return self._next_hello_at or now, 'hello'
	end
	local ping = self._next_ping_at or math.huge
	local live = (self._last_peer_at or now) + self._liveness_timeout
	if live <= ping then return live, 'liveness' end
	return ping, 'ping'
end

local function frame_event_from_item(item)
	if item == nil then return { kind = 'frame_closed' } end
	if type(item) == 'table' and item.kind == 'frame_received' then
		return {
			kind  = 'frame',
			frame = item.frame,
			at    = item.at or fibers.now(),
		}
	end

	if type(item) == 'table' and item.kind == 'wire_error' then
		return {
			kind = 'wire_error',
			err  = item.err or 'wire_error',
			at   = item.at or fibers.now(),
		}
	end
	return {
		kind = 'invalid_frame_item',
		err  = 'fabric.session frame_rx accepts only frame_received events',
	}
end

local function try_frame_now(self)
	if self._frame_closed then return nil end
	local item, err = queue.try_recv_now(self._frame_rx)
	if item ~= nil then return frame_event_from_item(item) end
	if err ~= 'not_ready' then return frame_event_from_item(nil) end
	return nil
end

local function try_session_event_now(self)
	if self._pending_frame ~= nil then
		local ev = self._pending_frame
		self._pending_frame = nil
		return ev
	end
	local ev = try_frame_now(self)
	if ev ~= nil then return ev end
	if self._pending_timer ~= nil then
		ev = self._pending_timer
		self._pending_timer = nil
		return ev
	end
	return nil
end

local function session_event_op(self)
	return priority_event.next_op {
		label = 'fabric.session',
		select_now = function ()
			return try_session_event_now(self)
		end,
		wait_op = function ()
			local deadline, due = session_next_deadline(self)
			local dt = deadline - fibers.now()
			if dt < 0 then dt = 0 end
			return fibers.named_choice {
				frame = self._frame_rx:recv_op():wrap(frame_event_from_item),
				timer = sleep.sleep_op(dt):wrap(function ()
					return { kind = 'timer', due = due }
				end),
			}
		end,
		store_wake = function (which, ev)
			if which == 'frame' and ev ~= nil then
				self._pending_frame = ev
			elseif which == 'timer' and ev ~= nil then
				self._pending_timer = ev
			end
		end,
	}
end

local function route_downstream(self, lane, frame, at)
	if lane == 'rpc' then
		return publish_to(self._rpc_tx, session_frame_event(self, lane, frame, at), 'session_rpc_frame_admit_failed')
	end
	if lane == 'transfer' then
		return publish_to(self._transfer_tx, session_frame_event(self, lane, frame, at), 'session_transfer_frame_admit_failed')
	end
	return true, nil
end

local function record_bad_frame(self, at)
	at = at or fibers.now()
	local window_s = self._bad_frame_window_s
	local cutoff = at - window_s
	local kept = {}

	for _, seen_at in ipairs(self._bad_frame_times or {}) do
		if type(seen_at) == 'number' and seen_at >= cutoff then
			kept[#kept + 1] = seen_at
		end
	end

	kept[#kept + 1] = at
	self._bad_frame_times = kept

	return #kept
end

local function handle_wire_error(self, ev)
	local at = (type(ev) == 'table' and ev.at) or fibers.now()
	local err = (type(ev) == 'table' and ev.err) or 'wire_error'
	local count = record_bad_frame(self, at)

	update_session(self, function (s)
		s.wire_errors = (s.wire_errors or 0) + 1
		s.bad_frame_count = count
		s.last_wire_error = tostring(err)
	end)

	if count >= self._bad_frame_limit then
		self._bad_frame_times = {}
		reset_to_hello(self, 'bad_frame_limit', at)
	end
end

local function handle_session_frame(self, checked, at)
	local cur = session_snapshot(self)
	if (checked.type == 'hello' or checked.type == 'hello_ack')
		and not protocol.proto_supported(checked.proto)
	then
		reset_to_hello(self, 'unsupported_proto', at)
		return
	end
	if checked.type == 'hello' then
		if not cur.established or cur.phase == 'hello' or not same_peer(cur, checked) then
			establish_from_peer(self, checked, at)
		else
			refresh_peer(self, checked, at)
		end
		send_hello_ack(self)
	elseif checked.type == 'hello_ack' then
		if not cur.established or cur.phase == 'hello' then
			establish_from_peer(self, checked, at)
		elseif same_peer(cur, checked) then
			refresh_peer(self, checked, at)
		end
	elseif checked.type == 'ping' then
		if cur.established and same_peer(cur, checked) then
			refresh_peer(self, checked, at)
			send_pong(self)
		end
	elseif checked.type == 'pong' then
		if cur.established and same_peer(cur, checked) then
			refresh_peer(self, checked, at)
		end
	end
end

local function handle_non_session_frame(self, checked, lane, at)
	local cur = session_snapshot(self)
	if cur.established ~= true or cur.peer_sid == nil then return end
	self._last_peer_at = at or fibers.now()
	local ok, err = route_downstream(self, lane, checked, at)
	if ok ~= true then error(err or 'session_downstream_frame_admit_failed', 0) end
end

local function handle_frame(self, ev)
	local checked, err = protocol.validate(ev.frame)
	if not checked then error('session invalid frame: ' .. tostring(err), 0) end
	local lane = protocol.dispatch_lane(checked)
	if lane == 'session_control' then
		handle_session_frame(self, checked, ev.at or fibers.now())
	else
		handle_non_session_frame(self, checked, lane, ev.at or fibers.now())
	end
end

local function handle_timer(self, ev)
	local now = fibers.now()
	local cur = session_snapshot(self)
	local due = type(ev) == 'table' and ev.due or nil
	if cur.established ~= true then
		if now >= (self._next_hello_at or 0) then send_hello(self) end
		return
	end
	if now >= ((self._last_peer_at or now) + self._liveness_timeout) then
		reset_to_hello(self, 'liveness_timeout', now)
		return
	end
	if (due == nil or due == 'ping') and now >= (self._next_ping_at or math.huge) then
		send_ping(self)
	end
end

function M.run(scope, params)
	if type(scope) ~= 'table' then error('fabric.session.run: scope required', 2) end
	if type(params) ~= 'table' then error('fabric.session.run: params table required', 2) end
	local frame_rx = require_rx(params.frame_rx, 'fabric.session: frame_rx', 2)
	local tx_control = require_tx(params.tx_control, 'fabric.session: tx_control', 2)
	local outbound = params.outbound or params.outbound_gate
	if type(outbound) ~= 'table' or type(outbound.send_frame_now) ~= 'function' then
		error('fabric.session: outbound gate required', 2)
	end
	local rpc_tx = require_tx(params.rpc_tx, 'fabric.session: rpc_tx', 2)
	local transfer_tx = require_tx(params.transfer_tx, 'fabric.session: transfer_tx', 2)
	local link_id = params.link_id or 'link'
	local link_generation = params.link_generation or 1
	local local_node = params.local_node or link_id
	local initial = {
		role = 'session',
		link_id = link_id,
		link_generation = link_generation,
		phase = 'hello',
		local_node = local_node,
		local_sid = params.local_sid or tostring(uuid.new()),
		peer_sid = nil,
		peer_node = nil,
		peer_identity_claim = nil,
		peer_auth_claim = nil,
		auth_state = 'unauthenticated',
		authenticated = false,
		proto = nil,
		session_generation = params.session_generation or 0,
		established = false,
		why = nil,
		wire_errors = 0,
		bad_frame_count = 0,
		last_wire_error = nil,
	}

	local session_model = model_mod.new(initial, {
		copy = protocol.copy_reserved_claim,
		equals = session_equal,
		label = 'fabric.session',
	})

	scope:finally(function (_, status, primary)
		local reason = primary or status or 'session closed'
		session_model:terminate(reason)
		outbound:terminate(reason)
	end)

	local self = setmetatable({
		_link_id = link_id,
		_link_generation = link_generation,
		_frame_rx = frame_rx,
		_tx_control = tx_control,
		_outbound = outbound,
		_rpc_tx = rpc_tx,
		_transfer_tx = transfer_tx,
		_session_model = session_model,
		_local_node = local_node,
		_identity_claim = protocol.normalise_reserved_claim(params.identity_claim),
		_auth_claim = protocol.normalise_reserved_claim(params.auth_claim),
		_auth_state = 'unauthenticated',
		_authenticated = false,
		_state_tx = params.state_tx,
		_component_name = params.component_name or 'session',
		_hello_interval = positive_number(params.hello_interval_s, DEFAULT_HELLO_INTERVAL, 'hello_interval_s'),
		_ping_interval = positive_number(params.ping_interval_s, DEFAULT_PING_INTERVAL, 'ping_interval_s'),
		_liveness_timeout = positive_number(params.liveness_timeout_s, DEFAULT_LIVENESS_TIMEOUT, 'liveness_timeout_s'),
		_bad_frame_limit = positive_integer(params.bad_frame_limit, DEFAULT_BAD_FRAME_LIMIT, 'bad_frame_limit'),
		_bad_frame_window_s = positive_number(params.bad_frame_window_s, DEFAULT_BAD_FRAME_WINDOW_S, 'bad_frame_window_s'),
		_bad_frame_times = {},
		_next_hello_at = fibers.now(),
		_next_ping_at = math.huge,
		_last_peer_at = nil,
		_frame_closed = false,
		_pending_frame = nil,
		_pending_timer = nil,
	}, Session)

	publish_state(self)
	send_hello(self)

	while true do
		local ev = fibers.perform(session_event_op(self))
		if ev.kind == 'frame_closed' then
			self._frame_closed = true
			publish_session_drop(self, session_snapshot(self), 'frame_closed', fibers.now())
			self._outbound:drop('frame_closed')
			return {
				role = 'session',
				link_id = link_id,
				snapshot = session_snapshot(self),
				reason = 'frame_closed',
			}
		elseif ev.kind == 'frame' then
			handle_frame(self, ev)
		elseif ev.kind == 'wire_error' then
			handle_wire_error(self, ev)
		elseif ev.kind == 'invalid_frame_item' then
			error(ev.err or 'fabric.session invalid frame input', 0)
		elseif ev.kind == 'timer' then
			handle_timer(self, ev)
		else
			error('fabric.session unknown event: ' .. tostring(ev.kind), 0)
		end
	end
end

M.peer_session_event = peer_session_event
M.peer_session_dropped_event = peer_session_dropped_event
M.session_frame_event = session_frame_event
M.Session = Session
M.OutboundGate = OutboundGate

return M
