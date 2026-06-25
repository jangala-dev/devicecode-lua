-- services/device/service.lua
--
-- Device service coordinator spine.
-- The coordinator has one suspending control point and non-suspending branches.

local fibers      = require 'fibers'
local mailbox     = require 'fibers.mailbox'
local pulse       = require 'fibers.pulse'
local runtime     = require 'fibers.runtime'
local config_mod  = require 'services.device.config'
local model_mod   = require 'services.device.model'
local topics      = require 'services.device.topics'
local publisher   = require 'services.device.publisher'
local projection  = require 'services.device.projection'
local observer_manager = require 'services.device.observer_manager'
local action_manager   = require 'services.device.action_manager'
local priority_event   = require 'devicecode.support.priority_event'
local queue            = require 'devicecode.support.queue'
local bus_cleanup = require 'devicecode.support.bus_cleanup'
local config_watch = require 'devicecode.support.config_watch'
local service_events = require 'devicecode.support.service_events'
local service_base = require 'devicecode.service_base'
local cap_deps_mod = require 'devicecode.support.capability_dependencies'
local dep_failure  = require 'devicecode.support.dependency_failure'
local backpressure = require 'services.device.backpressure'
local dependency_mod = require 'services.device.dependencies'
local fabric_topics  = require 'services.fabric.topics'
local tablex = require 'shared.table'

local M = {}

local DEFAULT_DONE_QUEUE = backpressure.policy.completions.default_len
local DEFAULT_OBSERVATION_QUEUE = backpressure.policy.observations.default_len

local shallow_copy = tablex.shallow_copy

local function new_service_id()
	return ('device-%d-%d'):format(os.time(), math.random(1, 1000000))
end

-- Device action timeout is owned by the action worker scope.  The Fabric
-- transfer-manager request may legitimately stay open for that whole action, so
-- do not add lua-bus' default one-second call timeout here.  The transfer budget
-- is passed as payload policy, while caller abandonment still aborts this Op.
local FABRIC_SEND_BLOB_CALL_OPTS = { timeout = false }

local function default_fabric_client(conn)
	if type(conn) ~= 'table' or type(conn.call_op) ~= 'function' then return nil end

	return {
		send_blob_op = function (_, params, opts)
			params = params or {}
			opts = opts or {}
			local timeout_s = opts.timeout or params.timeout
			local ev, err = conn:call_op(fabric_topics.transfer_manager_rpc('send-blob'), {
				link_id = params.link_id,
				request_id = params.request_id or params.job_id,
				xfer_id = params.xfer_id,
				target = params.target,
				source_owner = params.source_owner,
				size = params.size,
				digest_alg = params.digest_alg,
				digest = params.digest,
				chunk_size = params.chunk_size,
				meta = params.meta,
				timeout_s = timeout_s,
			}, FABRIC_SEND_BLOB_CALL_OPTS)
			if not ev then return nil, err end
			return ev:wrap(function (reply, call_err)
				if reply == nil then return nil, call_err end
				if type(reply) == 'table' and reply.ok == false then
					return nil, reply.err or reply.error or reply.reason or call_err or 'fabric_transfer_failed'
				end
				return (type(reply) == 'table' and (reply.result or reply.transfer)) or reply, nil
			end)
		end,
	}
end

local function request_publication(state)
	if state.auto_publish == false then return end
	if state.publication_requested then return end
	state.publication_requested = true
	if state.publication_pulse then state.publication_pulse:signal() end
end

local function mark_component_dirty(state, component_id)
	state.dirty.components[component_id] = true
	state.dirty.summary = true
	request_publication(state)
end

local function mark_all_dirty(state)
	local snap = state.model:snapshot()
	for component_id in pairs(snap.components or {}) do
		state.dirty.components[component_id] = true
	end
	state.dirty.summary = true
	request_publication(state)
end

