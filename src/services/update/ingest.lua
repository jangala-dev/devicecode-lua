-- services/update/ingest.lua
--
-- Generation-owned ingest coordinator and sink ownership helpers.
--
-- The coordinator serialises operations for each ingest instance. Append work may
-- block inside request scopes, but at most one append/commit/abort operation may
-- touch a sink at a time. Terminal requests close append admission immediately
-- and are then run after any already-admitted operation for that instance.

local fibers        = require 'fibers'
local mailbox       = require 'fibers.mailbox'
local scoped_work   = require 'devicecode.support.scoped_work'
local queue         = require 'devicecode.support.queue'
local request_owner = require 'devicecode.support.request_owner'
local model         = require 'services.update.model'
local lifetime      = require 'services.update.artifacts.lifetime'

local M = {}

local Instance = {}
Instance.__index = Instance

local State = {}
State.__index = State

local function copy(v) return model.deep_copy(v) end


local function artifact_snapshot(artifact)
	if type(artifact) == 'table' and type(artifact.describe) == 'function' then
		local ok, rec = pcall(function () return artifact:describe() end)
		if ok and type(rec) == 'table' then
			rec = copy(rec)
			rec.ref = rec.ref or rec.artifact_ref
			rec.id = rec.id or rec.artifact_ref or rec.ref
			return rec
		end
	end
	local snap = copy(artifact)
	if type(snap) == 'table' then
		snap.ref = snap.ref or snap.artifact_ref
		snap.id = snap.id or snap.artifact_ref or snap.ref
	end
	return snap
end


local function payload_of(req)
	return type(req) == 'table' and type(req.payload) == 'table' and req.payload or {}
end

local function method_of(req)
	local p = payload_of(req)
	local method = (req and req._update_method) or 'ingest_append'
	method = tostring(method):gsub('-', '_')
	if method == 'ingest_create' then method = 'ingest_create' end
	if method == 'ingest_append' then method = 'ingest_append' end
	if method == 'ingest_commit' then method = 'ingest_commit' end
	if method == 'ingest_abort' then method = 'ingest_abort' end
	return method, p
end

local function owner_for(req)
	return request_owner.new(req)
end

local function reply(req, value)
	local ok, err = owner_for(req):reply_once(value)
	if ok ~= true then error(err or 'ingest_reply_failed', 0) end
end

local function fail(req, reason)
	local ok, err = owner_for(req):fail_once(reason)
	if ok ~= true then error(err or tostring(reason or 'ingest_failed'), 0) end
end

local request_abandoned

local function fail_owner(owner, req, reason)
	owner = owner or owner_for(req)
	if owner:done() or request_abandoned(req) then
		owner:abandon_unresolved(reason or 'caller_abandoned')
		return true
	end
	local ok, err = owner:fail_once(reason)
	if ok ~= true then error(err or tostring(reason or 'ingest_failed'), 0) end
	return true
end

request_abandoned = function(req)
	if type(req) == 'table' and type(req.status) == 'function' then
		local status = req:status()
		return status == 'abandoned'
	end
	return false
end

local function entry_abandoned(entry)
	if not entry then return false end
	if entry.owner and entry.owner:done() then return true end
	if request_abandoned(entry.req) then
		if entry.owner then entry.owner:abandon_unresolved('caller_abandoned') end
		return true
	end
	return false
end

local function category_for(method)
	if method == 'ingest_append' then return 'append' end
	if method == 'ingest_commit' then return 'commit' end
	if method == 'ingest_abort' then return 'abort' end
	if method == 'ingest_create' then return 'create' end
	return 'unknown'
end

function M.new_instance(scope, params)
	params = params or {}
	local sink = assert(params.sink, 'ingest sink required')
	assert(type(scope) == 'table' and type(scope.child) == 'function', 'ingest instance requires a parent scope')

	local child, child_err = scope:child()
	if not child then return nil, child_err or 'ingest_instance_scope_create_failed' end

	local owned, err = lifetime.own(child, sink, { reason = 'ingest scope closed' })
	if not owned then
		child:cancel(err or 'ingest_lifetime_own_failed')
		return nil, err
	end

	local self = setmetatable({
		ingest_id = assert(params.ingest_id, 'ingest_id required'),
		component = params.component,
		_scope = child,
		_owned = owned,
		bytes = 0,
		state = 'open',
		closed = false,
		artifact = nil,
		active_request_id = nil,
		pending = {},
		terminal_requested = false,
		_scope_closed = false,
	}, Instance)

	child:finally(function (_, status, primary)
		local reason = primary or ((status ~= 'ok') and status) or 'ingest_instance_closed'
		if self.state == 'open' then self.state = 'closed' end
		self.closed = true
		while #self.pending > 0 do
			local pending = table.remove(self.pending, 1)
			local owner = pending.owner or request_owner.new(pending.req)
			owner:finalise_unresolved(reason)
		end
	end)

	return self
