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
			request_owner.new(pending.req):finalise_unresolved(reason)
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
	local artifact, cerr = fibers.perform(ev)
	if artifact == nil then return nil, cerr or 'commit failed' end
	self.artifact = copy(artifact)
	self.closed = true
	self.state = 'committed'
	self._owned:handoff(function () return true end)
	self:_close_scope('ingest_committed')
	return { tag = 'ingest_committed', ingest_id = self.ingest_id, artifact = copy(artifact), bytes = self.bytes }, nil
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

local function create_instance_now(state, req, payload)
	local sink = payload.sink
	if type(sink) ~= 'table' then
		fail(req, 'ingest_sink_required')
		return
	end
	local ingest_id = payload.ingest_id
	if type(ingest_id) ~= 'string' or ingest_id == '' then
		fail(req, 'ingest_id_required')
		return
	end
	if state._instances[ingest_id] ~= nil then
		fail(req, 'ingest_exists')
		return
	end
	local inst, err = M.new_instance(state._scope, {
		ingest_id = ingest_id,
		component = payload.component,
		sink = sink,
	})
	if not inst then
		fail(req, err or 'ingest_create_failed')
		return
	end
	state._instances[ingest_id] = inst
	reply(req, { ok = true, ingest = inst:snapshot() })
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
		run = function (work_scope)
			local owner = request_owner.new(entry.req)
			work_scope:finally(function (_, status, primary)
				owner:finalise_unresolved((status == 'failed' and primary) or (entry.method .. '_cancelled') or primary or status)
			end)
			return entry.run(work_scope, owner)
		end,
		report = function (ev)
			return queue.try_admit_required(ctx.done_tx, ev, 'update_ingest_completion_report_failed')
		end,
	}
	if not handle then
		inst.active_request_id = nil
		fail(entry.req, err or 'ingest_work_start_failed')
		return nil, err
	end
	state._work[entry.request_id] = { handle = handle, ingest_id = inst.ingest_id, category = entry.category }
	return handle, nil
end

start_next_for_instance = function (ctx, state, inst)
	if not inst or inst.active_request_id ~= nil then return true end
	local entry = table.remove(inst.pending, 1)
	if not entry then return true end
	inst.active_request_id = entry.request_id
	local handle, err = start_ingest_work(ctx, state, inst, entry)
	if not handle then
		inst.active_request_id = nil
		return nil, err
	end
	return true, nil
end

local function new_request_id(state, method, ingest_id)
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
				fail(pending.req, 'ingest_closing')
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
		create_instance_now(self, req, payload)
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
	if ev.kind ~= 'ingest_request_done' then return true end
	self._ctx = ctx or self._ctx
	ctx = ctx or self._ctx

	local rec = self._work[ev.request_id]
	self._work[ev.request_id] = nil
	local ingest_id = ev.ingest_id or (rec and rec.ingest_id)
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
			fail(pending.req, 'ingest_closed')
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
