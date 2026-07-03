-- services/wired/service.lua
--
-- Minimal house-style Wired service.
-- The coordinator owns no OS-facing work.  It composes configured appliance
-- surfaces from net segment state, Device physical assembly and raw wired observations.

local fibers = require 'fibers'
local runtime = require 'fibers.runtime'
local config_mod = require 'services.wired.config'
local model_mod = require 'services.wired.model'
local topics = require 'services.wired.topics'
local publisher = require 'services.wired.publisher'
local bus_cleanup = require 'devicecode.support.bus_cleanup'
local config_watch = require 'devicecode.support.config_watch'
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

local function update_observation_from_event(snap, ev)
	local topic = ev and ev.topic or {}
	if topic[1] ~= 'raw'
		or topic[2] ~= 'host'
		or topic[3] ~= 'wired'
		or topic[4] ~= 'provider'
	then
		return false
	end
	local id = topic[5]
	if type(id) ~= 'string' or id == '' then return false end
	local current = snap.observations[id]
	local rec = copy(current or { id = id, status = {}, identity = {}, runtime = {}, power = {}, surfaces = {}, counters = {}, topology = {}, meta = {} })
	if ev.op == 'unretain' then
		if topic[6] == 'status' then rec.status = { state = 'unavailable', available = false, reason = 'unretained' }
		elseif topic[6] == 'state' and topic[7] == 'identity' then rec.identity = {}
		elseif topic[6] == 'state' and topic[7] == 'runtime' then rec.runtime = {}
		elseif topic[6] == 'state' and topic[7] == 'power' then rec.power = {}
		elseif topic[6] == 'state' and topic[7] == 'surfaces' then rec.surfaces = {}
		elseif topic[6] == 'state' and topic[7] == 'counters' then rec.counters = {}
		elseif topic[6] == 'state' and topic[7] == 'topology' then rec.topology = {}
		elseif topic[6] == 'meta' then rec.meta = {} end
	else
		local payload = copy(ev.payload or {})
		if topic[6] == 'status' then rec.status = payload
		elseif topic[6] == 'state' and topic[7] == 'identity' then rec.identity = payload
		elseif topic[6] == 'state' and topic[7] == 'runtime' then rec.runtime = payload
		elseif topic[6] == 'state' and topic[7] == 'power' then rec.power = payload
		elseif topic[6] == 'state' and topic[7] == 'surfaces' then rec.surfaces = payload.surfaces or payload
		elseif topic[6] == 'state' and topic[7] == 'counters' then rec.counters = payload.counters or payload
		elseif topic[6] == 'state' and topic[7] == 'topology' then rec.topology = payload
		elseif topic[6] == 'meta' then rec.meta = payload end
	end
	if tablex.deep_equal(current, rec) then return false, id end
	snap.observations[id] = rec
	return true, id
end

local function net_segments_from_payload(payload)
	if type(payload) ~= 'table' then return {}, {} end
	return copy(payload.segments or payload), copy(payload.vlan_policy or {})
end

local function observed_surface_record(observation, observed_surface)
	local surfaces = observation and observation.surfaces or nil
	if type(surfaces) ~= 'table' then return nil end
	return surfaces[observed_surface]
end


local function assembly_surface(snap, surface_id)
	local assembly = snap and snap.assembly or {}
	local surfaces = assembly and assembly.surfaces or {}
	return type(surfaces) == 'table' and surfaces[surface_id] or nil
end

local function resolve_observation_binding(snap, desired)
	local a = assembly_surface(snap, desired and desired.surface_id or desired and desired.id)
	if type(a) ~= 'table' then return nil, 'assembly_surface_missing' end
	if type(a.component) ~= 'string' or a.component == '' then return nil, 'assembly_component_missing' end
	if type(a.observed_surface) ~= 'string' or a.observed_surface == '' then return nil, 'assembly_observed_surface_missing' end
	return {
		component = a.component,
		observed_surface = a.observed_surface,
		exposure = a.exposure,
		connector = a.connector,
		assembly = copy(a),
	}, nil
end

local function source_from_binding(binding)
	if not binding then return nil end
	return {
		kind = 'local-provider',
		component = binding.component,
		observed_surface = binding.observed_surface,
		exposure = binding.exposure,
		connector = binding.connector,
	}
end