end

function Instance:_close_scope(reason)
	if self._scope_closed then return true, nil end
	self._scope_closed = true
	if self._scope and type(self._scope.close) == 'function' then
		self._scope:close(reason or 'ingest_instance_closed')
	end
	return true, nil
end

function Instance:cancel(reason)
	if self._scope and type(self._scope.cancel) == 'function' then
		self._scope:cancel(reason or 'ingest_instance_cancelled')
	end
	return true, nil
end


function Instance:terminate(reason)
	return self:cancel(reason or 'ingest_instance_terminated')
end

function Instance:append_op(chunk)
	if self.closed or self.state ~= 'open' then return nil, 'ingest closed' end
	local ev, err = self._owned:append_op(chunk)
	if not ev then return nil, err end
	return ev:wrap(function (ok, aerr)
		if ok ~= true then return nil, aerr or 'append failed' end
		self.bytes = self.bytes + #(chunk or '')
		return { tag = 'ingest_appended', ingest_id = self.ingest_id, bytes = self.bytes }, nil
	end)
end

function Instance:begin_commit()
	if self.closed then return nil, 'ingest closed' end
	if self.state ~= 'open' and self.state ~= 'committing' then
		return nil, 'ingest not committable'
	end
	self.state = 'committing'
	return true, nil
end

function Instance:commit_worker(_scope, ...)
	if self.closed then return nil, 'ingest closed' end
	if self.state ~= 'committing' then
		return nil, 'ingest not committable'
	end
	local ev, err = self._owned:commit_op(...)
	if not ev then return nil, err end

	local artifact, commit_err = fibers.perform(ev)
	if artifact == nil then return nil, commit_err or 'commit failed' end
	local snap = artifact_snapshot(artifact)
	self.artifact = snap
	self.closed = true
	self.state = 'committed'
	self._owned:handoff(function () return true end)
	self:_close_scope('ingest_committed')
	return {
		tag = 'ingest_committed',
		ingest_id = self.ingest_id,
		artifact = copy(snap),
		artifact_ref = type(snap) == 'table' and (snap.artifact_ref or snap.ref or snap.id) or snap,
		bytes = self.bytes,
	}, nil
end

function Instance:abort(reason)
	if self.state == 'committed' then return nil, 'ingest already committed' end
	if self.closed and self.state == 'aborted' then return true, nil end
	self.state = 'aborting'
	local ok, err = self._owned:terminate(reason or 'ingest aborted')
	if ok ~= true then return nil, err or 'ingest abort failed' end
	self.closed = true
	self.state = 'aborted'
	self:_close_scope(reason or 'ingest_aborted')
	return true, nil
end

function Instance:snapshot()
	return {
		ingest_id = self.ingest_id,
		component = self.component,
		bytes = self.bytes,
		state = self.state,
		closed = self.closed,
		active_request_id = self.active_request_id,
		queued = #self.pending,
		artifact = copy(self.artifact),
	}
end

function M.append(_scope, instance, chunk)
	local result, err = fibers.perform(assert(instance:append_op(chunk)))
	if not result then error(err or 'ingest_append_failed', 0) end
	return result
end

function M.commit(scope, instance, ...)
	local ok_begin, berr = instance:begin_commit()
	if ok_begin ~= true then error(berr or 'ingest_commit_begin_failed', 0) end
	local result, err = instance:commit_worker(scope, ...)
	if not result then error(err or 'ingest_commit_failed', 0) end
	return result
end

function M.new_state(scope, params)
	params = params or {}
	local request_tx, request_rx = mailbox.new(params.queue_len or 16, { full = 'reject_newest' })
	local terminal_tx, terminal_rx = mailbox.new(params.queue_len or 16, { full = 'reject_newest' })
	scope:finally(function (_, status, primary)
		local reason = primary or status or 'ingest_closed'
		request_tx:close(reason)
		terminal_tx:close(reason)
	end)
	local self = setmetatable({
		_scope = scope,
		_request_tx = request_tx,
		_request_rx = request_rx,
		_terminal_tx = terminal_tx,
		_terminal_rx = terminal_rx,
		_instances = {},
		_work = {},
		_next_request_id = 1,
		_ctx = nil,
	}, State)

	scope:finally(function (_, status, primary)
		self:terminate_instances(primary or status or 'ingest_closed')
	end)

	return self
