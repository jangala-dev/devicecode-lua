-- services/http/service.lua
-- System HTTP capability service. It owns backend lifetime, handle registry,
-- retained status and bus endpoints. Protocol I/O lives in handles/workers.

local fibers  = require 'fibers'
local mailbox = require 'fibers.mailbox'

local driver_mod = require 'services.http.transport.cqueues_driver'
local backend_mod = require 'services.http.backend'
local model_mod = require 'services.http.model'
local topics = require 'services.http.topics'
local cap_surface = require 'services.http.cap_surface'
local registry_mod = require 'services.http.registry'
local operations = require 'services.http.operations'
local operation_owner = require 'services.http.operation_owner'
local body = require 'services.http.body'
local queue = require 'devicecode.support.queue'
local config_watch = require 'devicecode.support.config_watch'
local config_mod = require 'services.http.config'
local service_events = require 'devicecode.support.service_events'

local M = {}
local perform = fibers.perform

local DEFAULT_MAX_EVENT_LOG = 256
local EVENT_LOG_OMIT = {
	req = true,
	owner = true,
	ctx = true,
	websocket = true,
	result = true,
	report = true,
}

local function normalise_initial_config(opts)
	local raw = opts.config
	if raw == nil then raw = { id = opts.id, policy = opts.policy } end
	local cfg, err = config_mod.normalise(raw)
	if not cfg then return nil, err end
	return cfg, nil
end

local HttpService = {}
HttpService.__index = HttpService

local function copy(t)
	local out = {}
	for k, v in pairs(t or {}) do out[k] = v end
	return out
end

local function copy_event(ev)
	local out = {}
	for k, v in pairs(ev or {}) do
		if not EVENT_LOG_OMIT[k] then out[k] = v end
	end
	return out
end


-- Event ingress is a documented immediate Fibers-side attempt.  All code in
-- this system runs inside Fibers, so use the public Op interface rather than
-- probing primitive internals.
local function try_admit_event_now(tx, ev, label)
	local prefix = label or 'http_event_report_failed'
	if not tx or type(tx.send_op) ~= 'function' then
		return nil, prefix .. ': closed'
	end
	return queue.try_admit_required(tx, ev, prefix)
end

local function fail_req(req, reason)
	if req and type(req.fail) == 'function' then return req:fail(reason) end
	return false, 'request has no fail'
end

local function terminate_handle(h, reason)
	if h and type(h.terminate) == 'function' then return h:terminate(reason) end
	return true
end

local function is_live_handle(rec)
	return rec and rec.state ~= 'reserved' and rec.state ~= 'terminated'
end

local function count_where(t, pred)
	local n = 0
	for _, rec in pairs(t or {}) do if pred(rec) then n = n + 1 end end
	return n
end

local function count_table(t)
	local n = 0
	for _ in pairs(t or {}) do n = n + 1 end
	return n
end

function HttpService:_derive_snapshot()
	local st = self._state
	return {
		state = st.service_state,
		backend = st.backend,
		ready = st.ready,
		active_listeners = count_where(st.listeners, is_live_handle),
		active_contexts = count_table(st.contexts),
		active_exchanges = count_where(st.exchanges, is_live_handle),
		active_websockets = count_where(st.websockets, is_live_handle),
		completed_exchanges = st.completed_exchanges or 0,
		failed_exchanges = st.failed_exchanges or 0,
		rejected_requests = st.rejected_requests or 0,
		tracked_requests = count_table(st.requests),
		tracked_operations = count_table(st.operations),
		tracked_contexts = count_table(st.contexts),
		tracked_listeners = count_table(st.listeners),
		tracked_exchanges = count_table(st.exchanges),
		tracked_websockets = count_table(st.websockets),
		last_error = st.last_error,
		policy_generation = st.policy_generation,
	}
end

function HttpService:_publish_model()
	if self._closed and not self._publishing_after_close then return end
	local snap = self._model:snapshot()
	self._conn:retain(topics.status(self._id), {
		state = snap.state,
		available = snap.ready,
		backend = snap.backend,
		last_error = snap.last_error,
	})
	self._conn:retain(topics.state(self._id, 'stats'), snap)
	self._conn:retain(topics.obs_metric(self._id, 'stats'), snap)