local function observation_available(_snap, _component, observation)
	if observation == nil then return false, 'source_missing' end
	local st = observation.status or {}
	if st.available == false or st.state == 'removed' or st.state == 'unavailable' or st.state == 'not_configured' then
		return false, st.reason or st.state or 'source_unavailable'
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

local function validate_observed_capabilities(violations, surface_id, desired, binding, p_surface)
	if p_surface == nil then return end
	local caps = p_surface.capabilities
	if not is_plain_table(caps) then return end
	local mode = desired.attachment and desired.attachment.mode or 'none'
	if mode == 'access' and caps.access ~= true then
		append_violation(violations, 'observed_surface_does_not_support_access', {
			surface_id = surface_id,
			observed_surface = binding and binding.observed_surface or nil,
		})
	elseif mode == 'trunk' and caps.trunk ~= true then
		append_violation(violations, 'observed_surface_does_not_support_trunk', {
			surface_id = surface_id,
			observed_surface = binding and binding.observed_surface or nil,
		})
	end
	local dcaps = desired.capabilities
	if is_plain_table(dcaps) and dcaps.poe == true and caps.poe ~= true then
		append_violation(violations, 'observed_surface_does_not_support_poe', {
			surface_id = surface_id,
			observed_surface = binding and binding.observed_surface or nil,
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
	local counters = {}
	local violations = {}
	local topology = { protected_trunks = {}, access = {}, trunks = {} }
	local segments = snap.net and snap.net.segments or {}

	for id, desired in pairs((snap.config_intent and snap.config_intent.surfaces) or {}) do
		local binding, binding_reason = resolve_observation_binding(snap, desired)
		local component = binding and binding.component or nil
		local observation = component and snap.observations[component] or nil
		local p_ok, p_reason = observation_available(snap, component, observation)
		if not binding then p_ok, p_reason = false, binding_reason or 'assembly_binding_missing' end
		local p_surface = binding and observed_surface_record(observation, binding.observed_surface) or nil
		local link = copy((p_surface and p_surface.link) or {})
		local observed_attachment = copy((p_surface and p_surface.attachment) or {})
		local observed_counters = copy((observation and observation.counters and binding and observation.counters[binding.observed_surface]) or {})
		local observed_poe = copy((p_surface and p_surface.poe) or {})
		local availability = { state = 'available', reason = nil }
		if desired.enabled == false then
			availability = { state = 'disabled', reason = 'disabled_by_config' }
		elseif not p_ok then
			availability = { state = 'unavailable', reason = p_reason }
		elseif p_surface == nil then
			availability = { state = 'degraded', reason = 'observed_surface_missing' }
		end

		for _, segment_id in ipairs(collect_attachment_segments(desired.attachment)) do
			if not segments[segment_id] then
				append_violation(violations, 'unknown_segment', { surface_id = id, segment = segment_id })
			end
		end

		validate_observed_capabilities(violations, id, desired, binding, p_surface)

		if next(observed_counters) ~= nil then
			counters[id] = {
				surface_id = id,
				source = source_from_binding(binding),
				counters = observed_counters,
			}
		end

		if desired.protected then
			if desired.enabled == false then append_violation(violations, 'protected_surface_disabled', { surface_id = id, severity = 'critical' }) end
			if desired.attachment.mode ~= 'trunk' then append_violation(violations, 'protected_surface_not_trunk', { surface_id = id, severity = 'critical' }) end
			if observation == nil then
				append_violation(violations, 'protected_source_missing', { surface_id = id, component = component, severity = 'critical' })
			elseif not p_ok then
				append_violation(violations, 'protected_source_unavailable', { surface_id = id, component = component, reason = p_reason, severity = 'critical' })
			elseif p_surface == nil then
				append_violation(violations, 'protected_observed_surface_missing', {
					surface_id = id,
					component = component,
					observed_surface = binding and binding.observed_surface,
					severity = 'critical',
				})
			end
			local expected_vlans, observed_vlans = validate_protected_trunk_carriage(violations, id, desired, p_ok, p_surface, observed_attachment, segments)
			topology.protected_trunks[id] = {
				surface_id = id,
				required_segments = copy(desired.attachment.required_segments),
				required_vlans = expected_vlans,
				observed_vlans = observed_vlans,
				source = source_from_binding(binding),
			}
		end

		if desired.attachment.mode == 'access' then topology.access[id] = { surface_id = id, segment = desired.attachment.segment }
		elseif desired.attachment.mode == 'trunk' then topology.trunks[id] = { surface_id = id, segments = copy(desired.attachment.segments), required_segments = copy(desired.attachment.required_segments), user_segments = copy(desired.attachment.user_segments), expanded_user_segments = expand_user_segments(desired.attachment, segments) }
		end

		surfaces[id] = {
			surface_id = id,
			name = desired.name,
			description = desired.description,
			kind = desired.kind,
			role = desired.role,
			enabled = desired.enabled,
			protected = desired.protected,
			source = source_from_binding(binding),
			capabilities = copy(desired.capabilities),
			attachment = copy(desired.attachment),
			observed = { attachment = observed_attachment, poe = observed_poe, source = source_from_binding(binding) },
			link = link,
			poe = observed_poe,
			availability = availability,
		}
	end

	snap.surfaces = surfaces
	snap.counters = counters
	snap.topology = topology
	snap.violations = violations
	snap.ready = true
	snap.state = (#violations == 0) and 'running' or 'degraded'
	snap.reason = (#violations == 0) and nil or 'validation_violations'
	return snap
end

local function mark_surfaces_for_provider(dirty, snap, provider_id)
	local marked = false
	if provider_id == nil then return marked end
	for surface_id, desired in pairs((snap.config_intent and snap.config_intent.surfaces) or {}) do
		local binding = resolve_observation_binding(snap, desired)
		if binding and binding.component == provider_id then
			publisher.mark_surface(dirty, surface_id)
			marked = true
		end
	end
	return marked
end


local function mark_counters_for_provider(dirty, snap, provider_id)
	local marked = false
	if provider_id == nil then return marked end
	for surface_id, desired in pairs((snap.config_intent and snap.config_intent.surfaces) or {}) do
		local binding = resolve_observation_binding(snap, desired)
		if binding and binding.component == provider_id then
			publisher.mark_counter(dirty, surface_id)
			marked = true
		end
	end
	return marked
end

local function publish(state)
	local snap = state.model:snapshot()
	local ok, err, changed = publisher.publish_dirty_now(state.conn, snap, state.published, state.dirty)
	if ok ~= true then return nil, err end
	if (changed or 0) > 0 then
		state.model:update(function (s)
			s.stats.publications = (s.stats.publications or 0) + 1
			return s
		end)
	end
	return true, nil
end


local function apply_config(state, ev)
	local intent, err = config_mod.normalise(ev and ev.raw or nil, { rev = ev and ev.rev, generation = ev and ev.generation })
	if not intent then return nil, err end
	local _changed, _version, uerr = state.model:update(function (snap)
		snap.generation = (ev and ev.generation) or (snap.generation + 1)
		snap.config = { rev = intent.rev, schema = intent.schema, config_schema = intent.config_schema, version = intent.version }
		snap.config_intent = intent
		snap.stats.config_updates = (snap.stats.config_updates or 0) + 1
		return rebuild_derived(snap)
	end)
	if uerr ~= nil then return nil, uerr end
	publisher.mark_all(state.dirty)
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
	publisher.mark_all(state.dirty)
	return publish(state)
end

local function apply_assembly_event(state, ev)
	if ev and ev.op == 'replay_done' then return true, nil end
	local assembly = (ev and ev.op == 'unretain') and {} or copy((ev and ev.payload) or {})
	local _changed, _version, uerr = state.model:update(function (snap)
		snap.assembly = assembly
		snap.stats.assembly_updates = (snap.stats.assembly_updates or 0) + 1
		return rebuild_derived(snap)
	end)
	if uerr ~= nil then return nil, uerr end
	publisher.mark_all(state.dirty)
	return publish(state)
end

local function apply_observation_event(state, ev)
	if ev and ev.op == 'replay_done' then return true, nil end
	local changed_provider_id
	local observation_changed = false
	local _changed, _version, uerr = state.model:update(function (snap)
		local changed, provider_id = update_observation_from_event(snap, ev)
		changed_provider_id = provider_id
		observation_changed = changed == true
		if changed then snap.stats.observation_updates = (snap.stats.observation_updates or 0) + 1 end
		return rebuild_derived(snap)
	end)
	if uerr ~= nil then return nil, uerr end
	if not observation_changed then return true, nil end
	local snap = state.model:snapshot()
	local topic = ev and ev.topic or {}
	if topic[6] == 'state' and topic[7] == 'counters' then
		if not mark_counters_for_provider(state.dirty, snap, changed_provider_id) then
			publisher.mark_summary(state.dirty)
		end
		return publish(state)
	end
	local surface_marked = mark_surfaces_for_provider(state.dirty, snap, changed_provider_id)
	local counter_marked = mark_counters_for_provider(state.dirty, snap, changed_provider_id)
	if not surface_marked and not counter_marked then
		publisher.mark_summary(state.dirty)
	end
	publisher.mark_topology(state.dirty)
	publisher.mark_violations(state.dirty)
	return publish(state)
end


function M.build_state(scope, opts)
	opts = opts or {}
	local conn = assert(opts.conn, 'wired service requires conn')
	local cfg, cfg_err = config_watch.open(conn, 'wired', { changed_kind = 'wired_config_changed', closed_kind = 'wired_config_closed' })
	if not cfg then return nil, cfg_err end
	local net_watch, nerr = bus_cleanup.watch_retained(conn, topics.net_segments(), { replay = true, queue_len = 8, full = 'reject_newest' })
	if not net_watch then cfg:close(); return nil, nerr end
	local assembly_watch, aerr = bus_cleanup.watch_retained(conn, topics.device_assembly(), { replay = true, queue_len = 8, full = 'reject_newest' })
	if not assembly_watch then cfg:close(); bus_cleanup.unwatch_retained(conn, net_watch); return nil, aerr end
	local observation_watch, perr = bus_cleanup.watch_retained(conn, topics.raw_wired_provider_pattern(), { replay = true, queue_len = 32, full = 'reject_newest' })
	if not observation_watch then cfg:close(); bus_cleanup.unwatch_retained(conn, net_watch); bus_cleanup.unwatch_retained(conn, assembly_watch); return nil, perr end
	local state = {
		scope = scope,
		conn = conn,
		model = opts.model or model_mod.new(opts.service_id or new_service_id()),
		config_watch = cfg,
		net_watch = net_watch,
		assembly_watch = assembly_watch,
		observation_watch = observation_watch,
		published = publisher.new_state(),
		dirty = publisher.mark_all(publisher.new_dirty_state()),
	}
	scope:finally(function ()
		cfg:close()
		bus_cleanup.unwatch_retained(conn, net_watch)
		bus_cleanup.unwatch_retained(conn, assembly_watch)
		bus_cleanup.unwatch_retained(conn, observation_watch)
		publisher.cleanup_now(conn, state.published)
		state.model:terminate('wired_service_stopped')
	end)
	return state, nil
end

function M.next_event_op(state)
	local arms = {
		config = state.config_watch:recv_op(),
		net = state.net_watch:recv_op():wrap(function (ev, err) return { kind = ev and 'net_segments_changed' or 'net_segments_closed', ev = ev, err = err } end),
		assembly = state.assembly_watch:recv_op():wrap(function (ev, err) return { kind = ev and 'assembly_changed' or 'assembly_closed', ev = ev, err = err } end),
		observation = state.observation_watch:recv_op():wrap(function (ev, err) return { kind = ev and 'observation_changed' or 'observation_closed', ev = ev, err = err } end),
	}
	return fibers.named_choice(arms):wrap(function (_, ev) return ev end)
end

function M.handle_event(state, ev)
	if not ev then return nil, 'wired event stream closed' end
	if ev.kind == 'wired_config_changed' then return apply_config(state, ev) end
	if ev.kind == 'wired_config_closed' then return nil, ev.err or 'wired config closed' end
	if ev.kind == 'net_segments_changed' then return apply_net_segments(state, ev.ev) end
	if ev.kind == 'net_segments_closed' then return nil, ev.err or 'net segments watch closed' end
	if ev.kind == 'assembly_changed' then return apply_assembly_event(state, ev.ev) end
	if ev.kind == 'assembly_closed' then return nil, ev.err or 'device assembly watch closed' end
	if ev.kind == 'observation_changed' then return apply_observation_event(state, ev.ev) end
	if ev.kind == 'observation_closed' then return nil, ev.err or 'wired observation watch closed' end
	return true, nil
end

M._test = {
	rebuild_derived = rebuild_derived,
	observed_vlan_set = observed_vlan_set,
	update_observation_from_event = update_observation_from_event,
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
