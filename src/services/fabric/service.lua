-- services/fabric/service.lua
--
-- Fabric service coordinator spine.
--
-- This module supervises link work as scoped children, records completions as
-- semantic data, updates a model, and applies service-level policy.
--
-- This module owns the configured-link Fabric service runner. It deliberately
-- does not own:
--   * transport opening
--   * bridge routing
--   * transfer attempts
--   * HAL work
--
-- Coordinator rule:
--   one suspending control point; branches do not suspend.

local fibers      = require 'fibers'
local mailbox     = require 'fibers.mailbox'
local scoped_work = require 'devicecode.support.scoped_work'
local queue       = require 'devicecode.support.queue'
local bus_cleanup = require 'devicecode.support.bus_cleanup'
local priority_event = require 'devicecode.support.priority_event'
local config_watch = require 'devicecode.support.config_watch'
local service_events = require 'devicecode.support.service_events'
local model_mod   = require 'services.fabric.model'
local link_mod    = require 'services.fabric.link'
local config_mod  = require 'services.fabric.config'
local topics      = require 'services.fabric.topics'
local transfer_client = require 'services.fabric.transfer_client'
local service_base = require 'devicecode.service_base'
local request_owner = require 'devicecode.support.request_owner'
local dep_slot    = require 'devicecode.support.dependency_slot'
local dep_failure = require 'devicecode.support.dependency_failure'
local fabric_deps = require 'services.fabric.dependencies'
local tablex       = require 'shared.table'

local M = {}

local Service = {}
Service.__index = Service

local DEFAULT_DONE_QUEUE = 64

local shallow_copy = tablex.shallow_copy

local function copy_link_entry(v)
	local out = shallow_copy(v)

	if type(out.result) == 'table' then
		out.result = shallow_copy(out.result)
	end

	if type(out.snapshot) == 'table' then
		out.snapshot = shallow_copy(out.snapshot)
	end

	return out
end

local function copy_links(links)
	local out = {}

	for id, v in pairs(links or {}) do
		out[id] = copy_link_entry(v)
	end

	return out
end

local function copy_snapshot(s)
	local out = shallow_copy(s or {})
	out.links = copy_links(out.links)
	return out
end

local function shallow_value_equal(a, b)
	if a == b then return true end
	if type(a) ~= 'table' or type(b) ~= 'table' then return false end

	for k, v in pairs(a) do
		if b[k] ~= v then return false end
	end

	for k in pairs(b) do
		if a[k] == nil then return false end
	end

	return true
end

local function snapshots_equal(a, b)
	if a == b then return true end
	if type(a) ~= 'table' or type(b) ~= 'table' then return false end

	if a.service_id ~= b.service_id then return false end
	if a.service_generation ~= b.service_generation then return false end
	if a.state ~= b.state then return false end
	if a.reason ~= b.reason then return false end
	if a.total ~= b.total then return false end
	if a.completed ~= b.completed then return false end

	local al = a.links or {}
	local bl = b.links or {}

	for id, av in pairs(al) do
		local bv = bl[id]
		if type(bv) ~= 'table' then return false end
		if av.link_generation ~= bv.link_generation then return false end
		if av.status ~= bv.status then return false end
		if av.primary ~= bv.primary then return false end
		if not shallow_value_equal(av.result, bv.result) then return false end
	end

	for id in pairs(bl) do
		if al[id] == nil then return false end
	end

	return true
end

local function require_params(params)
	if type(params) ~= 'table' then
		error('fabric.service.run: params table required', 3)
	end

	return params
end

local function compiled_from_params(params)
	local compiled = params.compiled_config
	if compiled ~= nil then
		return compiled, nil
	end

	local raw = params.config
	if raw == nil then
		return nil, nil
	end

	local c, err = config_mod.compile(raw)
	if not c then
		return nil, err or 'fabric config compile failed'
	end
	return c, nil
end

local function link_override(params, id, index)
	local overrides = params.link_overrides
	if type(overrides) ~= 'table' then
		return nil
	end
	return overrides[id] or overrides[index]
end

local function apply_runtime_defaults(params, copy)
	for _, key in ipairs({
		'conn',
		'open_transport_op',
		'local_rx', 'transfer_admission_rx',
	}) do
		if copy[key] == nil and params[key] ~= nil then
			copy[key] = params[key]
		end
	end
end