end

function State:snapshot()
	local out = {}
	for id, inst in pairs(self._instances) do out[id] = inst:snapshot() end
	return out
end

function State:terminate_instances(reason)
	for _, inst in pairs(self._instances or {}) do
		if inst and type(inst.cancel) == 'function' then
			inst:cancel(reason or 'ingest_state_closed')
		end
	end
end

function State:submit(req)
	local method = method_of(req)
	local cat = category_for(method)
	local tx = (cat == 'commit' or cat == 'abort') and self._terminal_tx or self._request_tx
	return queue.try_admit_required(tx, req, 'update_ingest_request_admission_failed')
end

function State:try_terminal_now()
	local req = queue.try_recv_now(self._terminal_rx)
	if req == nil then return nil end
	return { kind = 'ingest_request', priority = 'terminal', request = req }
end

function State:try_request_now()
	local req = queue.try_recv_now(self._request_rx)
	if req == nil then return nil end
	return { kind = 'ingest_request', priority = 'normal', request = req }
end

function State:terminal_op()
	return self._terminal_rx:recv_op():wrap(function (req)
		if req == nil then return { kind = 'ingest_closed' } end
		return { kind = 'ingest_request', priority = 'terminal', request = req }
	end)
end

function State:request_op()
	return self._request_rx:recv_op():wrap(function (req)
		if req == nil then return { kind = 'ingest_closed' } end
		return { kind = 'ingest_request', priority = 'normal', request = req }
	end)
end

local new_request_id

local function create_instance_with_sink_now(state, req, payload, sink, owner)
	if type(sink) ~= 'table' then
		fail_owner(owner, req, 'ingest_sink_required')
		return nil, 'ingest_sink_required'
	end
	local ingest_id = payload.ingest_id
	if type(ingest_id) ~= 'string' or ingest_id == '' then
		fail_owner(owner, req, 'ingest_id_required')
		return nil, 'ingest_id_required'
	end
	if state._instances[ingest_id] ~= nil then
		fail_owner(owner, req, 'ingest_exists')
		return nil, 'ingest_exists'
	end
	local inst, err = M.new_instance(state._scope, {
		ingest_id = ingest_id,
		component = payload.component,
		sink = sink,
	})
	if not inst then
		fail_owner(owner, req, err or 'ingest_create_failed')
		return nil, err or 'ingest_create_failed'
	end
	state._instances[ingest_id] = inst
	owner = owner or owner_for(req)
	local ok, rerr = owner:reply_once({ ok = true, ingest = inst:snapshot() })
	if ok ~= true then error(rerr or 'ingest_create_reply_failed', 0) end
	return inst, nil
end

local function start_create_sink_work(ctx, state, req, payload)
	if type(ctx) ~= 'table' or type(ctx.artifact_store) ~= 'table' or type(ctx.artifact_store.create_sink_op) ~= 'function' then
		fail(req, 'artifact_store_unavailable')
		return nil, 'artifact_store_unavailable'
	end
	local owner = request_owner.new(req)
	local ingest_id = payload.ingest_id
	local request_id = tostring(payload.request_id or new_request_id(state, 'ingest_create', ingest_id))
	local handle, err = scoped_work.start {
		lifetime_scope = ctx.request_root or ctx.scope,
		reaper_scope = ctx.request_root or ctx.scope,
		report_scope = ctx.scope,
		identity = {
			kind = 'ingest_create_done',
			service_id = ctx.service_id,
			generation = ctx.generation,
			method = 'ingest_create',
			request_id = request_id,
			ingest_id = ingest_id,
		},
		setup = function (work_scope)
			work_scope:finally(function (_, status, primary)
				if owner:done() then return end
				-- On success the unresolved request owner is intentionally
				-- carried by the completion event and resolved by the
				-- coordinator after the sink has been admitted to ingest
				-- state. Do not fail it merely because the create-sink
				-- worker scope has ended successfully.
				if status ~= 'ok' then
					owner:finalise_unresolved((status == 'failed' and primary) or primary or 'ingest_create_cancelled')
				end
			end)
			return {
				request_owner = owner,
				cancel_owned_now = function (reason)
					owner:abandon_unresolved(reason or 'caller_abandoned')
					return true
				end,
			}
		end,
		cancel_op = owner:caller_cancel_op(),
		run = function (_, setup)
			local sink, serr = fibers.perform(ctx.artifact_store:create_sink_op({
				component = payload.component,
				meta = payload.metadata or payload.meta or {},
				policy = payload.policy or 'transient_only',
			}))
			if sink == nil then error(serr or 'artifact_sink_create_failed', 0) end
			return {
				tag = 'ingest_sink_created',
				ingest_id = ingest_id,
				payload = copy(payload),
				sink = sink,
				request_owner = setup and setup.request_owner or owner,
			}
		end,
		report = function (ev)
			return queue.try_admit_required(ctx.done_tx, ev, 'update_ingest_create_completion_report_failed')
		end,
	}
	if not handle then
		fail_owner(owner, req, err or 'ingest_create_start_failed')
		return nil, err or 'ingest_create_start_failed'
	end
	state._work[request_id] = { handle = handle, ingest_id = ingest_id, category = 'create', request = req, owner = owner }
	return handle, nil
