-- services/device/action_manager.lua
--
-- Generation-owned action endpoint binding and scoped action admission.

local scoped_work = require 'devicecode.support.scoped_work'
local queue       = require 'devicecode.support.queue'
local service_events = require 'devicecode.support.service_events'
local publisher   = require 'services.device.publisher'
local projection  = require 'services.device.projection'
local action_worker = require 'services.device.action_worker'
local request_owner = require 'devicecode.support.request_owner'
local cap_deps_mod = require 'devicecode.support.capability_dependencies'
local dependency_mod = require 'services.device.dependencies'
local backpressure = require 'services.device.backpressure'
local safe = require 'coxpcall'

local M = {}

local function new_request_id(state)
	state._action_seq = (state._action_seq or 0) + 1
	return 'act-' .. tostring(state._action_seq)
end

local function action_identity(generation, component_id, action, request_id)
	return {
		kind = 'component_action_done',
		generation = generation,
		component = component_id,
		action = action,
		request_id = request_id,
	}
end



local function completion_reporter(state, identity, label)
	local target = state.events_port or state.done_tx
	if type(target) == 'table'
		and (type(target.emit_required) == 'function' or type(target.send_op) == 'function')
	then
		return service_events.reporter_for(target, identity, { label = label })
	end
	return function (ev)
		return queue.try_admit_required(state.done_tx, ev, label)
	end
end

local function request_payload(req)
	return type(req) == 'table' and req.payload or nil
end

local function fail_public_request(req, reason)
	if type(req) == 'table' and type(req.fail) == 'function' then
		local ok, err = req:fail(reason)
		if ok == true or (ok == nil and err == nil) then
			-- Local bus Request:fail returns true; a few test doubles return nil.
			-- In both cases, the request-level policy has been applied.
			return true, nil
		end
		return nil, err or ('request fail rejected: ' .. tostring(reason))
	end
	return nil, 'request has no fail method: ' .. tostring(reason)
end

local function resolve_action_spec(component, action, req, base_spec)
	local mod = type(component) == 'table' and component.module or nil
	if type(mod) == 'table' and type(mod.action_spec) == 'function' then
		local ok, spec, err = safe.pcall(mod.action_spec, component, action, request_payload(req), base_spec)
		if not ok then return nil, tostring(spec) end
		if spec == nil then return nil, err or 'unknown_action' end
		return spec, nil
	end
	return base_spec, nil
end


local function mapped_action_dependency_key(active, component_id, action)
	local by_component = active and active.action_dependency_keys and active.action_dependency_keys[component_id] or nil
	return by_component and by_component[action] or nil
end

local function remember_action_dependency_key(active, component_id, action, key)
	if key == nil then return end
	active.action_dependency_keys = active.action_dependency_keys or {}
	active.action_dependency_keys[component_id] = active.action_dependency_keys[component_id] or {}
	active.action_dependency_keys[component_id][action] = key
end

local function open_dynamic_dependency_manager(state, active, spec)
	local deps, err = cap_deps_mod.open(state.conn, { spec }, {
		changed_kind = 'device_dependency_changed',
		closed_kind = 'device_dependency_closed',
		queue_len = state.dependency_queue_len or 8,
		full = 'drop_oldest',
	})
	if not deps then return nil, err or 'device_dynamic_action_dependency_open_failed' end
	active.action_deps = deps
	state.action_deps = deps
	return true, nil
end

local function ensure_action_dependency(state, active, component_id, action, action_spec)
	local mapped = mapped_action_dependency_key(active, component_id, action)
	local spec, err = dependency_mod.action_dependency_spec(component_id, action, action_spec)
	if err ~= nil then return nil, err end
	if spec == nil then return mapped, nil end

	local key = spec.key
	remember_action_dependency_key(active, component_id, action, key)

	if active.action_deps == nil then
		local ok, oerr = open_dynamic_dependency_manager(state, active, spec)
		if ok ~= true then return nil, oerr end
	elseif type(active.action_deps.ensure) == 'function' then
		local ok, eerr = active.action_deps:ensure(spec)
		if ok ~= true then return nil, eerr or 'device_dynamic_action_dependency_add_failed' end
	elseif active.action_deps:dependency(key) == nil then
		return nil, 'device_action_dependency_manager_cannot_add:' .. tostring(key)
	end

	if type(state.update_dependency_model) == 'function' then
		state.update_dependency_model(state, active)
	end

	return key, nil
end

local function component_actions(component)
	local out = { ['get-status'] = true }
	for action in pairs(component.actions or {}) do
		out[action] = true
	end
	return out
end

function M.bind_generation(active, params)
	active.action_eps = active.action_eps or {}
	params = params or {}

	for component_id, component in pairs((active.catalogue and active.catalogue.components) or {}) do
		for action in pairs(component_actions(component)) do
			local key = component_id .. ':' .. action
			local ep, err = publisher.bind_now(params.conn, projection.component_cap_topic(component_id, action), {
				queue_len = params.action_queue_len or backpressure.policy.action_endpoints.default_len,
				full = backpressure.policy.action_endpoints.full,
			})
			if not ep then
				-- Binding public endpoints is an immediate generation-owned effect.
				-- If later admission fails, undo what has already been exposed; do
				-- not wait for generation finalisation to make the failed start safe.
				local ok_unbind, unbind_err = M.unbind_generation(active, params.conn)
				if ok_unbind ~= true then
					return nil, tostring(err or 'bind failed') .. '; rollback unbind failed: ' .. tostring(unbind_err)
				end
				return nil, err
			end
			active.action_eps[key] = {
				key = key,
				generation = active.generation,
				component = component_id,
				action = action,
				ep = ep,
				bound = true,
			}
		end
	end

	return true, nil