local function unpublish_removed_components(state, snapshot)
	local removed = {}
	for component_id in pairs(state.published_components) do
		if not (snapshot.components and snapshot.components[component_id]) then
			local ok, err = publisher.unpublish_component_now(state.conn, component_id)
			if ok ~= true then
				return nil, err or ('component unpublish failed: ' .. tostring(component_id))
			end
			removed[#removed + 1] = component_id
		end
	end
	for i = 1, #removed do
		state.published_components[removed[i]] = nil
	end
	return true, nil
end

local function flush_publication(state)
	if state.auto_publish == false then
		state.publication_requested = false
		return true, nil
	end
	if not state.conn then
		state.publication_requested = false
		return true, nil
	end

	local snapshot = state.model:snapshot()
	local ok_removed, removed_err = unpublish_removed_components(state, snapshot)
	if ok_removed ~= true then return nil, removed_err end

	local ok, err = publisher.publish_dirty_now(state.conn, snapshot, state.dirty, {
		now = state.now,
		emit_event = state.emit_events ~= false,
	})
	if ok ~= true then return nil, err end

	for component_id in pairs(state.dirty.components) do
		state.published_components[component_id] = true
		state.dirty.components[component_id] = nil
	end
	if state.dirty.summary then
		state.published_summary = true
		state.published_identity = true
		state.published_assembly = true
	end
	state.dirty.summary = false
	state.publication_requested = false
	return true, nil
end

local function cleanup_publication_now(state)
	if not state.conn then return true, nil end
	local cleaned = {}
	for component_id in pairs(state.published_components or {}) do
		local ok, err = publisher.unpublish_component_now(state.conn, component_id)
		if ok ~= true then
			return nil, err or ('component publication cleanup failed: ' .. tostring(component_id))
		end
		cleaned[#cleaned + 1] = component_id
	end

	if state.published_summary then
		local ok, err = bus_cleanup.unretain(state.conn, projection.summary_topic())
		if ok ~= true then return nil, err or 'summary publication cleanup failed' end
	end
	if state.published_identity then
		local ok, err = bus_cleanup.unretain(state.conn, projection.identity_topic())
		if ok ~= true then return nil, err or 'identity publication cleanup failed' end
	end
	if state.published_assembly then
		local ok, err = bus_cleanup.unretain(state.conn, projection.assembly_topic())
		if ok ~= true then return nil, err or 'assembly publication cleanup failed' end
	end

	for i = 1, #cleaned do
		state.published_components[cleaned[i]] = nil
	end
	state.published_summary = false
	state.published_identity = false
	state.published_assembly = false
	return true, nil
end

local function mark_generation_actions_cancelled(state, generation, reason)
	for _, rec in pairs(state.pending_actions or {}) do
		if rec and rec.generation == generation then
			rec.cancelled = true
			rec.cancel_reason = reason or 'generation_cancelled'
		end
	end
end

local function cancel_generation_actions(state, generation, reason)
	-- Cancelling the action handle cancels the action scope. Request resolution is
	-- owned by the action-scope finaliser, not by the coordinator.
	for _, rec in pairs(state.pending_actions or {}) do
		if rec and rec.generation == generation and rec.handle and rec.handle.cancel then
			rec.cancelled = true
			rec.cancel_reason = reason or 'generation_cancelled'
			local ok, err = rec.handle:cancel(reason or 'generation_cancelled')
			if ok ~= true then
				return nil, err or 'action_cancel_failed'
			end
		end
	end
	return true, nil
end

local terminate_action_deps

local function cancel_active_generation(state, reason)
	local active = state.active
	if not active then return true, nil end

	-- Make the generation non-current before cancellation effects can report
	-- completions.  Any later events from this lifetime are stale for model
	-- mutation, but still accounted for in the generation/action outcome ledgers.
	state.active = nil
	active.cancelled = true
	active.cancel_reason = reason or 'generation_replaced'
	state.generation_history = state.generation_history or {}
	state.generation_history[active.generation] = active

	-- Public admission is a coordinator-visible resource, not merely a child
	-- scope finaliser concern. Release generation-owned endpoints immediately so
	-- replacement generations can bind the same public routes without waiting for
	-- the old generation to be joined by its parent.
	local ok_unbind, unbind_err = action_manager.unbind_generation(active, state.conn)
	if ok_unbind ~= true then
		return nil, unbind_err or 'generation_unbind_failed'
	end

	terminate_action_deps(active, reason or 'generation_replaced')
	state.action_deps = nil
	local ok_actions, action_err = cancel_generation_actions(state, active.generation, reason or 'generation_replaced')
	if ok_actions ~= true then
		return nil, action_err or 'generation_action_cancel_failed'
	end

	mark_generation_actions_cancelled(state, active.generation, reason or 'generation_replaced')

	if active.cancel then
		local ok_cancel, cancel_err = active.cancel(reason or 'generation_replaced')
		if ok_cancel ~= true then
			return nil, cancel_err or 'generation_cancel_failed'
		end
	elseif active.scope then
		active.scope:cancel(reason or 'generation_replaced')
	end

	return true, nil
end


function terminate_action_deps(active, reason)
	if active and active.action_deps and type(active.action_deps.terminate) == 'function' then
		active.action_deps:terminate(reason or 'device_action_dependencies_closed')
	end
	if active then active.action_deps = nil end
	return true
end

local function open_action_deps(state, active, catalogue)
	local specs, map, err = dependency_mod.catalogue_dependencies(catalogue)
	if err ~= nil then return nil, err end
	active.action_dependency_keys = map or {}
	if #specs == 0 then return true, nil end
	local deps, derr = cap_deps_mod.open(state.conn, specs, {
		changed_kind = 'device_dependency_changed',
		closed_kind = 'device_dependency_closed',
		queue_len = state.dependency_queue_len or 8,
		full = 'drop_oldest',
	})
	if not deps then return nil, derr or 'device_action_dependencies_open_failed' end
	active.action_deps = deps
	state.action_deps = deps
	return true, nil
end

local function update_dependency_model(state, active)
	if not active then return true, nil end
	local changed, _, err = state.model:update_dependencies(active.generation, active.action_deps and active.action_deps:snapshot() or {})
	if err ~= nil then return nil, err end
	if changed then state.dirty.summary = true; request_publication(state) end
	return true, nil
end

local function create_generation_lifetime(state, generation, catalogue)
	local gen_scope, gen_err = state.scope:child()
	if not gen_scope then
		return nil, gen_err or 'generation_scope_create_failed'
	end

	local observer_root, observer_root_err = gen_scope:child()
	if not observer_root then
		gen_scope:cancel('observer_root_create_failed')
		return nil, observer_root_err or 'observer_root_create_failed'
	end

	local action_root, action_root_err = gen_scope:child()
	if not action_root then
		gen_scope:cancel('action_root_create_failed')
		return nil, action_root_err or 'action_root_create_failed'
	end

	local active = {
		generation = generation,
		scope = gen_scope,
		observer_root = observer_root,
		action_root = action_root,
		catalogue = catalogue,
		observers = {},
		observer_outcomes = {},
		action_eps = {},
	}

	gen_scope:finally(function ()
		local ok, err = action_manager.unbind_generation(active, state.conn)
		if ok ~= true then error(err or 'generation endpoint cleanup failed', 0) end
	end)

	function active.cancel(reason)
		gen_scope:cancel(reason or 'generation_cancelled')
		return true, nil
	end

	return active, nil
end

local function rollback_generation_start(state, active, reason)
	if not active then return true, nil end
	local ok_unbind, unbind_err = action_manager.unbind_generation(active, state.conn)
	terminate_action_deps(active, reason or 'generation_start_failed')
	active.cancel(reason or 'generation_start_failed')
	if ok_unbind ~= true then return nil, unbind_err or 'generation_rollback_unbind_failed' end
	return true, nil
end

local function start_generation(state, catalogue)
	local ok_cancel, cancel_err = cancel_active_generation(state, 'catalogue_changed')
	if ok_cancel ~= true then
		return nil, cancel_err or 'generation_cleanup_failed'
	end

	state.generation_seq = state.generation_seq + 1
	local generation = state.generation_seq

	local active, err = create_generation_lifetime(state, generation, catalogue)
	if not active then
		return nil, err or 'generation_start_failed'
	end

	local ok_deps, dep_err = open_action_deps(state, active, catalogue)
	if ok_deps ~= true then
		local ok_rb, rb_err = rollback_generation_start(state, active, 'action_dependency_open_failed')
		return nil, dep_err or rb_err or 'action_dependency_open_failed'
	end

	if state.enable_actions ~= false then
		local ok_bind, bind_err = action_manager.bind_generation(active, {
			conn = state.conn,
			action_queue_len = state.action_queue_len,
		})
		if ok_bind ~= true then
			local ok_rb, rb_err = rollback_generation_start(state, active, 'action_bind_failed')
			if ok_rb ~= true then return nil, tostring(bind_err or 'action_bind_failed') .. '; rollback failed: ' .. tostring(rb_err) end
			return nil, bind_err or 'action_bind_failed'
		end
	end

	if state.enable_observers ~= false then
		local ok_obs, obs_err = observer_manager.start_all(active, {
			conn = state.conn,
			service_scope = state.scope,
			report_scope = state.scope,
			observation_tx = state.observation_tx,
			done_tx = state.done_tx,
			events_port = state.events_port,
		})
		if ok_obs ~= true then
			local ok_rb, rb_err = rollback_generation_start(state, active, 'observer_start_failed')
			if ok_rb ~= true then return nil, tostring(obs_err or 'observer_start_failed') .. '; rollback failed: ' .. tostring(rb_err) end
			return nil, obs_err or 'observer_start_failed'
		end
	end

	local changed, _, merr = state.model:apply_catalogue(generation, catalogue)
	if merr ~= nil then
		local ok_rb, rb_err = rollback_generation_start(state, active, 'model_catalogue_failed')
		if ok_rb ~= true then return nil, tostring(merr) .. '; rollback failed: ' .. tostring(rb_err) end
		return nil, merr
	end
	if changed then mark_all_dirty(state) end

	state.generation_history = state.generation_history or {}
	state.generation_history[generation] = active
	state.active = active
	return active, nil
end

local function apply_config_payload(state, payload)
	local catalogue, err = config_mod.to_catalogue(payload)
	if not catalogue then
		return nil, err or 'device_catalogue_failed'
	end

	if state.active then
		local cat_mod = require 'services.device.catalogue'
		if cat_mod.equal(state.active.catalogue, catalogue) then
			return true, nil
		end
		if cat_mod.materially_equal(state.active.catalogue, catalogue) then
			local changed_components = cat_mod.public_component_ids_changed(state.active.catalogue, catalogue)
			state.active.catalogue = catalogue
			local changed, _, merr = state.model:update_catalogue_metadata(state.active.generation, catalogue)
			if merr ~= nil then return nil, merr end
			if changed then
				for i = 1, #changed_components do
					mark_component_dirty(state, changed_components[i])
				end
				state.dirty.summary = true
			end
			return true, nil
		end
	end

	local active, serr = start_generation(state, catalogue)
	if not active then return nil, serr end
	return true, nil
end

local function map_config_event(ev, err)
	if ev == nil then
		return { kind = 'config_closed', err = err or 'closed' }
	end

	-- devicecode.support.config_watch normalises retained cfg/<service> records to
	-- config_changed/config_closed events and extracts the public data payload from
	-- { rev = n, data = ... } records.  Device keeps support for the older retained
	-- watch and injected mailbox shapes so existing unit tests and harnesses can
	-- still drive the coordinator directly.
	if type(ev) == 'table' and ev.kind == 'config_closed' then
		return { kind = 'config_closed', err = ev.err or err or 'closed' }
	end
	if type(ev) == 'table' and ev.kind == 'config_changed' then
		if ev.raw ~= nil or ev.record ~= nil or ev.msg ~= nil or ev.rev ~= nil or ev.generation ~= nil then
			return {
				kind = 'config_changed',
				generation = ev.generation,
				rev = ev.rev,
				payload = ev.raw,
				raw = ev.raw,
				record = ev.record,
				msg = ev.msg,
			}
		end
		return ev
	end

	if type(ev) == 'table' and ev.op == 'replay_done' then
		return { kind = 'noop' }
	end
	if type(ev) == 'table' and ev.op == 'retain' then
		return { kind = 'config_changed', payload = ev.payload }
	end
	if type(ev) == 'table' and ev.op == 'unretain' then
		return { kind = 'config_changed', payload = nil }
	end

	return { kind = 'config_changed', payload = ev }
end

local function map_queue_event(kind)
	return function (ev)
		if ev == nil then return { kind = kind .. '_closed' } end
		return ev
	end
end

local function try_op_event_now(ev)
	local item, err = queue.try_now(ev, nil, 'not_ready')
	if item ~= nil then return item end
	if err ~= 'not_ready' then return item end
	return nil
end

local function config_event_op(state)
	if state.config_feed ~= nil then
		return state.config_feed:recv_op():wrap(map_config_event)
	elseif state.config_rx ~= nil then
		return state.config_rx:recv_op():wrap(function (ev)
			return map_config_event(ev)
		end)
	end
	return nil
end

local function observation_event_op(state)
	return state.observation_rx:recv_op():wrap(map_queue_event('observation'))
end

local function done_event_op(state)
	return state.done_rx:recv_op():wrap(map_queue_event('done'))
end

local function publication_event_op(state)
	return fibers.guard(function ()
		if state.publication_requested then
			return fibers.always({ kind = 'publication_flush' })
		end

		return state.publication_pulse:next_op():wrap(function (_, reason)
			if reason ~= nil then return { kind = 'publication_closed', err = reason } end
			return { kind = 'publication_flush' }
		end)
	end)
end

local function action_event_op(rec)
	return rec.ep:recv_op():wrap(function (req, err)
		if req == nil then
			return {
				kind = 'action_endpoint_closed',
				generation = rec.generation,
				component = rec.component,
				action = rec.action,
				err = err or 'closed',
			}
		end
		return {
			kind = 'component_action_request',
			generation = rec.generation,
			component = rec.component,
			action = rec.action,
			request = req,
		}
	end)
end

local function add_source(sources, name, make_op, try_now)
	sources[#sources + 1] = {
		name = name,
		try_now = try_now,
		recv_op = make_op,
	}
end

local function add_config_source(state, sources)
	if not config_event_op(state) then return end
	add_source(sources, 'config', function () return config_event_op(state) end, function ()
		return priority_event.take_pending(state.pending_events, 'config')
			or try_op_event_now(config_event_op(state))
	end)
end

local function add_done_source(state, sources)
	add_source(sources, 'done', function () return done_event_op(state) end, function ()
		return priority_event.take_pending(state.pending_events, 'done')
			or try_op_event_now(done_event_op(state))
	end)
end

local function add_observation_source(state, sources)
	add_source(sources, 'observation', function () return observation_event_op(state) end, function ()
		return priority_event.take_pending(state.pending_events, 'observation')
			or try_op_event_now(observation_event_op(state))
	end)
end

local function add_action_sources(state, sources, action_sources)
	for _, rec in ipairs(action_sources or {}) do
		local rec0 = rec
		local name = 'action:' .. rec0.key
		add_source(sources, name, function () return action_event_op(rec0) end, function ()
			return priority_event.take_pending(state.pending_events, name)
				or try_op_event_now(action_event_op(rec0))
		end)
	end
end

local function add_publication_source(state, sources)
	if state.auto_publish == false then return end
	add_source(sources, 'publication', function () return publication_event_op(state) end, function ()
		return priority_event.take_pending(state.pending_events, 'publication')
			or (state.publication_requested and { kind = 'publication_flush' } or nil)
	end)
end


local function add_dependency_source(state, sources)
	if not state.action_deps then return end
	local src = state.action_deps:event_source({ name = 'dependencies' })
	if src.enabled ~= nil and src.enabled() ~= true then return end
	sources[#sources + 1] = src
end

local function take_pending_from_sources(state, sources)
	for _, source in ipairs(sources) do
		local ev = priority_event.take_pending(state.pending_events, source.name)
		if ev ~= nil then return ev end
	end
	return nil
end

local function prune_unavailable_pending_events(state, action_sources)
	local keep = { done = true, observation = true }
	if config_event_op(state) ~= nil then keep.config = true end
	if state.auto_publish ~= false then keep.publication = true end
	if state.action_deps ~= nil then keep.dependencies = true end

	for _, rec in ipairs(action_sources or {}) do
		keep['action:' .. rec.key] = true
	end

	for name in pairs(state.pending_events or {}) do
		if not keep[name] then
			state.pending_events[name] = nil
		end
	end
end

local function unordered_event_op(state, sources)
	return fibers.guard(function ()
		local pending = take_pending_from_sources(state, sources)
		if pending ~= nil then
			return fibers.always(pending)
		end

		local arms = {}
		for _, source in ipairs(sources) do
			arms[source.name] = source.recv_op()
		end

		return fibers.named_choice(arms):wrap(function (_, ev)
			return ev
		end)
	end)
end

local function next_event_op(state)
	state.pending_events = state.pending_events or {}

	local action_sources = state.active and action_manager.endpoint_sources(state.active) or {}
	prune_unavailable_pending_events(state, action_sources)

	local has_actions = #action_sources > 0
	local has_config = config_event_op(state) ~= nil

	-- Default path: Device reducers are stale-safe and idempotent, so ordinary
	-- readiness selection is sufficient.  Pending events can exist only after a
	-- previous priority wait selected a higher-priority wake; drain them before
	-- blocking so no stored event is lost when the next pass no longer needs
	-- priority.
	if not (has_actions and has_config) then
		local sources = {}
		add_config_source(state, sources)
		add_done_source(state, sources)
		add_observation_source(state, sources)
		add_action_sources(state, sources, action_sources)
		add_dependency_source(state, sources)
		add_publication_source(state, sources)
		return unordered_event_op(state, sources)
	end

	-- Admission-sensitive path: a ready configuration change can invalidate the
	-- current generation and its action endpoints.  Select configuration before
	-- admitting an action request.  Other events remain ordinary/coalesced and are
	-- deliberately after action admission unless a future policy makes their order
	-- safety-critical.
	local sources = {}
	add_config_source(state, sources)
	add_action_sources(state, sources, action_sources)
	add_dependency_source(state, sources)
	add_done_source(state, sources)
	add_observation_source(state, sources)
	add_publication_source(state, sources)

	return priority_event.sources_op {
		label = 'device.next_event.admission_sensitive',
		pending = state.pending_events,
		sources = sources,
	}
end

local function handle_observation(state, ev)
	if not state.active or ev.generation ~= state.active.generation then
		return true, nil
	end
	local changed = state.model:apply_observation(ev.generation, ev)
	if changed then mark_component_dirty(state, ev.component) end
	return true, nil
end

local function generation_for_event(state, generation)
	if state.active and state.active.generation == generation then
		return state.active, true
	end
	local hist = state.generation_history or {}
	return hist[generation], false
end

local function handle_observer_done(state, ev)
	local generation_rec, is_current = generation_for_event(state, ev.generation)

	-- Observer completions are outcomes and should be accounted for even when the
	-- generation has already been replaced.  Stale outcomes do not mutate the
	-- service-owned public model, but they remain attached to their generation
	-- handle for diagnostics and later inspection.
	if generation_rec then
		generation_rec.observers = generation_rec.observers or {}
		generation_rec.observer_outcomes = generation_rec.observer_outcomes or {}
		generation_rec.observers[ev.component] = nil
		generation_rec.observer_outcomes[ev.component] = ev
	end

	if not is_current then
		return true, nil
	end

	if ev.status == 'failed' then
		state.model:apply_source_down(ev.generation, ev.component, ev.primary or 'observer_failed')
		mark_component_dirty(state, ev.component)
	end
	return true, nil
end

local function archive_action_outcome(state, ev, rec, is_current)
	state.action_outcomes = state.action_outcomes or {}
	state.stale_action_outcomes = state.stale_action_outcomes or {}

	local archived = {
		event = ev,
		record = rec,
		current = not not is_current,
	}

	state.action_outcomes[ev.request_id] = archived
	if not is_current then
		state.stale_action_outcomes[ev.request_id] = archived
	end
end

local function handle_action_done(state, ev)
	local generation_rec, is_current = generation_for_event(state, ev.generation)
	local rec = state.pending_actions[ev.request_id]

	-- Action completions are completion records first and model inputs second.
	-- Even stale completions are archived and clear their pending metadata, so
	-- generation replacement does not make child outcomes disappear.
	archive_action_outcome(state, ev, rec, is_current)
	state.pending_actions[ev.request_id] = nil

	if not generation_rec or not is_current then
		return true, nil
	end

	local result = ev.result or {}
	local public_status
	local public_ok
	local public_error

	if rec and rec.dependency_key and state.action_deps and dep_failure.is_no_route(ev.primary, result, ev.report) then
		state.action_deps:classify_call_failure(rec.dependency_key, result, ev.primary)
		update_dependency_model(state, generation_rec)
		public_status = 'dependency_unavailable'
		public_ok = false
		public_error = 'dependency_unavailable:' .. tostring(rec.dependency_key)
	elseif ev.status == 'ok' then
		public_status = result.public_status or (result.ok == true and 'succeeded' or 'remote_failed')
		public_ok = result.ok == true or public_status == 'succeeded'
		public_error = result.error or result.err
	else
		public_status = ev.status
		public_ok = false
		public_error = ev.primary
	end

	local changed = state.model:apply_action_result(ev.generation, {
		component = ev.component,
		action = ev.action,
		request_id = ev.request_id,
		scope_status = ev.status,
		public_status = public_status,
		ok = public_ok,
		err = public_error,
		result = result,
		primary = ev.primary,
	})
	if changed then mark_component_dirty(state, ev.component) end
	return true, nil
end

local function reduce_event(state, ev)
	if ev == nil or ev.kind == 'noop' then
		return true, nil
	end

	if ev.kind == 'config_closed' then
		return nil, 'device config feed closed: ' .. tostring(ev.err or 'closed')
	elseif ev.kind == 'config_changed' then
		return apply_config_payload(state, ev.payload)
	elseif ev.kind == 'component_observation' then
		return handle_observation(state, ev)
	elseif ev.kind == 'observer_done' then
		return handle_observer_done(state, ev)
	elseif ev.kind == 'component_action_request' then
		if not state.active or ev.generation ~= state.active.generation then
			if ev.request and type(ev.request.fail) == 'function' then ev.request:fail('stale_generation') end
			return true, nil
		end
		return action_manager.start_action(state, ev.request, ev)
	elseif ev.kind == 'component_action_done' then
		return handle_action_done(state, ev)
	elseif ev.kind == 'device_dependency_changed' or ev.kind == 'device_dependency_closed' then
		if state.active then return update_dependency_model(state, state.active) end
		return true, nil
	elseif ev.kind == 'publication_flush' then
		return flush_publication(state)
	elseif ev.kind == 'publication_closed' then
		return true, nil
	elseif ev.kind == 'observation_closed' or ev.kind == 'done_closed' then
		return nil, ev.kind
	elseif ev.kind == 'action_endpoint_closed' then
		return true, nil
	end

	return nil, 'unknown device event kind: ' .. tostring(ev.kind)
end

local function coordinator_loop(state)
	while true do
		local ev = fibers.perform(next_event_op(state))
		local ok, err = reduce_event(state, ev)
		if ok ~= true then
			error(err or 'device coordinator failed', 0)
		end

	end
end

local function build_state(scope, params)
	params = params or {}
	local service_id = params.service_id or new_service_id()
	local done_tx, done_rx = mailbox.new(params.done_queue_len or DEFAULT_DONE_QUEUE, { full = backpressure.policy.completions.full })
	local obs_tx, obs_rx = mailbox.new(params.observation_queue_len or DEFAULT_OBSERVATION_QUEUE, { full = backpressure.policy.observations.full })

	local state = {
		scope = scope,
		conn = params.conn,
		service_id = service_id,
		generation_seq = 0,
		active = nil,
		model = params.model or model_mod.new(),
		done_tx = done_tx,
		done_rx = done_rx,
		events_port = service_events.port(done_tx, {
			service_id = service_id,
			source = 'device_service',
			source_id = service_id,
		}, { label = 'device_service_event_report_failed' }),
		observation_tx = obs_tx,
		observation_rx = obs_rx,
		config_feed = params.config_watch or params.config_feed,
		config_rx = params.config_rx,
		owns_config_feed = not not params.owns_config_feed,
		close_config_feed = params.close_config_feed,
		dirty = { components = {}, summary = false },
		publication_pulse = pulse.new(),
		publication_requested = false,
		published_components = {},
		published_summary = false,
		published_identity = false,
		published_assembly = false,
		pending_actions = {},
		action_outcomes = {},
		stale_action_outcomes = {},
		generation_history = {},
		pending_events = {},
		action_timeout = params.action_timeout or 10.0,
		action_queue_len = params.action_queue_len or backpressure.policy.action_endpoints.default_len,
		enable_actions = params.enable_actions,
		enable_observers = params.enable_observers,
		auto_publish = params.auto_publish,
		emit_events = params.emit_events,
		fabric_client = params.fabric_client or default_fabric_client(params.conn),
		open_source = params.open_source,
		open_source_op = params.open_source_op,
		terminate_source = params.terminate_source,
		action_deps = nil,
		dependency_queue_len = params.dependency_queue_len,
		update_dependency_model = update_dependency_model,
	}

	state.now = params.now or function () return fibers.now() end

	scope:finally(function (_, status, primary)
		local reason = primary or status or 'device_closed'

		-- Cancel owned generation work before closing local reporting queues.  This
		-- gives authorised reapers/reporters the best chance to store and submit
		-- completion events while the service-owned queues are still open.
		local ok_cancel, cancel_err = cancel_active_generation(state, reason)
		if ok_cancel ~= true then error(cancel_err or 'generation cleanup failed', 0) end

		done_tx:close(reason)
		obs_tx:close(reason)
		local ok_pub, pub_err = cleanup_publication_now(state)
		if ok_pub ~= true then error(pub_err or 'publication cleanup failed', 0) end
		if state.publication_pulse then state.publication_pulse:close(reason) end
		state.model:terminate(reason)
		if state.owns_config_feed and state.config_feed then
			if type(state.close_config_feed) == 'function' then
				state.close_config_feed(state.config_feed)
			elseif type(state.config_feed.close) == 'function' then
				state.config_feed:close()
			else
				bus_cleanup.unwatch_retained(state.conn, state.config_feed)
			end
		end
	end)

	return state
end

function M.run(scope, params)
	if type(scope) ~= 'table' then error('device.service.run: scope required', 2) end
	local state = build_state(scope, params or {})

	if params and params.initial_config ~= nil then
		local ok, err = apply_config_payload(state, params.initial_config)
		if ok ~= true then error(err or 'initial device config failed', 0) end
		-- Publication is a semantic event. The initial configuration marks the
		-- model dirty; the coordinator selects publication_flush next.
	end

	if params and params.lifecycle and type(params.lifecycle.ready) == 'function' then
		params.lifecycle:ready({ ready = true })
	end

	coordinator_loop(state)
	return { status = 'stopped' }
end

function M.start(conn, opts)
	opts = opts or {}
	if conn == nil then
		error('device.service.start: conn required', 2)
	end

	if not runtime.current_fiber() then
		error('device.service.start must be called inside a fiber', 2)
	end

	local scope = fibers.current_scope()

	local svc = service_base.new(conn, {
		name = opts.name or 'device',
		env = opts.env,
		meta = opts.meta,
		announce = opts.announce,
	})
	svc:starting({ ready = false })

	-- service_base removes retained lifecycle topics from its own finaliser.  This
	-- finaliser is registered after service_base.new(), so it runs first and leaves
	-- a final status visible during shutdown/failure cleanup.
	scope:finally(function (_, status, primary)
		if status == 'failed' then
			svc:failed(primary or 'device_failed')
		else
			svc:stopped({ reason = primary or status or 'device_stopped' })
		end
	end)

	local cfg_watch = opts.config_watch or opts.config_feed
	local owns_cfg_watch = false
	if cfg_watch == nil and opts.watch_config ~= false then
		local watch, err = config_watch.open(conn, 'device', {
			topic = opts.config_topic or topics.config(),
			queue_len = opts.config_queue_len or backpressure.policy.observer_feeds.default_len,
			full = backpressure.policy.observer_feeds.full,
		})
		if not watch then
			svc:failed(err or 'config_watch_failed')
			error(err or 'config_watch_failed', 2)
		end
		cfg_watch = watch
		owns_cfg_watch = true
	end

	svc:running({ ready = false })
	return M.run(scope, {
		conn = conn,
		config_watch = cfg_watch,
		owns_config_feed = owns_cfg_watch,
		initial_config = opts.initial_config,
		done_queue_len = opts.done_queue_len,
		observation_queue_len = opts.observation_queue_len,
		action_queue_len = opts.action_queue_len,
		action_timeout = opts.action_timeout,
		enable_actions = opts.enable_actions,
		enable_observers = opts.enable_observers,
		auto_publish = opts.auto_publish,
		emit_events = opts.emit_events,
		fabric_client = opts.fabric_client,
		open_source = opts.open_source,
		open_source_op = opts.open_source_op,
		terminate_source = opts.terminate_source,
		now = opts.now,
		lifecycle = svc,
	})
end

M.next_event_op = next_event_op
M.build_state = build_state
M.apply_config_payload = apply_config_payload
M.reduce_event = reduce_event
M.start_generation = start_generation
M.cancel_active_generation = cancel_active_generation
M.flush_publication = flush_publication
M.cleanup_publication_now = cleanup_publication_now
M.default_fabric_client = default_fabric_client

return M