end

local function create_instance_now(ctx, state, req, payload)
	if type(payload.sink) == 'table' then
		return create_instance_with_sink_now(state, req, payload, payload.sink)
	end
	return start_create_sink_work(ctx, state, req, payload)
end

local start_next_for_instance

local function start_ingest_work(ctx, state, inst, entry)
	local work_parent = inst._scope or ctx.request_root or ctx.scope
	local handle, err = scoped_work.start {
		lifetime_scope = work_parent,
		reaper_scope = work_parent,
		report_scope = ctx.scope,
		identity = {
			kind = 'ingest_request_done',
			service_id = ctx.service_id,
			generation = ctx.generation,
			method = entry.method,
			request_id = entry.request_id,
			ingest_id = inst.ingest_id,
			category = entry.category,
		},
		setup = function (work_scope)
			local owner = entry.owner or request_owner.new(entry.req)
			work_scope:finally(function (_, status, primary)
				owner:finalise_unresolved((status == 'failed' and primary) or primary or (entry.method .. '_cancelled') or status)
			end)
			return {
				request_owner = owner,
				cancel_owned_now = function (reason)
					owner:abandon_unresolved(reason or 'caller_abandoned')
					return true
				end,
			}
		end,
		cancel_op = entry.owner and entry.owner:caller_cancel_op() or nil,
		run = function (work_scope, setup)
			return entry.run(work_scope, setup and setup.request_owner or entry.owner)
		end,
		report = function (ev)
			return queue.try_admit_required(ctx.done_tx, ev, 'update_ingest_completion_report_failed')
		end,
	}
	if not handle then
		inst.active_request_id = nil
		fail_owner(entry.owner, entry.req, err or 'ingest_work_start_failed')
		return nil, err
	end
	state._work[entry.request_id] = { handle = handle, ingest_id = inst.ingest_id, category = entry.category }
	return handle, nil
end

start_next_for_instance = function (ctx, state, inst)
	if not inst or inst.active_request_id ~= nil then return true end
	local entry
	repeat
		entry = table.remove(inst.pending, 1)
		if not entry then return true end
		if entry_abandoned(entry) then entry = nil end
	until entry ~= nil
	inst.active_request_id = entry.request_id
	local handle, err = start_ingest_work(ctx, state, inst, entry)
	if not handle then
		inst.active_request_id = nil
		return nil, err
	end
	return true, nil
end

new_request_id = function(state, method, ingest_id)
	local n = state._next_request_id or 1
	state._next_request_id = n + 1
	return table.concat({ tostring(ingest_id or 'ingest'), tostring(method or 'request'), tostring(n) }, ':')
end