end

function M.unbind_generation(active, conn)
	local eps = (active and active.action_eps) or {}
	local cleared = {}

	for key, rec in pairs(eps) do
		local ep = rec and rec.ep or nil
		local has_immediate_unbind = (conn ~= nil and type(conn.unbind) == 'function')
			or (type(ep) == 'table' and type(ep.unbind) == 'function')

		if rec and rec.bound == true or has_immediate_unbind then
			local ok, err = publisher.unbind_now(conn, ep)
			if ok ~= true then
				return nil, err or ('action endpoint unbind failed: ' .. tostring(key))
			end
		end

		cleared[#cleared + 1] = key
	end

	-- Only forget records after all durable public endpoint cleanup has succeeded.
	for i = 1, #cleared do
		eps[cleared[i]] = nil
	end
	if active then active.action_eps = eps end
	return true, nil
end

function M.endpoint_sources(active)
	local sources = {}
	for key, rec in pairs((active and active.action_eps) or {}) do
		sources[#sources + 1] = rec
	end
	table.sort(sources, function (a, b) return tostring(a.key) < tostring(b.key) end)
	return sources
end

function M.status_reply(state, req, component_id)
	local rec = state.model:component_snapshot(component_id)
	if not rec then
		if type(req.fail) == 'function' then return req:fail('unknown_component') end
		return nil, 'unknown_component'
	end

	local payload = projection.component_payloads(component_id, rec, state.now()).component
	if type(req.reply) == 'function' then return req:reply(payload) end
	return nil, 'request has no reply method'
end

function M.start_action(state, req, rec)
	local active = state.active
	if not active or rec.generation ~= active.generation then
		return fail_public_request(req, 'stale_generation')
	end

	local component = active.catalogue.components[rec.component]
	if not component then
		return fail_public_request(req, 'unknown_component')
	end

	if rec.action == 'get-status' then
		return M.status_reply(state, req, rec.component)
	end

	local base_action_spec = component.actions and component.actions[rec.action]
	if not base_action_spec then
		return fail_public_request(req, 'unknown_action')
	end

	local action_spec, spec_err = resolve_action_spec(component, rec.action, req, base_action_spec)
	if not action_spec then
		return fail_public_request(req, spec_err or 'unknown_action')
	end

	local dep_key, dep_err = ensure_action_dependency(state, active, rec.component, rec.action, action_spec)
	if dep_err ~= nil then
		return fail_public_request(req, 'dependency_invalid:' .. tostring(dep_err))
	end
	if dep_key ~= nil then
		if not active.action_deps or active.action_deps:available(dep_key) ~= true then
			return fail_public_request(req, 'dependency_unavailable:' .. tostring(dep_key))
		end
	end

	local request_id = new_request_id(state)
	local owner = request_owner.new(req)

	local handle, err = scoped_work.start {
		lifetime_scope = active.action_root or active.scope,
		reaper_scope   = active.action_root or active.scope,
		report_scope   = state.scope,
		identity = action_identity(active.generation, rec.component, rec.action, request_id),

		setup = function (scope)
			-- Request ownership is created before scoped-work admission.  The
			-- action-scope finaliser remains the structural fallback, while the
			-- cancel_owned_now hook resolves the caller-visible request immediately
			-- when the coordinator cancels the scoped action before the worker body
			-- has had a chance to run.  Both paths are idempotent.
			scope:finally(function (_, status, primary)
				action_worker.finalise_owner(owner, status, primary)
			end)

			return {
				request_owner = owner,
				cancel_owned_now = function (reason)
					action_worker.finalise_owner(owner, 'cancelled', reason)
					return true
				end,
			}
		end,

		cancel_op = owner:caller_cancel_op(),

		run = function (scope, setup)
			return action_worker.run(scope, {
				conn = state.conn,
				request = req,
				request_owner = setup.request_owner,
				request_id = request_id,
				component_id = rec.component,
				action = rec.action,
				action_spec = action_spec,
				timeout = state.action_timeout,
				fabric_client = state.fabric_client,
				open_source = state.open_source,
				open_source_op = state.open_source_op,
				terminate_source = state.terminate_source,
			})
		end,
		report = completion_reporter(state, action_identity(active.generation, rec.component, rec.action, request_id), 'device_action_done_report_failed'),
	}

	if not handle then
		owner:fail_once(err or 'action_start_failed')
		return nil, err or 'action_start_failed'
	end

	state.pending_actions[request_id] = {
		generation = active.generation,
		component = rec.component,
		action = rec.action,
		dependency_key = dep_key,
		handle = handle,
	}

	return true, nil
end

return M