end

function HttpService:_refresh_model()
	local changed = self._model:set_snapshot(self:_derive_snapshot())
	if changed ~= nil then self:_publish_model() end
	return true
end

function HttpService:_log_event(ev)
	if not ev or not ev.kind then return true end
	self._event_seq = self._event_seq + 1
	local saved = copy_event(ev)
	saved.seq = self._event_seq
	local max_events = self._max_event_log
	if max_events ~= false and max_events ~= 0 then
		self._events[#self._events + 1] = saved
		while #self._events > max_events do table.remove(self._events, 1) end
	end
	return true
end

function HttpService:_submit_event(ev, label, opts)
	opts = opts or {}
	if not ev or not ev.kind then return nil, 'invalid_event' end
	local ok, err = try_admit_event_now(self._event_tx, ev, label or 'http_event_report_failed')
	if ok == true then return true end

	self._event_admission_failure = err or 'http_event_report_failed'
	-- Once service shutdown has begun, the observing scope is no longer healthy.
	-- Late stored completions may try to report after the event queue has been
	-- closed; that must not turn orderly shutdown into reporter failure.
	if self._closed and tostring(self._event_admission_failure):match('closed') then
		return true, nil
	end
	if opts.fail_request and ev.owner then ev.owner:fail_once(self._event_admission_failure) end
	if opts.fatal and self._scope then
		local reason = self._event_admission_failure
		if type(self._scope.spawn) == 'function' then
			local spawned = self._scope:spawn(function () error(reason, 0) end)
			if spawned ~= true and type(self._scope.cancel) == 'function' then self._scope:cancel(reason) end
		elseif type(self._scope.cancel) == 'function' then
			self._scope:cancel(reason)
		end
	end
	return nil, self._event_admission_failure
end


-- Registry callbacks may run from the caller's scope, including while that
-- scope is being actively cancelled because a public handle Op lost interest.
-- A normal scope-aware immediate send is then rejected before it can even probe
-- the service event queue.  Preserve the event-driven model by falling back to
-- a tiny reporter fibre in the HTTP service scope; the coordinator still sees a
-- semantic event and remains the only reducer.

function HttpService:_event_port(identity, opts)
	opts = opts or {}
	local attrs = {
		service_id = self._id,
		source = identity and identity.source or 'http_service',
		source_id = identity and identity.source_id or self._id,
		generation = identity and identity.generation or self._generation,
	}
	for k, v in pairs(identity or {}) do attrs[k] = v end

	-- Build event envelopes with the shared helper, but route admission through
	-- _submit_event.  That preserves the HTTP service's shutdown policy: late
	-- component completions after service termination are benign, while admission
	-- failure during a healthy service remains explicit/fatal where requested.
	local base = service_events.port(self._event_tx, attrs, opts)
	local svc = self
	local default_label = opts.label or 'http_service_event_report_failed'
	return {
		emit_required = function (_, ev, label)
			return svc:_submit_event(base:event(ev), label or default_label, { fatal = opts.fatal ~= false })
		end,
		event = function (_, ev, extra)
			return base:event(ev, extra)
		end,
		identity = function () return base:identity() end,
	}
end

function HttpService:_submit_registry_event(ev, label)
	local ok, r1, r2 = pcall(function ()
		return self:_submit_event(ev, label or 'http_registry_event_report_failed', { fatal = true })
	end)
	if ok then return r1, r2 end

	if self._closed or not self._scope or type(self._scope.spawn) ~= 'function' then
		return nil, r1
	end

	local spawned, serr = self._scope:spawn(function ()
		local admitted, aerr = self:_submit_event(ev, label or 'http_registry_event_report_failed', { fatal = true })
		if admitted ~= true then error(aerr or 'http_registry_event_report_failed', 0) end
	end)
	if spawned == true then return true, nil end
	return nil, serr or r1
end

function HttpService:_next_request_identity(verb, req)
	return operation_owner.next_request(self, verb, req)
end

function HttpService:_finish_request(request_id, state, reason)
	local rec = self._state.requests[request_id]
	if rec then
		rec.state = state or rec.state or 'resolved'
		rec.reason = reason
	end
	self._owned_requests[request_id] = nil
	if state == nil or state == 'resolved' or state == 'cancelled' or state == 'failed' then
		self._state.requests[request_id] = nil
	end
	return true
end

function HttpService:_reject_request(request_id, owner, reason)
	if owner then owner:fail_once(reason or 'invalid_args') end
	local rec = self._state.requests[request_id]
	if rec then
		rec.state = 'rejected'
		rec.reason = reason or 'invalid_args'
	end
	self._state.rejected_requests = (self._state.rejected_requests or 0) + 1
	self._state.last_error = reason or 'invalid_args'
	self:_log_event { kind = 'cap_request_rejected', request_id = request_id, reason = reason or 'invalid_args' }
	self._owned_requests[request_id] = nil
	self._state.requests[request_id] = nil
	return true
end

function HttpService:_reserve_handle(kind, opts)
	opts = opts or {}
	return self._registry:reserve(kind, {
		generation = opts.generation or self._generation,
		owner = opts.owner or 'http_service',
	})
end

function HttpService:_register_handle(kind, handle, opts)
	opts = opts or {}
	return self._registry:register(kind, handle, {
		id = opts.id,
		generation = opts.generation or self._generation,
		owner = opts.owner or 'http_service',
	})
end

function HttpService:_remove_handle(id, reason)
	return self._registry:remove(id, reason or 'closed')
end

function HttpService:_terminate_handle(id, reason)
	return self._registry:terminate(id, reason or 'http_service_shutdown')
end

function HttpService:_context_registry_id(ctx)
	if ctx and type(ctx.registry_id) == 'function' then return ctx:registry_id() end
	if ctx and type(ctx.id) == 'function' then return 'ctx' .. tostring(ctx:id()) end
	return nil
end

function HttpService:_register_context(listener_id, ctx)
	local id = self:_context_registry_id(ctx)
	if not id then return nil, 'context_missing_identity' end
	return self._registry:register('context', ctx, {
		id = id,
		generation = self._generation,
		owner = 'listener',
		listener_id = listener_id,
		context_id = (ctx and type(ctx.id) == 'function') and ctx:id() or id,
	})
end

function HttpService:_mark_context_transferred(ctx)
	local id = self:_context_registry_id(ctx)
	if not id then return nil, 'context_missing_identity' end
	return self._registry:mark_transferred(id, self._generation)
end

function HttpService:_remove_context(ctx, reason)
	local id = self:_context_registry_id(ctx)
	if not id then return nil, 'context_missing_identity' end
	return self._registry:remove(id, reason or 'context_terminated', self._generation)
end

function HttpService:_register_server_websocket(ctx, ws)
	if self._closed then
		terminate_handle(ws, 'service_closed')
		return nil, 'service_closed'
	end

	local handle_id, err = self:_register_handle('websocket', ws, {
		generation = self._generation,
		owner = 'caller_after_handoff',
		context_id = ctx and type(ctx.id) == 'function' and ctx:id() or nil,
	})
	if not handle_id then return nil, err or 'websocket_register_failed' end

	if ws and type(ws.add_terminate_hook) == 'function' then
		ws:add_terminate_hook(function (_, reason)
			self:_remove_handle(handle_id, reason or 'websocket_terminated')
		end)
	end

	self._registry:mark_transferred(handle_id, self._generation)
	return true, handle_id
end

function HttpService:_record_handle_event(ev)
	local kind, id = ev.kind, ev.handle_id
	local generation = ev.generation or self._generation
	if not id then return true end

	local function table_for(k)
		if k:match('^listener_') then return self._state.listeners, 'listener' end
		if k:match('^exchange_') then return self._state.exchanges, 'exchange' end
		if k:match('^websocket_') then return self._state.websockets, 'websocket' end
		return nil, nil
	end

	local tbl, hkind = table_for(kind)
	if not tbl then return true end
	local rec = tbl[id]
	if rec and rec.generation ~= generation then return true end

	if kind == hkind .. '_registered' then
		tbl[id] = rec or { handle_id = id, generation = generation, kind = hkind }
		tbl[id].state = 'registered'
		tbl[id].owner = 'http_service'
	elseif kind == hkind .. '_transferred' then
		if not rec then
			tbl[id] = { handle_id = id, generation = generation, kind = hkind, state = 'transferred', owner = 'caller_after_handoff' }
		else
			rec.state = 'transferred'
			rec.owner = 'caller_after_handoff'
		end
	elseif kind == hkind .. '_terminated' then
		tbl[id] = nil
	end
	return true
end

function HttpService:_record_context_event(ev)
	local context_id = ev.context_id
	if context_id == nil then
		self._state.last_error = 'context_event_missing_identity'
		return true
	end
	local id = tostring(context_id)
	local rec = self._state.contexts[id]
	local generation = ev.generation or self._generation
	if rec and rec.generation ~= generation then return true end

	-- Context handles may report from caller/request scopes through an event port.
	-- The coordinator remains the owner of the public model; registry operations
	-- here are immediate accounting/termination backstop updates.
	if ev.ctx ~= nil then
		if ev.kind == 'context_admitted' or ev.kind == 'context_registered' then
			self:_register_context(ev.listener_id, ev.ctx)
		elseif ev.kind == 'context_transferred' then
			self:_mark_context_transferred(ev.ctx)
		elseif ev.kind == 'context_terminated' then
			self:_remove_context(ev.ctx, ev.reason or 'context_terminated')
		end
	end
	if ev.kind == 'context_admitted' or ev.kind == 'context_registered' then
		if not rec then
			self._state.contexts[id] = {
				context_id = context_id,
				listener_id = ev.listener_id,
				generation = generation,
				state = 'admitted',
				owner = 'listener',
			}
		end
	elseif ev.kind == 'context_transferred' then
		if not rec then
			self._state.contexts[id] = {
				context_id = context_id,
				listener_id = ev.listener_id,
				generation = generation,
				state = 'transferred',
				owner = 'caller_after_handoff',
			}
		else
			rec.state = 'transferred'
			rec.owner = 'caller_after_handoff'
		end
	elseif ev.kind == 'context_terminated' then
		self._state.contexts[id] = nil
	end
	return true
end

function HttpService:_handle_cap_request(ev)
	local verb, req, request_id, owner = ev.verb, ev.req, ev.request_id, ev.owner
	if not request_id or not owner then
		return nil, 'cap_request_missing_owner'
	end

	if not self._state.requests[request_id] then
		self._state.requests[request_id] = {
			request_id = request_id,
			generation = ev.generation or self._generation,
			verb = verb,
			owner = owner,
			state = 'received',
		}
	end

	if type(owner.done) == 'function' and owner:done() then
		self:_finish_request(request_id, 'cancelled', 'request_already_resolved')
		return true
	end

	if verb ~= 'status' and self._state.config and self._state.config.enabled == false then
		return self:_reject_request(request_id, owner, 'disabled')
	end

	if verb == 'status' then
		local ok, err = owner:reply_once({ status = self._model:snapshot() })
		if ok ~= true then return nil, err or 'request_reply_failed' end
		self:_finish_request(request_id, 'resolved')
		return true
	end

	local ok, err = operations.validate_cap_request(self, verb, req)
	if not ok then return self:_reject_request(request_id, owner, err or 'invalid_args') end
	return operations.start_operation(self, verb, req, request_id, owner)
end

function HttpService:_handle_operation_done(ev)
	local rec = self._state.operations[ev.operation_id]
	if not rec or rec.generation ~= ev.generation then
		return true
	end
	if rec.state == 'completed' then return true end

	rec.state = 'completed'
	rec.status = ev.status
	rec.report = ev.report
	rec.result = ev.result
	rec.primary = ev.primary
	if rec.operation == 'exchange' then
		if ev.status == 'ok' then
			self._state.completed_exchanges = (self._state.completed_exchanges or 0) + 1
		else
			self._state.failed_exchanges = (self._state.failed_exchanges or 0) + 1
		end
	end
	if ev.status ~= 'ok' then self._state.last_error = ev.primary or ev.status end

	local request_id = rec.request_id
	local owner = request_id ~= nil and self._owned_requests[request_id] or nil
	local reqrec = request_id ~= nil and self._state.requests[request_id] or nil
	if ev.status == 'ok' then
		local reply = ev.result or {}
		local ok, rerr = true, nil
		if owner and not owner:done() then
			ok, rerr = owner:reply_once(reply)
		end
		if ok == true then
			if reply.handle_id then self._registry:mark_transferred(reply.handle_id) end
			if reqrec then reqrec.state = 'resolved' end
		else
			if reply.handle_id then self:_terminate_handle(reply.handle_id, rerr or 'reply_failed') end
			if reqrec then reqrec.state = 'failed'; reqrec.reason = rerr or 'reply_failed' end
			self._state.last_error = rerr or 'reply_failed'
		end
	else
		if owner and not owner:done() then owner:fail_once(ev.primary or ev.status or 'operation_failed') end
		if reqrec then reqrec.state = ev.status or 'failed'; reqrec.reason = ev.primary end
	end
	if request_id ~= nil then
		self._owned_requests[request_id] = nil
		self._state.requests[request_id] = nil
	end
	self._state.operations[ev.operation_id] = nil
	self:_log_event(ev)
	return true
end


function HttpService:_handle_config_changed(ev)
	local cfg, err = config_mod.normalise(ev.raw or {})
	if not cfg then
		self._state.last_error = tostring(err or 'invalid_config')
		self._state.service_state = 'degraded'
		return true
	end

	if cfg.id ~= self._id then
		self._state.last_error = 'config_id_mismatch'
		self._state.service_state = 'degraded'
		return true
	end

	self._state.config = cfg
	self._state.config_generation = ev.generation or (self._state.config_generation + 1)
	self._state.policy_generation = self._state.config_generation
	self._opts.policy = cfg.policy
	if cfg.enabled == false then
		self._state.service_state = 'disabled'
		self._state.ready = false
	else
		self._state.ready = self._state.backend == 'ready'
		if self._state.backend == 'ready' then self._state.service_state = 'ready' end
	end
	self._state.last_error = nil
	self:_log_event({ kind = 'policy_changed', generation = self._state.policy_generation })
	return true
end

function HttpService:_reduce_event(ev)
	local k = ev.kind
	if k == 'backend_ready' then
		self._state.backend = 'ready'
		if self._state.config and self._state.config.enabled == false then
			self._state.service_state = 'disabled'; self._state.ready = false
		else
			self._state.service_state = 'ready'; self._state.ready = true
		end
	elseif k == 'backend_failed' then
		self._state.backend = 'failed'; self._state.service_state = 'failed'; self._state.ready = false; self._state.last_error = ev.reason
		if self._registry then self._registry:terminate_all(ev.reason or 'backend_failed') end
	elseif k == 'backend_terminated' then
		self._state.backend = 'terminated'; self._state.service_state = 'closed'; self._state.ready = false; self._state.last_error = ev.reason
		if self._registry then self._registry:terminate_all(ev.reason or 'backend_terminated') end
	elseif k == 'backend_done' then
		if ev.generation and ev.generation ~= self._generation then return true end
		if ev.status == 'ok' then
			self._state.backend = 'terminated'; self._state.service_state = 'closed'; self._state.ready = false
			self._state.last_error = ev.result and ev.result.reason or 'backend_done'
			if self._registry then self._registry:terminate_all(self._state.last_error or 'backend_done') end
		elseif ev.status == 'cancelled' then
			self._state.backend = 'terminated'; self._state.service_state = 'closed'; self._state.ready = false
			self._state.last_error = ev.primary or 'backend_cancelled'
			if self._registry then self._registry:terminate_all(ev.primary or 'backend_cancelled') end
		else
			self._state.backend = 'failed'; self._state.service_state = 'failed'; self._state.ready = false
			self._state.last_error = ev.primary or ev.status or 'backend_failed'
			if self._registry then self._registry:terminate_all(self._state.last_error or 'backend_failed') end
		end
		return true
	elseif k == 'config_changed' then
		return self:_handle_config_changed(ev)
	elseif k == 'cap_request_received' then
		return self:_handle_cap_request(ev)
	elseif k == 'http_operation_done' then
		return self:_handle_operation_done(ev)
	elseif k == 'listener_registered' or k == 'listener_transferred' or k == 'listener_terminated'
		or k == 'exchange_registered' or k == 'exchange_transferred' or k == 'exchange_terminated'
		or k == 'websocket_registered' or k == 'websocket_transferred' or k == 'websocket_terminated' then
		return self:_record_handle_event(ev)
	elseif k == 'context_admitted' or k == 'context_registered' or k == 'context_transferred' or k == 'context_terminated' then
		return self:_record_context_event(ev)
	elseif k == 'server_websocket_registered' then
		if ev.ctx ~= nil and ev.websocket ~= nil then
			local ok, err = self:_register_server_websocket(ev.ctx, ev.websocket)
			if ok ~= true then self._state.last_error = err or 'server_websocket_register_failed' end
		end
		return true
	elseif k == 'listener_done' then
		if ev.status ~= 'ok' then self._state.last_error = ev.primary or ev.status end
		if ev.handle_id then
			local reason = ev.primary or (ev.result and ev.result.reason) or ev.status or 'listener_done'
			self:_remove_handle(ev.handle_id, reason)
		end
		return true
	elseif k == 'policy_changed' then
		self._state.policy_generation = ev.generation or (self._state.policy_generation + 1)
	end
	return true
end

function HttpService:_handle_event(ev)
	if not ev or not ev.kind then return nil, 'invalid_event' end
	local log_now = ev.kind ~= 'http_operation_done'
	if log_now then self:_log_event(ev) end
	local ok, err = self:_reduce_event(ev)
	self:_refresh_model()
	return ok, err
end

function HttpService:_coordinator_loop()
	while true do
		local ev, err = perform(self._event_rx:recv_op())
		if not ev then return nil, err end
		local ok, herr = self:_handle_event(ev)
		if ok == nil or ok == false then error(herr or 'http_coordinator_event_failed', 0) end
	end
end

function HttpService:_config_loop()
	while not self._closed do
		local ev = perform(self._cfg_watch:recv_op())
		if ev == nil or ev.kind == 'config_closed' then
			return nil, ev and ev.err or 'config_closed'
		end
		local ok, err = self:_submit_event({
			kind = 'config_changed',
			generation = ev.generation,
			rev = ev.rev,
			raw = ev.raw,
		}, 'http_config_event_report_failed', { fatal = true })
		if ok ~= true then error(err or 'http_config_event_report_failed', 0) end
	end
	return true
end

function HttpService:_endpoint_loop(verb, ep)
	while not self._closed do
		local req, err = perform(ep:recv_op())
		if not req then return nil, err end
		local request_id, owner = self:_next_request_identity(verb, req)
		local ok, qerr = self:_submit_event({
			kind = 'cap_request_received', verb = verb, req = req, request_id = request_id, owner = owner, generation = self._generation,
		}, 'http_cap_request_admission_failed')
		if ok ~= true then
			self._owned_requests[request_id] = nil
			owner:fail_once(qerr or 'service_busy')
		end
	end
	return true
end

function HttpService:terminate(reason)
	if self._closed then return true end
	local why = reason or 'closed'
	self._closed = true
	self._publishing_after_close = true
	for _, rec in pairs(self._state.operations or {}) do
		if rec.handle and type(rec.handle.cancel) == 'function' and rec.state ~= 'completed' then rec.handle:cancel(why) end
	end
	for request_id, owner in pairs(self._owned_requests or {}) do
		owner:finalise_unresolved(why)
		local rec = self._state.requests[request_id]
		if rec and rec.state ~= 'resolved' then rec.state = 'cancelled'; rec.reason = why end
		self._owned_requests[request_id] = nil
	end
	if self._registry then self._registry:terminate_all(why) end
	if self._cfg_watch then self._cfg_watch:close(); self._cfg_watch = nil end
	if self._backend then self._backend:terminate(why)
	elseif self._driver then self._driver:terminate(why) end
	if self._event_tx then
		self:_submit_event({ kind = 'backend_terminated', reason = why }, 'http_backend_terminated_report_failed')
		if type(self._event_tx.close) == 'function' then self._event_tx:close(why) end
	end
	if self._endpoints then cap_surface.unbind(self._conn, self._endpoints) end
	cap_surface.unretain_static(self._conn, self._id)
	self._model:terminate(why)
	return true
end

function HttpService:stats()
	local snap = self._model:snapshot()
	snap.handles = self._registry:snapshot()
	return snap
end

function HttpService:events()
	local out = {}
	for i, ev in ipairs(self._events) do out[i] = copy(ev) end
	return out
end

function M.start(conn, opts)
	opts = opts or {}
	local scope = fibers.current_scope()
	if not scope then return nil, 'http service must start inside a scope' end

	local initial_config, config_err = normalise_initial_config(opts)
	if not initial_config then return nil, config_err or 'invalid_http_config' end
	local driver = opts.driver or assert(driver_mod.new(opts.driver_options or { label = 'http-service' }))
	opts.policy = initial_config.policy
	local model = model_mod.new()
	local event_tx, event_rx = mailbox.new(opts.event_queue_len or 64, { full = 'reject_newest' })
	local max_event_log = opts.max_event_log
	if max_event_log == nil then max_event_log = DEFAULT_MAX_EVENT_LOG end
	local self = setmetatable({
		_conn = conn,
		_scope = scope,
		_id = opts.id or 'main',
		_opts = opts,
		_driver = driver,
		_backend = nil,
		_body_registry = opts.body_registry or body.new_registry(opts.body_resolvers or {}),
		_model = model,
		_event_tx = event_tx,
		_event_rx = event_rx,
		_next_operation_id = 0,
		_next_request_id = 0,
		_generation = 1,
		_config = initial_config,
		_closed = false,
		_events = {},
		_event_seq = 0,
		_max_event_log = max_event_log,
		_owned_requests = {},
		_state = {
			service_state = 'starting',
			backend = 'starting',
			ready = false,
			last_error = nil,
			policy_generation = 1,
			config_generation = 1,
			config = initial_config,
			requests = {},
			operations = {},
			completed_exchanges = 0,
			failed_exchanges = 0,
			rejected_requests = 0,
			listeners = {},
			contexts = {},
			exchanges = {},
			websockets = {},
		},
	}, HttpService)
	self._registry = registry_mod.new({
		events_port = {
			emit_required = function (_, ev, label)
				return self:_submit_registry_event(ev, label or 'http_registry_event_report_failed')
			end,
		},
	})

	local cfg_watch, cfg_err = config_watch.open(conn, 'http', {
		topic = opts.config_topic or { 'cfg', 'http' },
		queue_len = opts.config_queue_len or 4,
		full = 'reject_newest',
	})
	if not cfg_watch then self:terminate(cfg_err); return nil, cfg_err or 'http config subscribe failed' end
	self._cfg_watch = cfg_watch

	scope:finally(function (_, status, primary)
		self:terminate(primary or status or 'scope_finalised')
	end)

	cap_surface.retain_static(conn, self._id, { state = 'starting', available = false, backend = 'starting' }, model:snapshot())
	self._endpoints = assert(cap_surface.bind(conn, self._id, {}, { endpoint_opts = { queue_len = opts.endpoint_queue_len or 10 } }))

	local ok_coord, cerr = scope:spawn(function () return self:_coordinator_loop() end)
	if not ok_coord then self:terminate(cerr); return nil, cerr end

	local ok_cfg, cfg_loop_err = scope:spawn(function () return self:_config_loop() end)
	if not ok_cfg then self:terminate(cfg_loop_err); return nil, cfg_loop_err end

	local backend, derr = backend_mod.start({
		lifetime_scope = scope,
		driver = driver,
		generation = self._generation,
		identity = {
			kind = 'backend_done',
			component = 'backend',
			component_id = 'http_backend',
			generation = self._generation,
		},
		events_port = self:_event_port({
			source = 'http_backend',
			source_id = 'http_backend',
			component = 'backend',
			component_id = 'http_backend',
		}, { label = 'http_backend_event_report_failed' }),
	})
	if not backend then
		self:_submit_event({ kind = 'backend_failed', reason = derr }, 'http_backend_failed_report_failed')
		self:terminate(derr or 'backend_failed')
		return nil, derr
	end
	self._backend = backend

	for verb, ep in pairs(self._endpoints) do
		local spawned, serr = scope:spawn(function () return self:_endpoint_loop(verb, ep) end)
		if not spawned then self:terminate(serr); return nil, serr end
	end

	return self
end

M.HttpService = HttpService
return M
