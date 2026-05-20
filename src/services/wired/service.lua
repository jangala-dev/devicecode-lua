-- services/wired/service.lua
--
-- Minimal house-style Wired service.
-- The coordinator owns no OS-facing work.  It composes configured appliance
-- surfaces from net segment state and public wired-provider capability state.

local fibers = require 'fibers'
local runtime = require 'fibers.runtime'
local config_mod = require 'services.wired.config'
local model_mod = require 'services.wired.model'
local topics = require 'services.wired.topics'
local publisher = require 'services.wired.publisher'
local bus_cleanup = require 'devicecode.support.bus_cleanup'
local config_watch = require 'devicecode.support.config_watch'
local cap_deps_mod = require 'devicecode.support.capability_dependencies'
local dependency_mod = require 'services.wired.dependencies'
local tablex = require 'shared.table'

local M = {}

local function now() return runtime.now() end
local function copy(v) return tablex.deep_copy(v) end
local function is_plain_table(v) return type(v) == 'table' and getmetatable(v) == nil end

local function new_service_id()
	return ('wired-%d-%d'):format(os.time(), math.random(1, 1000000))
end

local function topic_eq(t, a)
	if type(t) ~= 'table' or #t ~= #a then return false end
	for i = 1, #a do if t[i] ~= a[i] then return false end end
	return true
end

local function update_provider_from_event(snap, ev)
	local topic = ev and ev.topic or {}
	if topic[1] ~= 'cap' or topic[2] ~= 'wired-provider' then return false end
	local id = topic[3]
	if type(id) ~= 'string' or id == '' then return false end
	local rec = snap.providers[id] or { id = id, capability_id = id, status = {}, surfaces = {}, topology = {}, meta = {} }
	if ev.op == 'unretain' then
		if topic[4] == 'status' then rec.status = { state = 'unavailable', available = false, reason = 'unretained' }
		elseif topic[4] == 'state' and topic[5] == 'surfaces' then rec.surfaces = {}
		elseif topic[4] == 'state' and topic[5] == 'topology' then rec.topology = {}
		elseif topic[4] == 'meta' then rec.meta = {} end
	else
		local payload = copy(ev.payload or {})
		if topic[4] == 'status' then rec.status = payload
		elseif topic[4] == 'state' and topic[5] == 'status' then rec.runtime_status = payload
		elseif topic[4] == 'state' and topic[5] == 'surfaces' then rec.surfaces = payload.surfaces or payload
		elseif topic[4] == 'state' and topic[5] == 'topology' then rec.topology = payload
		elseif topic[4] == 'meta' then rec.meta = payload end
	end
	rec.updated_at = now()
	snap.providers[id] = rec
	return true
end

local function net_segments_from_payload(payload)
	if type(payload) ~= 'table' then return {}, {} end
	return copy(payload.segments or payload), copy(payload.vlan_policy or {})
end

local function provider_surface(provider, provider_surface_id)
	local surfaces = provider and provider.surfaces or nil
	if type(surfaces) ~= 'table' then return nil end
	return surfaces[provider_surface_id]
end

local function provider_available(snap, provider_id, provider)
	local dep = snap and snap.dependencies and snap.dependencies[dependency_mod.provider_dependency_key(provider_id)] or nil
	if dep ~= nil and dep.available ~= true then
		return false, dep.reason or dep.status or 'provider_unavailable'
	end
	if provider == nil then return false, 'provider_missing' end
	local st = provider.status or {}
	if st.available == false or st.state == 'removed' or st.state == 'unavailable' or st.state == 'not_configured' then
		return false, st.reason or st.state or 'provider_unavailable'
	end
	return true, nil
end