local function enqueue_instance_work(ctx, state, inst, req, method, payload, run)
	local cat = category_for(method)
	if cat == 'append' then
		if inst.state ~= 'open' or inst.terminal_requested then
			fail(req, 'ingest_closing')
			return true
		end
	elseif cat == 'commit' or cat == 'abort' then
		if inst.closed then
			fail(req, 'ingest_closed')
			return true
		end
		if inst.terminal_requested then
			fail(req, 'ingest_terminal_in_progress')
			return true
		end
		inst.terminal_requested = true
		-- Close append admission immediately, but do not mutate the
		-- instance lifecycle state yet. An already-admitted append may still
		-- be active and must be allowed to complete while the sink remains
		-- logically open. The terminal worker changes state when it actually
		-- owns the lane.
		local kept = {}
		for _, pending in ipairs(inst.pending) do
			if pending.category == 'append' then
				fail_owner(pending.owner, pending.req, 'ingest_closing')
			else
				kept[#kept + 1] = pending
			end
		end
		inst.pending = kept
	else
		fail(req, 'unsupported_ingest_method: ' .. tostring(method))
		return true
	end

	local entry = {
		request_id = tostring(payload.request_id or new_request_id(state, method, inst.ingest_id)),
		req = req,
		owner = request_owner.new(req),
		method = method,
		payload = payload,
		category = cat,
		run = run,
	}
	inst.pending[#inst.pending + 1] = entry
	return start_next_for_instance(ctx, state, inst)
end

function State:handle_event(ctx, ev)
	self._ctx = ctx or self._ctx
	ctx = ctx or self._ctx
	if ev.kind == 'ingest_closed' then error('update ingest queue closed', 0) end
	local req = ev.request
	local method, payload = method_of(req)

	if method == 'ingest_create' then
		create_instance_now(ctx, self, req, payload)
		return true
	end

	local ingest_id = payload.ingest_id
	local inst = ingest_id and self._instances[ingest_id] or nil
	if not inst then fail(req, 'ingest_not_found'); return true end

	if method == 'ingest_append' then
		enqueue_instance_work(ctx, self, inst, req, method, payload, function (_, owner)
			if type(payload.chunk) ~= 'string' then error('ingest_append_chunk_required', 0) end
			local result, err = fibers.perform(assert(inst:append_op(payload.chunk)))
			if not result then error(err or 'ingest_append_failed', 0) end
			local ok, rerr = owner:reply_once({ ok = true, append = result })
			if ok ~= true then error(rerr or 'ingest_append_reply_failed', 0) end
			return { tag = 'ingest_appended', ingest_id = ingest_id, result = result }
		end)
		return true
	end

	if method == 'ingest_commit' then
		enqueue_instance_work(ctx, self, inst, req, method, payload, function (_, owner)
			local ok_begin, berr = inst:begin_commit()
			if ok_begin ~= true then error(berr or 'ingest_commit_begin_failed', 0) end
			local result, err = inst:commit_worker(nil)
			if not result then error(err or 'ingest_commit_failed', 0) end
			local ok, rerr = owner:reply_once({ ok = true, commit = result })
			if ok ~= true then error(rerr or 'ingest_commit_reply_failed', 0) end
			return { tag = 'ingest_committed', ingest_id = ingest_id, result = result }
		end)
		return true
	end

	if method == 'ingest_abort' then
		enqueue_instance_work(ctx, self, inst, req, method, payload, function (_, owner)
			local ok_abort, aerr = inst:abort(payload.reason or 'ingest_abort')
			if ok_abort ~= true then error(aerr or 'ingest_abort_failed', 0) end
			local ok, rerr = owner:reply_once({ ok = true, aborted = true })
			if ok ~= true then error(rerr or 'ingest_abort_reply_failed', 0) end
			return { tag = 'ingest_aborted', ingest_id = ingest_id }
		end)
		return true
	end

	fail(req, 'unsupported_ingest_method: ' .. tostring(method))
	return true
end

function State:handle_done(ctx, ev)
	if ev == nil then return true end
	if ev.kind ~= 'ingest_request_done' and ev.kind ~= 'ingest_create_done' then return true end
	self._ctx = ctx or self._ctx
	ctx = ctx or self._ctx

	local rec = self._work[ev.request_id]
	self._work[ev.request_id] = nil
	local ingest_id = ev.ingest_id or (rec and rec.ingest_id)

	if ev.kind == 'ingest_create_done' then
		local result = ev.result or {}
		local owner = result.request_owner or (rec and rec.owner)
		local req = rec and rec.request or nil
		if ev.status ~= 'ok' then
			fail_owner(owner, req, ev.primary or 'ingest_create_failed')
			return true
		end
		create_instance_with_sink_now(self, req, result.payload or {}, result.sink, owner)
		return true
	end

	local inst = ingest_id and self._instances[ingest_id] or nil
	if not inst then return true end

	inst.active_request_id = nil

	if ev.status ~= 'ok' then
		if ev.category == 'commit' or ev.category == 'abort' then
			inst.terminal_requested = false
			if not inst.closed then inst.state = 'open' end
		end
	else
		local result = ev.result or {}
		if result.tag == 'ingest_committed' then
			inst.state = 'committed'
			inst.closed = true
		elseif result.tag == 'ingest_aborted' then
			inst.state = 'aborted'
			inst.closed = true
		end
	end

	if inst.closed then
		-- Requests admitted before a terminal completion but not yet run are failed
		-- now. Later requests are rejected at admission by state checks.
		while #inst.pending > 0 do
			local pending = table.remove(inst.pending, 1)
			fail_owner(pending.owner, pending.req, 'ingest_closed')
		end
		inst:_close_scope('ingest_closed')
		return true
	end

	if ctx then
		start_next_for_instance(ctx, self, inst)
	end
	return true
end

M.State = State
M.Instance = Instance
return M