local function normalise_link_specs(params)
	local compiled, cerr = compiled_from_params(params)
	if cerr then
		error('fabric.service: ' .. tostring(cerr), 3)
	end

	local list = (compiled and compiled.links) or params.links

	if type(list) ~= 'table' then
		error('fabric.service: links array required', 3)
	end

	local out = {}
	local seen = {}

	for i, spec in ipairs(list) do
		if type(spec) ~= 'table' then
			error('fabric.service: link entry must be a table', 3)
		end

		local id = spec.link_id
		if type(id) ~= 'string' or id == '' then
			error('fabric.service: link id must be a non-empty string', 3)
		end

		if seen[id] then
			error('fabric.service: duplicate link id: ' .. id, 3)
		end
		seen[id] = true

		local copy = shallow_copy(spec)
		copy.link_id = id
		copy.link_generation = copy.link_generation or i

		local override = link_override(params, id, i)
		if override ~= nil then
			if type(override) ~= 'table' then
				error('fabric.service: link override must be a table: ' .. id, 3)
			end
			for k, v in pairs(override) do
				copy[k] = v
			end
		end

		apply_runtime_defaults(params, copy)
		fabric_deps.assign_transport_dependency(copy, override)

		out[#out + 1] = copy
		out[id] = copy
	end

	if #out == 0 then
		error('fabric.service: at least one link required', 3)
	end

	return out
end

local function initial_snapshot(service_id, service_generation, link_specs)
	local links = {}

	for _, spec in ipairs(link_specs) do
		links[spec.link_id] = {
			link_generation = spec.link_generation,
			status     = 'starting',
		}
	end

	return {
		service_id = service_id,
		service_generation = service_generation,
		state      = 'starting',
		total      = #link_specs,
		completed  = 0,
		links      = links,
	}
end

local function public_snapshot(self)
	return self._model:snapshot()
end

local function set_state(self, state, reason)
	self._model:update(function (s)
		s.state = state
		s.reason = reason
	end)
end

local function advance_completion_state(s)
	if s.state == 'failed' or s.state == 'cancelling' then
		return
	end

	if s.completed >= s.total then
		s.state = 'completed'
	else
		s.state = 'running'
	end
end

local function record_link_done(self, ev)
	local accepted = false
	local reject_reason = nil

	self._model:update(function (s)
		local id = ev.link_id
		local l = s.links[id]

		if not l then
			reject_reason = 'unknown_link'
			return
		end

		if l.link_generation ~= ev.link_generation
			or l.status == 'ok'
			or l.status == 'failed'
			or l.status == 'cancelled'
		then
			reject_reason = 'stale_link_completion'
			return
		end

		l.status = ev.status

		if ev.status == 'ok' then
			if type(ev.result) == 'table' then
				l.result = shallow_copy(ev.result)

				if type(ev.result.snapshot) == 'table' then
					l.snapshot = shallow_copy(ev.result.snapshot)
				end
			else
				l.result = ev.result
			end
		else
			l.primary = ev.primary
		end

		s.completed = (s.completed or 0) + 1
		advance_completion_state(s)
		accepted = true
	end)

	return accepted, reject_reason
end

local function canonical_dependency_route_failure(ev)
	if type(ev) ~= 'table' then return nil end
	local primary = ev.primary
	if not dep_failure.is(primary) or not dep_failure.is_no_route(primary) then return nil end
	local out = shallow_copy(primary)
	out.kind = 'dependency_failure'
	out.err = 'no_route'
	out.dependency_key = dep_failure.key(out)
	out.link_id = out.link_id or ev.link_id
	return out
end
local function default_policy(_, ev)
	if ev.kind ~= 'link_done' then
		return { action = 'continue' }
	end

	if ev.status == 'ok' then
		return { action = 'continue' }
	end

	if ev.status == 'failed' then
		local dependency_failure = canonical_dependency_route_failure(ev)
		if dependency_failure ~= nil then
			return {
				action = 'fail',
				reason = dependency_failure,
			}
		end

		return {
			action = 'fail',
			reason = ('link %s failed: %s'):format(
				tostring(ev.link_id),
				tostring(ev.primary or 'failed')
			),
		}
	end

	if ev.status == 'cancelled' then
		return {
			action = 'fail',
			reason = ('link %s cancelled unexpectedly: %s'):format(
				tostring(ev.link_id),
				tostring(ev.primary or 'cancelled')
			),
		}
	end

	return {
		action = 'fail',
		reason = ('link %s ended with invalid status: %s'):format(
			tostring(ev.link_id),
			tostring(ev.status)
		),
	}
end

local function cancel_all_links(self, reason)
	for _, rec in pairs(self._links) do
		if rec and rec.handle and rec.handle.cancel then
			rec.handle:cancel(reason or 'service_cancelled')
		end
	end
end

local function apply_policy(self, ev)
	local policy = self._policy or default_policy
	local decision = policy(self, ev) or { action = 'continue' }
	local action = decision.action or 'continue'

	if action == 'continue' then
		return
	end

	if action == 'fail' then
		local reason = decision.reason or 'fabric service policy failure'
		set_state(self, 'failed', reason)
		error(reason, 0)
	end

	if action == 'cancel' then
		local reason = decision.reason or 'fabric service policy cancellation'
		set_state(self, 'cancelling', reason)
		cancel_all_links(self, reason)
		return
	end

	if action == 'complete' then
		local snap = public_snapshot(self)
		if (snap.completed or 0) < (snap.total or 0) then
			error('fabric.service: complete policy before all links completed', 0)
		end

		set_state(self, 'completed', decision.reason)
		self._complete = true
		return
	end

	error('fabric.service: unknown policy action: ' .. tostring(action), 0)
end

local function make_link_identity(self, spec)
	return {
		kind       = 'link_done',
		service_id = self._service_id,
		service_generation = self._service_generation,
		link_generation = spec.link_generation,
		link_id    = spec.link_id,
		dependency_key = spec.dependency_key,
	}
end

local function make_service_caps(self)
	return {
		service_id = self._service_id,
		service_generation = self._service_generation,
		conn       = self._conn,
		compiled_config = self._compiled_config,
		routing = self._compiled_config and self._compiled_config.routing or nil,

		snapshot = public_snapshot(self),
	}
end

local function default_link_runner(link_scope, spec)
	return link_mod.run(link_scope, spec)
end

local function public_runner_spec(self, spec)
	if self._link_runner == nil or self._private_link_runtime then
		return spec
	end

	local out = shallow_copy(spec)
	-- transfer_admission_rx is a service-internal channel used to connect the
	-- public transfer-manager capability to the composed link implementation.
	-- Custom link runners receive the documented public link spec only.
	out.transfer_admission_rx = nil
	return out
end

local function start_link(self, spec)
	local runner = self._link_runner or default_link_runner

	local handle, err = scoped_work.start {
		lifetime_scope = self._scope,
		reaper_scope   = self._scope,
		report_scope   = self._scope,

		identity = make_link_identity(self, spec),
		preserve_error_primary = true,

		run = function (link_scope)
			return runner(link_scope, public_runner_spec(self, spec), make_service_caps(self))
		end,

		report = service_events.reporter_for(
			self._done_tx,
			make_link_identity(self, spec),
			{ label = 'fabric_service_link_completion_report_failed' }
		),
	}

	if not handle then
		return nil, err
	end

	self._links[spec.link_id] = {
		link_id    = spec.link_id,
		link_generation = spec.link_generation,
		handle     = handle,
	}

	return handle, nil
end

local function start_all_links(self, link_specs)
	for _, spec in ipairs(link_specs) do
		local h, err = start_link(self, spec)
		if not h then
			set_state(self, 'failed', err or 'link_start_failed')
			error(err or 'link_start_failed', 0)
		end
	end

	set_state(self, 'running')
end

local function next_event_op(self)
	return self._done_rx:recv_op():wrap(function (ev)
		if ev == nil then
			return {
				kind = 'done_queue_closed',
			}
		end

		return ev
	end)
end

local function coordinator_loop(self)
	while not self._complete do
		local ev = fibers.perform(next_event_op(self))

		if ev.kind == 'done_queue_closed' then
			error('fabric service completion queue closed', 0)
		end

		if ev.kind == 'link_done' then
			if ev.service_id ~= self._service_id or ev.service_generation ~= self._service_generation then
				-- Completion for another service instance/generation. Ignore.
			else
				local accepted = record_link_done(self, ev)

				if accepted then
					apply_policy(self, ev)
				end
			end
		else
			error('fabric.service: unknown event kind: ' .. tostring(ev.kind), 0)
		end

		local snap = public_snapshot(self)
		if snap.completed >= snap.total then
			self._complete = true
		end
	end

	return {
		role       = 'fabric_service',
		service_id = self._service_id,
		service_generation = self._service_generation,
		snapshot   = public_snapshot(self),
	}
end

--- Run the Fabric service coordinator inside an existing service scope.
---
--- params:
---   service_id?: string
---   service_generation?: integer
---   links: array of link specs. Each spec is passed to link.run by default.
---   link_runner?: function(link_scope, link_spec, service_caps) -> result_table
---   policy?: function(service, ev) -> { action = ... }
---   done_queue_len?: integer
---
---@param scope Scope
---@param params table
---@return table result
function M.run(scope, params)
	if type(scope) ~= 'table' then
		error('fabric.service.run: scope required', 2)
	end

	params = require_params(params)

	local compiled, cerr = compiled_from_params(params)
	if cerr then
		error('fabric.service: ' .. tostring(cerr), 2)
	end
	local link_specs = normalise_link_specs(params)
	local service_id = params.service_id or (compiled and compiled.service and compiled.service.service_id) or 'fabric'
	local service_generation = params.service_generation or 1

	local initial = initial_snapshot(service_id, service_generation, link_specs)
	local model = model_mod.new(initial, {
		copy = copy_snapshot,
		equals = snapshots_equal,
		label = 'fabric.service',
	})


	scope:finally(function (_, status, primary)
		model:terminate(primary or status or 'fabric service closed')
	end)

	local done_tx, done_rx = mailbox.new(
		params.done_queue_len or math.max(DEFAULT_DONE_QUEUE, #link_specs + 4),
		{ full = 'reject_newest' }
	)

	scope:finally(function ()
		done_tx:close('fabric service closed')
	end)

	local self = setmetatable({
		_scope       = scope,
		_service_id  = service_id,
		_service_generation = service_generation,
		_model       = model,
		_done_tx     = done_tx,
		_done_rx     = done_rx,
		_policy      = params.policy,
		_link_runner = params.link_runner,
		_private_link_runtime = not not params._private_link_runtime,
		_conn        = params.conn,
		_compiled_config = compiled,
		_links       = {},
		_complete    = false,
	}, Service)

	start_all_links(self, link_specs)

	return coordinator_loop(self)
end


--------------------------------------------------------------------------------
-- Long-lived public Fabric service shell
--------------------------------------------------------------------------------

local function extract_config_payload(ev_or_msg)
	if type(ev_or_msg) == 'table' and ev_or_msg.kind == 'cfg' then
		return ev_or_msg.raw
	end
	local payload = ev_or_msg and ev_or_msg.payload or ev_or_msg
	if type(payload) == 'table' and payload.data ~= nil then
		return payload.data
	end
	return payload
end

local retain_transfer_interface
local unretain_transfer_interface
local close_transfer_admissions
local bind_transfer_manager

local function service_status_payload(state, service_state, extra)
	local active = state.active
	local payload = {
		state      = service_state,
		ready      = active ~= nil,
		config_generation = active and active.config_generation or nil,
		last_error   = state.last_error,
		dependencies = state.generation_deps and state.generation_deps:snapshot() or nil,
	}
	for k, v in pairs(extra or {}) do
		payload[k] = v
	end
	return payload
end

local function publish_service_lifecycle(state, service_state, extra)
	local payload = service_status_payload(state, service_state, extra)

	retain_transfer_interface(state, service_state, extra)

	if service_state == 'starting' then
		state.svc:starting(payload)
	elseif service_state == 'running' then
		state.svc:running(payload)
	elseif service_state == 'degraded' then
		state.svc:degraded(payload)
	elseif service_state == 'failed' then
		state.svc:failed(payload.reason or payload.last_error or 'failed', payload)
	elseif service_state == 'stopped' then
		state.svc:stopped(payload)
	else
		state.svc:status(service_state, payload)
	end

	return payload
end


retain_transfer_interface = function(state, service_state, extra)
	if not state.conn then return true, nil end
	local active = state.active
	local links = {}
	for link_id in pairs(state.transfer_admissions or {}) do links[#links + 1] = link_id end
	table.sort(links)

	local ok, err = bus_cleanup.retain(state.conn, topics.transfer_manager_meta(), {
		kind = 'cap.transfer-manager',
		class = 'transfer-manager',
		id = 'main',
		owner = 'fabric',
		methods = { 'send-blob' },
		canonical_state = topics.state_root(),
		links = links,
	})
	if ok ~= true then return nil, err end

	return bus_cleanup.retain(state.conn, topics.transfer_manager_status(), {
		state = service_state == 'running' and active ~= nil and 'available' or 'unavailable',
		available = service_state == 'running' and active ~= nil,
		ready = service_state == 'running' and active ~= nil,
		config_generation = active and active.config_generation or nil,
		reason = extra and (extra.reason or extra.last_error) or state.last_error,
		links = links,
	})
end

unretain_transfer_interface = function(state)
	if not state.conn then return true, nil end
	bus_cleanup.unretain(state.conn, topics.transfer_manager_meta())
	bus_cleanup.unretain(state.conn, topics.transfer_manager_status())
	return true, nil
end

close_transfer_admissions = function(state, reason)
	for _, tx in pairs(state.transfer_admissions or {}) do
		if tx and type(tx.close) == 'function' then tx:close(reason or 'fabric_generation_closed') end
	end
	state.transfer_admissions = {}
end

local function count_transfer_admissions(state)
	local n, only = 0, nil
	for link_id in pairs(state.transfer_admissions or {}) do
		n = n + 1
		only = link_id
	end
	return n, only
end

local function fail_request(req, reason)
	if req and type(req.fail) == 'function' then return req:fail(reason) end
	return nil, reason or 'request_failed'
end

local function reply_request(req, payload)
	if req and type(req.reply) == 'function' then return req:reply(payload) end
	return nil, 'request has no reply method'
end

local function transfer_payload(req)
	return type(req) == 'table' and type(req.payload) == 'table' and req.payload or {}
end

local function transfer_request_params(state, req)
	local p = shallow_copy(transfer_payload(req))
	local link_id = p.link_id
	if type(link_id) ~= 'string' or link_id == '' then
		local n, only = count_transfer_admissions(state)
		if n == 1 then link_id = only end
	end
	if type(link_id) ~= 'string' or link_id == '' then return nil, 'link_id_required' end
	local tx = state.transfer_admissions and state.transfer_admissions[link_id] or nil
	if not tx then return nil, 'link_not_ready' end
	p.link_id = link_id
	p.admission_tx = tx
	state.transfer_seq = (state.transfer_seq or 0) + 1
	local seq = tostring(state.transfer_seq)
	if type(p.request_id) ~= 'string' or p.request_id == '' then
		p.request_id = 'fabric-transfer-request-' .. seq
	end
	if type(p.xfer_id) ~= 'string' or p.xfer_id == '' then
		p.xfer_id = 'fabric-xfer-' .. seq
	end
	return p, nil
end

local function run_public_transfer_request(scope, state, req, owner)
	owner = owner or request_owner.new(req)
	local params, perr = transfer_request_params(state, req)
	if not params then
		owner:fail_once(perr)
		return { ok = false, err = perr or 'transfer_request_invalid' }
	end
	local result, err = transfer_client.run(scope, params)
	if not result then
		local reason = err or 'transfer_failed'
		owner:fail_once(reason)
		return { ok = false, err = reason, link_id = params.link_id }
	end
	local ok, rerr = owner:reply_once({ ok = true, result = result, link_id = params.link_id })
	return { ok = ok == true, err = rerr, result = result, link_id = params.link_id }
end

bind_transfer_manager = function(scope, state, opts)
	if opts and opts.bind_transfer_manager == false then return true, nil end
	local ep, err = bus_cleanup.bind(state.conn, topics.transfer_manager_rpc('send-blob'), {
		queue_len = opts and opts.transfer_manager_queue_len or 16,
	})
	if not ep then return nil, err end
	state.transfer_manager_ep = ep
	scope:finally(function ()
		bus_cleanup.unbind(state.conn, ep)
	end)
	local ok, spawn_err = scope:spawn(function (worker_scope)
		while true do
			local req = fibers.perform(ep:recv_op())
			if req == nil then return { role = 'transfer_manager_endpoint', reason = 'endpoint_closed' } end
			local owner = request_owner.new(req)
			local payload = type(req.payload) == 'table' and req.payload or {}
			local transfer_id = payload.request_id or payload.xfer_id or tostring(state.transfer_seq or 0)
			local handle, serr = scoped_work.start {
				lifetime_scope = worker_scope,
				reaper_scope   = worker_scope,
				report_scope   = worker_scope,
				identity = {
					kind = 'public_transfer_request_done',
					service_id = state.service_id,
					request_id = tostring(transfer_id),
				},
				setup = function (request_scope)
					request_scope:finally(function (_, status, primary)
						owner:finalise_unresolved(primary or status or 'transfer_request_closed')
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
				run = function (request_scope, setup)
					return run_public_transfer_request(request_scope, state, req, setup.request_owner)
				end,
			}
			if not handle then
				owner:fail_once(serr or 'transfer_request_scope_start_failed')
			end
		end
	end)
	if ok ~= true then
		bus_cleanup.unbind(state.conn, ep)
		return nil, spawn_err or 'transfer_manager_endpoint_start_failed'
	end
	return true, nil
end

local function cancel_active_generation(state, reason)
	local active = state.active
	close_transfer_admissions(state, reason or 'generation_cancelled')
	if not active then return end
	state.active = nil
	if active.handle and active.handle.cancel then
		active.handle:cancel(reason or 'generation_cancelled')
	end
end

local function merged_link_override(state, link_id)
	local out = {}
	local src = state.link_overrides and state.link_overrides[link_id] or nil
	if type(src) == 'table' then
		for k, v in pairs(src) do out[k] = v end
	end
	return out
end

local function build_generation_overrides(state, compiled)
	local overrides = {}
	close_transfer_admissions(state, 'generation_replaced')
	state.transfer_admissions = {}

	for _, link in ipairs(compiled.links or {}) do
		local override = merged_link_override(state, link.link_id)
		override.conn = override.conn or state.conn
		if override.transfer_admission_rx == nil then
			local tx, rx = mailbox.new(state.transfer_admission_queue_len or 16, { full = 'reject_newest' })
			state.transfer_admissions[link.link_id] = tx
			override.transfer_admission_rx = rx
		end
		overrides[link.link_id] = override
	end

	return overrides
end


local start_generation

local function terminate_generation_deps(state, reason)
	dep_slot.terminate(state, 'generation_deps', reason or 'fabric_generation_dependency_closed')
	state.generation_dependency_specs = nil
	return true
end

local function open_generation_deps(state, compiled)
	terminate_generation_deps(state, 'fabric_generation_dependency_replaced')
	if state.link_runner ~= nil and not state.private_link_runtime then return true, nil end
	local specs = fabric_deps.transport_dependencies(compiled, state.link_overrides)
	if #specs == 0 then return true, nil end
	local ok, err = dep_slot.replace(state, 'generation_deps', state.conn, specs, {
		replace_reason = 'fabric_generation_dependency_replaced',
		changed_kind = 'fabric_dependency_changed',
		closed_kind = 'fabric_dependency_closed',
		queue_len = state.dependency_queue_len or 8,
		full = 'drop_oldest',
	})
	if ok ~= true then return nil, err or 'fabric_dependency_open_failed' end
	state.generation_dependency_specs = specs
	return true, nil
end
local function all_generation_deps_available(state)
	return dep_slot.all_available(state, 'generation_deps', state.generation_dependency_specs)
end

local function publish_waiting_for_transport(state, reason)
	state.last_error = reason or 'transport_unavailable'
	publish_service_lifecycle(state, 'waiting_for_dependency', {
		ready = false,
		reason = state.last_error,
		dependency = 'transport',
		links = state.pending_compiled and #(state.pending_compiled.links or {}) or nil,
	})
	return true
end

local function maybe_start_pending_generation(state, reason)
	if state.active ~= nil then return true, nil end
	local compiled = state.pending_compiled
	if compiled == nil then return true, nil end
	if not all_generation_deps_available(state) then
		publish_waiting_for_transport(state, reason or state.pending_generation_reason or 'transport_unavailable')
		return true, nil
	end
	state.pending_compiled = nil
	state.pending_generation_reason = nil
	local active, err = start_generation(state, compiled)
	if not active then return nil, err or 'generation_start_failed' end
	state.last_error = nil
	publish_service_lifecycle(state, 'running', {
		ready = true,
		config_generation = active.config_generation,
		links = #(compiled.links or {}),
	})
	return true, nil
end

function start_generation(state, compiled)
	state.config_generation_seq = state.config_generation_seq + 1
	local config_generation = state.config_generation_seq
	local overrides = build_generation_overrides(state, compiled)

	local handle, err = scoped_work.start {
		lifetime_scope = state.scope,
		reaper_scope   = state.scope,
		report_scope   = state.scope,

		identity = {
			kind       = 'generation_done',
			service_id = state.service_id,
			config_generation = config_generation,
		},
		preserve_error_primary = true,

		run = function (gen_scope)
			return M.run(gen_scope, {
				service_id       = state.service_id,
				service_generation = config_generation,
				compiled_config  = compiled,
				conn             = state.conn,
				link_runner      = state.link_runner,
				_private_link_runtime = state.private_link_runtime,
				link_overrides   = overrides,
				policy           = state.config_generation_policy,
				done_queue_len   = state.config_generation_done_queue_len,
			})
		end,

		report = service_events.reporter_for(
			state.events_port or state.done_tx,
			{
				service_id = state.service_id,
				source = 'fabric_generation',
				source_id = tostring(config_generation),
				config_generation = config_generation,
			},
			{ label = 'fabric_generation_done_report_failed' }
		),
	}

	if not handle then
		return nil, err or 'generation_start_failed'
	end

	state.active = {
		config_generation = config_generation,
		compiled   = compiled,
		handle     = handle,
		overrides  = overrides,
	}

	return state.active, nil
end

local function replace_generation(state, compiled, reason)
	cancel_active_generation(state, reason or 'config_changed')
	return start_generation(state, compiled)
end

local function dependency_key_exists(state, key)
	return key ~= nil and state.generation_deps ~= nil and state.generation_deps:dependency(key) ~= nil
end

local function generation_route_failure(state, ev)
	local primary = ev and ev.primary
	if not dep_failure.is(primary) or not dep_failure.is_no_route(primary) then return nil end
	local dep_key = dep_failure.key(primary)
	if not dependency_key_exists(state, dep_key) then return nil end
	return dep_key, primary
end
local function handle_generation_done(state, ev)
	local active = state.active
	if not active or ev.config_generation ~= active.config_generation then
		return
	end

	local completed = active
	close_transfer_admissions(state, ev.status == 'ok' and 'generation_completed' or 'generation_failed')
	state.active = nil

	if ev.status ~= 'ok' and state.generation_deps then
		local dep_key, failure = generation_route_failure(state, ev)
		if dep_key ~= nil then
			state.generation_deps:classify_call_failure(dep_key, failure, nil)
			state.pending_compiled = completed and completed.compiled or state.pending_compiled
			state.pending_generation_reason = 'transport_route_missing'
			publish_waiting_for_transport(state, 'transport_route_missing')
			return
		end
	end

	if ev.status == 'ok' then
		state.last_error = nil
		publish_service_lifecycle(state, 'running', {
			ready = false,
			config_generation = ev.config_generation,
			last_completed_config_generation = ev.config_generation,
		})
		return
	end

	state.last_error = tostring(ev.primary or ev.status or 'generation_failed')
	publish_service_lifecycle(state, 'degraded', {
		reason = 'generation_failed',
		last_error = state.last_error,
		config_generation = ev.config_generation,
	})
end

local function config_event_from_watch(ev)
	if ev == nil then return nil end
	if ev.kind == 'config_closed' then
		return { kind = 'cfg_closed', err = ev.err }
	end
	return {
		kind = 'cfg',
		generation = ev.generation,
		rev = ev.rev,
		raw = ev.raw,
		msg = ev.msg,
	}
end

local function done_event_from_recv(ev, err)
	if ev == nil then
		return { kind = 'done_closed', err = err }
	end
	return ev
end

local function try_shell_done_now(state)
	local ev, err = queue.try_recv_now(state.done_rx)
	if ev ~= nil then
		return done_event_from_recv(ev, nil)
	end
	if err ~= 'not_ready' then
		return done_event_from_recv(nil, err)
	end
	return nil
end

local function try_shell_cfg_now(state)
	local ev = state.cfg_watch:try_recv_now()
	if ev ~= nil then return config_event_from_watch(ev) end
	return nil
end

local function next_shell_event_op(state)
	local sources = {
		{
			name = 'done',
			try_now = function () return try_shell_done_now(state) end,
			recv_op = function ()
				return state.done_rx:recv_op():wrap(done_event_from_recv)
			end,
		},
		{
			name = 'cfg',
			try_now = function () return try_shell_cfg_now(state) end,
			recv_op = function ()
				return state.cfg_watch:recv_op():wrap(config_event_from_watch)
			end,
		},
	}
	local deps_source = dep_slot.event_source(state, 'generation_deps', { name = 'dependencies' })
	if deps_source then sources[#sources + 1] = deps_source end
	return priority_event.sources_op {
		label   = 'fabric.service.shell',
		pending = state.pending_events,
		sources = sources,
	}
end

local function handle_config_event(state, ev_or_msg)
	local raw = extract_config_payload(ev_or_msg)
	local compiled, err = config_mod.compile(raw)
	if not compiled then
		state.last_error = tostring(err or 'invalid_config')
		publish_service_lifecycle(state, 'degraded', {
			reason = 'invalid_config',
			last_error = state.last_error,
		})
		return
	end

	cancel_active_generation(state, 'config_changed')
	local ok_dep, dep_err = open_generation_deps(state, compiled)
	if ok_dep ~= true then
		state.last_error = tostring(dep_err or 'dependency_open_failed')
		publish_service_lifecycle(state, 'degraded', {
			reason = 'dependency_open_failed',
			last_error = state.last_error,
		})
		return
	end
	state.pending_compiled = compiled
	state.pending_generation_reason = 'transport_unavailable'
	local ok_start, gerr = maybe_start_pending_generation(state, 'config_changed')
	if ok_start ~= true then
		state.last_error = tostring(gerr or 'generation_start_failed')
		publish_service_lifecycle(state, 'degraded', {
			reason = 'generation_start_failed',
			last_error = state.last_error,
		})
		return
	end
end

local function handle_shell_event(state, ev)
	if ev.kind == 'cfg' then
		handle_config_event(state, ev)
	elseif ev.kind == 'generation_done' then
		handle_generation_done(state, ev)
	elseif ev.kind == 'fabric_dependency_changed' or ev.kind == 'fabric_dependency_closed' then
		local ok, err = maybe_start_pending_generation(state, ev.kind == 'fabric_dependency_changed' and 'dependency_available' or 'dependency_closed')
		if ok ~= true then error(err or 'fabric dependency handling failed', 0) end
	elseif ev.kind == 'cfg_closed' or ev.kind == 'done_closed' then
		error(tostring(ev.err or ev.kind), 0)
	else
		error('fabric.service.start: unknown event kind: ' .. tostring(ev.kind), 0)
	end
end

--- Start the long-lived public Fabric service shell.
---
--- It watches retained Fabric config and starts, replaces, or cancels configured
--- link generations. It does not expose application-specific entry points.
function M.start(conn, opts)
	opts = opts or {}
	if conn == nil then
		error('fabric.service.start: conn required', 2)
	end

	local scope = fibers.current_scope()
	if not scope then
		error('fabric.service.start must be called inside a fiber', 2)
	end

	local svc = service_base.new(conn, {
		name = opts.name or 'fabric',
		env = opts.env,
		meta = opts.meta,
		announce = opts.announce,
	})

	local cfg_watch, cfg_err = config_watch.open(conn, 'fabric', {
		topic = opts.config_topic or topics.cfg(),
		queue_len = opts.config_queue_len or 4,
		full = 'reject_newest',
	})
	if not cfg_watch then
		error(cfg_err or 'fabric config subscribe failed', 2)
	end

	local done_tx, done_rx = mailbox.new(opts.done_queue_len or 128, { full = 'reject_newest' })

	local state = {
		scope      = scope,
		conn       = conn,
		svc        = svc,
		service_id = opts.service_id or 'fabric',
		cfg_watch  = cfg_watch,
		done_tx    = done_tx,
		done_rx    = done_rx,
		events_port = service_events.port(done_tx, {
			service_id = opts.service_id or 'fabric',
			source = 'fabric_service',
			source_id = opts.service_id or 'fabric',
		}, { label = 'fabric_service_event_report_failed' }),
		active     = nil,
		pending_compiled = nil,
		pending_generation_reason = nil,
		generation_deps = nil,
		generation_dependency_specs = nil,
		config_generation_seq = 0,
		pending_events = {},
		link_runner = opts.link_runner,
		private_link_runtime = not not opts._private_link_runtime,
		link_overrides = opts.link_overrides,
		config_generation_policy = opts.config_generation_policy,
		config_generation_done_queue_len = opts.config_generation_done_queue_len,
		transfer_admissions = {},
		transfer_admission_queue_len = opts.transfer_admission_queue_len,
		dependency_queue_len = opts.dependency_queue_len,
		transfer_seq = 0,
		last_error = nil,
	}

	local transfer_ok, transfer_err = bind_transfer_manager(scope, state, opts)
	if transfer_ok ~= true then
		error(transfer_err or 'fabric transfer-manager bind failed', 2)
	end

	scope:finally(function (_, status, primary)
		local reason = primary or status or 'fabric_stop'
		cancel_active_generation(state, reason)
		terminate_generation_deps(state, reason)
		unretain_transfer_interface(state)
		done_tx:close(reason)
		cfg_watch:close()
	end)

	publish_service_lifecycle(state, 'starting', { ready = false })

	if opts.config ~= nil then
		handle_config_event(state, { payload = opts.config })
	end

	while true do
		local ev = fibers.perform(next_shell_event_op(state))
		handle_shell_event(state, ev)
	end
end


M.default_policy = default_policy
M.make_service_caps = make_service_caps
M.Service = Service
M._test = {
	generation_route_failure = generation_route_failure,
}

return M