local function append_violation(violations, kind, fields)
	local v = { kind = kind, severity = 'error' }
	for k, val in pairs(fields or {}) do v[k] = val end
	violations[#violations + 1] = v
end

local function collect_attachment_segments(attachment)
	local out = {}
	if not attachment then return out end
	if attachment.segment then out[#out + 1] = attachment.segment end
	for i = 1, #(attachment.segments or {}) do out[#out + 1] = attachment.segments[i] end
	for i = 1, #(attachment.required_segments or {}) do out[#out + 1] = attachment.required_segments[i] end
	if type(attachment.user_segments) == 'table' then
		for i = 1, #attachment.user_segments do out[#out + 1] = attachment.user_segments[i] end
	end
	if attachment.native_segment then out[#out + 1] = attachment.native_segment end
	return out
end

local function normalise_vlan_id(v)
	local n = tonumber(v)
	if n == nil or n % 1 ~= 0 or n < 1 or n > 4094 then return nil end
	return n
end

local function add_vlan_value(set, list, v)
	if v == nil then return end
	local tv = type(v)
	if tv == 'number' or tv == 'string' then
		local id = normalise_vlan_id(v)
		if id then
			set[id] = true
			list[#list + 1] = id
		end
	elseif tv == 'table' then
		if v.id ~= nil then add_vlan_value(set, list, v.id) end
		if v.vlan ~= nil then add_vlan_value(set, list, v.vlan) end
		if v.vid ~= nil then add_vlan_value(set, list, v.vid) end
		for k, val in pairs(v) do
			if type(k) == 'number' then
				add_vlan_value(set, list, val)
			elseif val == true then
				add_vlan_value(set, list, k)
			end
		end
	end
end

local function observed_vlan_set(attachment)
	local set, list = {}, {}
	attachment = attachment or {}
	add_vlan_value(set, list, attachment.vlan)
	add_vlan_value(set, list, attachment.vlans)
	add_vlan_value(set, list, attachment.tagged)
	add_vlan_value(set, list, attachment.untagged)
	table.sort(list)
	return set, list
end

local function segment_vlan_id(segment)
	if type(segment) ~= 'table' then return nil end
	local vlan = segment.vlan
	if type(vlan) == 'table' then
		return normalise_vlan_id(vlan.id or vlan.vlan or vlan.vid)
	end
	return normalise_vlan_id(vlan)
end

local function is_realised_user_segment(seg)
	if type(seg) ~= 'table' then return false end
	if seg.enabled == false then return false end
	if seg.protected == true then return false end
	if seg.kind == 'system' then return false end
	return segment_vlan_id(seg) ~= nil
end

local function append_expected_vlan(violations, expected, observed, observed_list, surface_id, seg_id, seg, role)
	if not seg then
		if role == 'required' then
			append_violation(violations, 'missing_required_segment_definition', {
				severity = 'critical',
				surface_id = surface_id,
				segment = seg_id,
			})
		end
		return
	end
	local vlan_id = segment_vlan_id(seg)
	if vlan_id == nil then
		append_violation(violations, role == 'user' and 'missing_user_segment_vlan' or 'missing_required_segment_vlan', {
			severity = role == 'required' and 'critical' or 'error',
			surface_id = surface_id,
			segment = seg_id,
		})
		return
	end
	expected[#expected + 1] = { segment = seg_id, vlan = vlan_id, role = role }
	if not observed[vlan_id] then
		append_violation(violations, role == 'user' and 'missing_user_segment_carriage' or 'missing_required_segment_carriage', {
			severity = role == 'required' and 'critical' or 'error',
			surface_id = surface_id,
			segment = seg_id,
			vlan = vlan_id,
			observed_vlans = copy(observed_list),
		})
	end
end

local function expand_user_segments(attachment, segments)
	local us = attachment and attachment.user_segments or nil
	local out = {}
	if us == 'all-realised-user-segments' then
		local keys = tablex.sorted_keys(segments or {})
		for i = 1, #keys do
			local sid = keys[i]
			if is_realised_user_segment(segments[sid]) then out[#out + 1] = sid end
		end
	elseif type(us) == 'table' then
		for i = 1, #us do out[#out + 1] = us[i] end
	end
	return out
end

local function validate_provider_capabilities(violations, surface_id, desired, p_surface)
	if p_surface == nil then return end
	local caps = p_surface.capabilities
	if not is_plain_table(caps) then return end
	local mode = desired.attachment and desired.attachment.mode or 'none'
	if mode == 'access' and caps.access ~= true then
		append_violation(violations, 'provider_surface_does_not_support_access', {
			surface_id = surface_id,
			provider_surface_id = desired.provider and desired.provider.provider_surface_id or nil,
		})
	elseif mode == 'trunk' and caps.trunk ~= true then
		append_violation(violations, 'provider_surface_does_not_support_trunk', {
			surface_id = surface_id,
			provider_surface_id = desired.provider and desired.provider.provider_surface_id or nil,
		})
	end
	local dcaps = desired.capabilities
	if is_plain_table(dcaps) and dcaps.poe == true and caps.poe ~= true then
		append_violation(violations, 'provider_surface_does_not_support_poe', {
			surface_id = surface_id,
			provider_surface_id = desired.provider and desired.provider.provider_surface_id or nil,
		})
	end
end

local function validate_protected_trunk_carriage(violations, surface_id, desired, p_ok, p_surface, observed_attachment, segments)
	if desired.enabled == false or desired.attachment.mode ~= 'trunk' then return {} end
	if not p_ok or p_surface == nil then return {} end

	local expected = {}
	if observed_attachment.mode ~= nil and observed_attachment.mode ~= 'trunk' then
		append_violation(violations, 'protected_trunk_observed_not_trunk', {
			severity = 'critical',
			surface_id = surface_id,
			observed_mode = observed_attachment.mode,
		})
	end

	local observed, observed_list = observed_vlan_set(observed_attachment)
	for _, seg in ipairs(desired.attachment.required_segments or {}) do
		append_expected_vlan(violations, expected, observed, observed_list, surface_id, seg, segments[seg], 'required')
	end
	for _, seg in ipairs(expand_user_segments(desired.attachment, segments)) do
		append_expected_vlan(violations, expected, observed, observed_list, surface_id, seg, segments[seg], 'user')
	end
	return expected, observed_list
end

local function rebuild_derived(snap)
	local surfaces = {}
	local violations = {}
	local topology = { protected_trunks = {}, access = {}, trunks = {} }
	local segments = snap.net and snap.net.segments or {}

	for id, desired in pairs((snap.config_intent and snap.config_intent.surfaces) or {}) do
		local provider_id = desired.provider.capability_id
		local provider = snap.providers[provider_id]
		local p_ok, p_reason = provider_available(snap, provider_id, provider)
		local p_surface = provider_surface(provider, desired.provider.provider_surface_id)
		local link = copy((p_surface and p_surface.link) or {})
		local observed_attachment = copy((p_surface and p_surface.attachment) or {})
		local availability = { state = 'available', reason = nil }
		if desired.enabled == false then
			availability = { state = 'disabled', reason = 'disabled_by_config' }
		elseif not p_ok then
			availability = { state = 'unavailable', reason = p_reason }
		elseif p_surface == nil then
			availability = { state = 'degraded', reason = 'provider_surface_missing' }
		end

		for _, segment_id in ipairs(collect_attachment_segments(desired.attachment)) do
			if not segments[segment_id] then
				append_violation(violations, 'unknown_segment', { surface_id = id, segment = segment_id })
			end
		end

		validate_provider_capabilities(violations, id, desired, p_surface)

		if desired.protected then
			if desired.enabled == false then append_violation(violations, 'protected_surface_disabled', { surface_id = id, severity = 'critical' }) end
			if desired.attachment.mode ~= 'trunk' then append_violation(violations, 'protected_surface_not_trunk', { surface_id = id, severity = 'critical' }) end
			if provider == nil then
				append_violation(violations, 'protected_provider_missing', { surface_id = id, provider_id = provider_id, severity = 'critical' })
			elseif not p_ok then
				append_violation(violations, 'protected_provider_unavailable', { surface_id = id, provider_id = provider_id, reason = p_reason, severity = 'critical' })
			elseif p_surface == nil then
				append_violation(violations, 'protected_provider_surface_missing', {
					surface_id = id,
					provider_id = provider_id,
					provider_surface_id = desired.provider.provider_surface_id,
					severity = 'critical',
				})
			end
			local expected_vlans, observed_vlans = validate_protected_trunk_carriage(violations, id, desired, p_ok, p_surface, observed_attachment, segments)
			topology.protected_trunks[id] = {
				surface_id = id,
				required_segments = copy(desired.attachment.required_segments),
				required_vlans = expected_vlans,
				observed_vlans = observed_vlans,
				provider = copy(desired.provider),
			}
		end

		if desired.attachment.mode == 'access' then topology.access[id] = { surface_id = id, segment = desired.attachment.segment }
		elseif desired.attachment.mode == 'trunk' then topology.trunks[id] = { surface_id = id, segments = copy(desired.attachment.segments), required_segments = copy(desired.attachment.required_segments), user_segments = copy(desired.attachment.user_segments), expanded_user_segments = expand_user_segments(desired.attachment, segments) }
		end

		surfaces[id] = {
			surface_id = id,
			name = desired.name,
			label = desired.label,
			description = desired.description,
			kind = desired.kind,
			role = desired.role,
			enabled = desired.enabled,
			protected = desired.protected,
			provider = copy(desired.provider),
			capabilities = copy(desired.capabilities),
			attachment = copy(desired.attachment),
			observed = { attachment = observed_attachment },
			link = link,
			availability = availability,
			updated_at = now(),
		}
	end

	snap.surfaces = surfaces
	snap.topology = topology
	snap.violations = violations
	snap.ready = true
	snap.state = (#violations == 0) and 'running' or 'degraded'
	snap.reason = (#violations == 0) and nil or 'validation_violations'
	return snap
end

local function publish(state)
	local snap = state.model:snapshot()
	local ok, err = publisher.publish_all_now(state.conn, snap, state.published)
	if ok ~= true then return nil, err end
	state.model:update(function (s)
		s.stats.publications = (s.stats.publications or 0) + 1
		return s
	end)
	return true, nil
end


local function terminate_provider_deps(state, reason)
	if state.provider_deps and type(state.provider_deps.terminate) == 'function' then
		state.provider_deps:terminate(reason or 'wired_provider_dependencies_closed')
	end
	state.provider_deps = nil
	return true
end

local function open_provider_deps(state, intent)
	terminate_provider_deps(state, 'wired_provider_dependencies_replaced')
	local specs = dependency_mod.provider_dependencies(intent)
	if #specs == 0 then return true, nil end
	local deps, err = cap_deps_mod.open(state.conn, specs, {
		changed_kind = 'wired_dependency_changed',
		closed_kind = 'wired_dependency_closed',
		queue_len = state.dependency_queue_len or 8,
		full = 'drop_oldest',
	})
	if not deps then return nil, err or 'wired_provider_dependencies_open_failed' end
	state.provider_deps = deps
	return true, nil
end

local function dependency_snapshot(state)
	return state.provider_deps and state.provider_deps:snapshot() or {}
end

local function apply_config(state, ev)
	local intent, err = config_mod.normalise(ev and ev.raw or nil, { rev = ev and ev.rev, generation = ev and ev.generation })
	if not intent then return nil, err end
	local ok_deps, dep_err = open_provider_deps(state, intent)
	if ok_deps ~= true then return nil, dep_err or 'wired_provider_dependencies_open_failed' end
	local _changed, _version, uerr = state.model:update(function (snap)
		snap.generation = (ev and ev.generation) or (snap.generation + 1)
		snap.config = { rev = intent.rev, schema = intent.schema, config_schema = intent.config_schema, version = intent.version }
		snap.config_intent = intent
		snap.dependencies = dependency_snapshot(state)
		snap.stats.config_updates = (snap.stats.config_updates or 0) + 1
		return rebuild_derived(snap)
	end)
	if uerr ~= nil then return nil, uerr end
	return publish(state)
end

local function apply_net_segments(state, ev)
	if ev and ev.op == 'replay_done' then return true, nil end
	local segments, vlan_policy = net_segments_from_payload(ev and ev.payload)
	local _changed, _version, uerr = state.model:update(function (snap)
		snap.net.segments = segments
		snap.net.vlan_policy = vlan_policy
		snap.net.segments_rev = ev and (ev.payload and ev.payload.rev or ev.payload and ev.payload.generation)
		snap.stats.segment_updates = (snap.stats.segment_updates or 0) + 1
		return rebuild_derived(snap)
	end)
	if uerr ~= nil then return nil, uerr end
	return publish(state)
end

local function apply_provider_event(state, ev)
	if ev and ev.op == 'replay_done' then return true, nil end
	local _changed, _version, uerr = state.model:update(function (snap)
		if update_provider_from_event(snap, ev) then snap.stats.provider_updates = (snap.stats.provider_updates or 0) + 1 end
		return rebuild_derived(snap)
	end)
	if uerr ~= nil then return nil, uerr end
	return publish(state)
end


local function apply_dependency_event(state, _ev)
	local _changed, _version, uerr = state.model:update(function (snap)
		snap.dependencies = dependency_snapshot(state)
		return rebuild_derived(snap)
	end)
	if uerr ~= nil then return nil, uerr end
	return publish(state)
end

function M.build_state(scope, opts)
	opts = opts or {}
	local conn = assert(opts.conn, 'wired service requires conn')
	local cfg, cfg_err = config_watch.open(conn, 'wired', { changed_kind = 'wired_config_changed', closed_kind = 'wired_config_closed' })
	if not cfg then return nil, cfg_err end
	local net_watch, nerr = bus_cleanup.watch_retained(conn, topics.net_segments(), { replay = true, queue_len = 8, full = 'reject_newest' })
	if not net_watch then cfg:close(); return nil, nerr end
	local provider_watch, perr = bus_cleanup.watch_retained(conn, topics.wired_provider_cap_pattern(), { replay = true, queue_len = 32, full = 'reject_newest' })
	if not provider_watch then cfg:close(); bus_cleanup.unwatch_retained(conn, net_watch); return nil, perr end
	local state = {
		scope = scope,
		conn = conn,
		model = opts.model or model_mod.new(opts.service_id or new_service_id()),
		config_watch = cfg,
		net_watch = net_watch,
		provider_watch = provider_watch,
		provider_deps = nil,
		dependency_queue_len = opts.dependency_queue_len,
		published = publisher.new_state(),
	}
	scope:finally(function ()
		cfg:close()
		bus_cleanup.unwatch_retained(conn, net_watch)
		bus_cleanup.unwatch_retained(conn, provider_watch)
		terminate_provider_deps(state, 'wired_service_stopped')
		publisher.cleanup_now(conn, state.published)
		state.model:terminate('wired_service_stopped')
	end)
	return state, nil
end

function M.next_event_op(state)
	local arms = {
		config = state.config_watch:recv_op(),
		net = state.net_watch:recv_op():wrap(function (ev, err) return { kind = ev and 'net_segments_changed' or 'net_segments_closed', ev = ev, err = err } end),
		provider = state.provider_watch:recv_op():wrap(function (ev, err) return { kind = ev and 'provider_changed' or 'provider_closed', ev = ev, err = err } end),
	}
	if state.provider_deps then
		local src = state.provider_deps:event_source({ name = 'dependencies' })
		arms.dependencies = src.recv_op()
	end
	return fibers.named_choice(arms):wrap(function (_, ev) return ev end)
end

function M.handle_event(state, ev)
	if not ev then return nil, 'wired event stream closed' end
	if ev.kind == 'wired_config_changed' then return apply_config(state, ev) end
	if ev.kind == 'wired_config_closed' then return nil, ev.err or 'wired config closed' end
	if ev.kind == 'net_segments_changed' then return apply_net_segments(state, ev.ev) end
	if ev.kind == 'net_segments_closed' then return nil, ev.err or 'net segments watch closed' end
	if ev.kind == 'provider_changed' then return apply_provider_event(state, ev.ev) end
	if ev.kind == 'provider_closed' then return nil, ev.err or 'wired provider watch closed' end
	if ev.kind == 'wired_dependency_changed' or ev.kind == 'wired_dependency_closed' then return apply_dependency_event(state, ev) end
	return true, nil
end

M._test = {
	rebuild_derived = rebuild_derived,
	observed_vlan_set = observed_vlan_set,
}

function M.run(scope, opts)
	opts = opts or {}
	local state, err = M.build_state(scope, opts)
	if not state then error(err or 'wired service start failed', 0) end
	publish(state)
	while true do
		local ev = fibers.perform(M.next_event_op(state))
		local ok, herr = M.handle_event(state, ev)
		if ok ~= true then error(herr or 'wired service failed', 0) end
	end
end

return M
