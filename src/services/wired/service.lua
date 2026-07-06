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

local OPERATOR_SETTLE_S = 12
local COUNTER_FIRST_THRESHOLD = 25
local COUNTER_REPEAT_S = 60

local function now() return runtime.now() end
local function copy(v) return tablex.deep_copy(v) end
local function is_plain_table(v) return type(v) == 'table' and getmetatable(v) == nil end

local function count_map(t)
	local n = 0
	for _ in pairs(t or {}) do n = n + 1 end
	return n
end

local function count_where(t, pred)
	local n = 0
	for k, v in pairs(t or {}) do if pred(k, v) then n = n + 1 end end
	return n
end

local function surface_label(id, rec)
	return tostring((rec and (rec.operator_label or rec.name)) or id)
end

local function operator_settling(state)
	local started = state and state.operator_started_at or nil
	if not started then return false end
	return (now() - started) < (state.operator_settle_s or OPERATOR_SETTLE_S)
end

local function link_status(link)
	link = link or {}
	local v = link.state or link.status
	if v == nil and link.carrier ~= nil then v = link.carrier end
	if v == true or v == 'up' or v == 'online' or v == 'available' then return 'up' end
	if v == false or v == 'down' or v == 'offline' or v == 'unavailable' then return 'down' end
	return nil
end

local function link_is_up(link)
	return link_status(link) == 'up'
end

local function link_speed(link)
	link = link or {}
	return link.speed or link.speed_mbps
end

local function link_summary(link)
	link = link or {}
	local parts = {}
	local speed = link_speed(link)
	if speed then parts[#parts + 1] = 'speed=' .. tostring(speed) end
	if link.duplex then parts[#parts + 1] = 'duplex=' .. tostring(link.duplex) end
	return table.concat(parts, ' ')
end

local function segment_summary(rec)
	local parts = {}
	if rec and rec.segment_id then parts[#parts + 1] = 'segment=' .. tostring(rec.segment_id) end
	if rec and rec.vlan_id then parts[#parts + 1] = 'vlan=' .. tostring(rec.vlan_id) end
	return table.concat(parts, ' ')
end

local function has_observed_surfaces(surfaces)
	for _, rec in pairs(surfaces or {}) do
		if rec and rec.source and rec.source.exposure then return true end
	end
	return false
end

local function has_observed_link_state(surfaces)
	for _, rec in pairs(surfaces or {}) do
		if link_status(rec and rec.link or {}) ~= nil then return true end
	end
	return false
end

local function count_link_states(surfaces)
	local up, down, unknown = 0, 0, 0
	for _, rec in pairs(surfaces or {}) do
		local st = link_status(rec and rec.link or {})
		if st == 'up' then up = up + 1
		elseif st == 'down' then down = down + 1
		else unknown = unknown + 1 end
	end
	return up, down, unknown
end


local function link_brief(rec)
	if not rec then return 'unknown' end
	local st = link_status(rec.link or {}) or 'unknown'
	local speed = link_speed(rec.link or {})
	local duplex = rec.link and rec.link.duplex or nil
	local parts = { st }
	if speed then parts[#parts + 1] = tostring(speed) end
	if duplex then parts[#parts + 1] = tostring(duplex) end
	return table.concat(parts, '/')
end

local function choose_wan_surface(surfaces)
	for id, rec in pairs(surfaces or {}) do
		if rec and rec.role == 'wan-uplink' then return id, rec end
	end
	return nil, nil
end

local function choose_trunk_surface(surfaces)
	for id, rec in pairs(surfaces or {}) do
		if rec and rec.protected == true and link_status(rec.link or {}) ~= nil then return id, rec end
	end
	for id, rec in pairs(surfaces or {}) do
		if rec and rec.protected == true and rec.source and rec.source.exposure == 'internal' then return id, rec end
	end
	for id, rec in pairs(surfaces or {}) do
		if rec and rec.protected == true then return id, rec end
	end
	return nil, nil
end

local function log_wired_summary(state, snap, reason)
	if not state.svc then return end
	local surfaces = snap and snap.surfaces or {}
	if not has_observed_surfaces(surfaces) or not has_observed_link_state(surfaces) then return end
	local up, down, unknown = count_link_states(surfaces)
	local wan_id, wan = choose_wan_surface(surfaces)
	if not wan then return end
	local trunk_id, trunk = choose_trunk_surface(surfaces)
	local parts = {}
	if wan then parts[#parts + 1] = 'wan=' .. surface_label(wan_id, wan) .. ':' .. link_brief(wan) end
	if trunk then parts[#parts + 1] = 'trunk=' .. surface_label(trunk_id, trunk) .. ':' .. link_brief(trunk) end
	parts[#parts + 1] = 'links_up=' .. tostring(up)
	parts[#parts + 1] = 'links_down=' .. tostring(down)
	if unknown and unknown > 0 then parts[#parts + 1] = 'links_unknown=' .. tostring(unknown) end
	local summary = 'wired summary ' .. table.concat(parts, ' ')
	local tnow = now()
	if state.operator_wired_summary_key == summary and (tnow - (state.operator_wired_summary_at or 0)) < 600 then return end
	state.operator_wired_summary_key = summary
	state.operator_wired_summary_at = tnow
	state.svc:info('wired_summary', {
		summary = summary,
		reason = reason,
		wan_surface = wan_id,
		trunk_surface = trunk_id,
		links_up = up,
		links_down = down,
		links_unknown = unknown,
	})
end

local function log_wired_inventory(state, snap)
	if not state.svc then return end
	local surfaces = snap and snap.surfaces or {}
	if count_map(surfaces) == 0 then return end
	-- Configuration alone produces placeholder surfaces.  Wait until we have at
	-- least one observed provider surface before calling the runtime inventory ready.
	if not has_observed_surfaces(surfaces) or not has_observed_link_state(surfaces) then return end
	local protected = count_where(surfaces, function(_, rec) return rec and rec.protected == true end)
	local external = count_where(surfaces, function(_, rec) return rec and rec.source and rec.source.exposure == 'external' end)
	local key = tostring(count_map(surfaces)) .. '|' .. tostring(protected) .. '|' .. tostring(external)
	if state._operator_inventory_key == key then return end
	state._operator_inventory_key = key
	local up, down, unknown = count_link_states(surfaces)
	state.svc:info('wired_ready', {
		summary = string.format('wired ready surfaces=%d protected=%d external=%d links_up=%d links_down=%d links_unknown=%d', count_map(surfaces), protected, external, up, down, unknown),
		surfaces = count_map(surfaces),
		protected = protected,
		external = external,
		links_up = up,
		links_down = down,
		links_unknown = unknown,
	})
	log_wired_summary(state, snap, 'inventory_ready')
end

local function log_protected_backhaul(state, snap)
	if not state.svc then return end
	state._operator_backhaul_key = state._operator_backhaul_key or {}
	state._operator_backhaul_up_seen = state._operator_backhaul_up_seen or {}
	local surfaces = (snap and snap.surfaces) or {}
	if not has_observed_surfaces(surfaces) or not has_observed_link_state(surfaces) then return end
	for id, rec in pairs(surfaces) do
		if rec and rec.protected == true then
			local avail = rec.availability or {}
			local link = rec.link or {}
			local lst = link_status(link)
			local available = avail.state == 'available' or avail.state == 'ok'
			local up = available and lst == 'up'
			local state_now = up and 'up' or (lst or avail.state or 'unknown')
			local key = tostring(state_now) .. '|' .. tostring(link.speed or '') .. '|' .. tostring(link.duplex or '') .. '|' .. tostring(avail.reason or '')
			if state._operator_backhaul_key[id] ~= key then
				local ls = link_summary(link)
				if up then
					state._operator_backhaul_key[id] = key
					state._operator_backhaul_up_seen[id] = true
					state.svc:info('backhaul_up', {
						summary = string.format('wired backhaul %s link up%s', surface_label(id, rec), ls ~= '' and (' ' .. ls) or ''),
						surface_id = id,
						state = state_now,
						speed = link_speed(link),
						duplex = link.duplex,
					})
				else
					local pending = (operator_settling(state) and not state._operator_backhaul_up_seen[id])
						or (not state.operator_surface_baselined and not state._operator_backhaul_up_seen[id])
						or (available and lst == nil)
					if pending then
						state.svc:debug('backhaul_pending', {
							summary = string.format('wired backhaul %s pending state=%s%s', surface_label(id, rec), tostring(state_now), avail.reason and (' reason=' .. tostring(avail.reason)) or ''),
							surface_id = id,
							state = state_now,
							reason = avail.reason,
						})
					else
						state._operator_backhaul_key[id] = key
						state.svc:warn('backhaul_degraded', {
							summary = string.format('wired backhaul %s degraded state=%s%s%s', surface_label(id, rec), tostring(state_now), ls ~= '' and (' ' .. ls) or '', avail.reason and (' reason=' .. tostring(avail.reason)) or ''),
							surface_id = id,
							state = state_now,
							reason = avail.reason,
							speed = link_speed(link),
							duplex = link.duplex,
						})
					end
				end
			end
		end
	end
end

local function counter_number(t, a, b)
	local v = t and t[a]
	if type(v) == 'table' and b then v = v[b] end
	return tonumber(v) or 0
end

local function counter_total(c, key)
	return counter_number(c, key) + counter_number(c, 'rx', key) + counter_number(c, 'tx', key)
end

local function log_counter_anomalies(state, snap)
	if not state.svc then return end
	state.logged_counter_state = state.logged_counter_state or {}
	state.counter_windows = state.counter_windows or {}
	local tnow = now()
	for id, rec in pairs((snap and snap.counters) or {}) do
		local counters = rec.counters or {}
		local errors = counter_total(counters, 'errors')
		local drops = counter_total(counters, 'drops')
		local prev = state.logged_counter_state[id]
		state.logged_counter_state[id] = { errors = errors, drops = drops }
		if prev then
			local de = errors - (prev.errors or 0)
			local dd = drops - (prev.drops or 0)
			if de > 0 or dd > 0 then
				local surf = snap.surfaces and snap.surfaces[id]
				-- Operator warnings are reserved for protected/backhaul surfaces.  Other
				-- counters remain available as metrics and debug state.
				if not (surf and surf.protected) then
					state.svc:debug('counter_changed', { surface_id = id, errors_delta = de, drops_delta = dd })
				else
					local win = state.counter_windows[id] or { started_at = tnow, errors = 0, drops = 0, last_emit = nil }
					win.errors = (win.errors or 0) + de
					win.drops = (win.drops or 0) + dd
					local first = win.last_emit == nil
					local should_emit = (first and ((win.errors or 0) >= COUNTER_FIRST_THRESHOLD or (win.drops or 0) >= COUNTER_FIRST_THRESHOLD))
						or ((not first) and (tnow - win.last_emit) >= COUNTER_REPEAT_S)
					if should_emit then
						local elapsed = math.max(1, math.floor(tnow - (win.started_at or tnow) + 0.5))
						state.svc:warn(first and 'counter_anomaly' or 'counter_anomaly_continuing', {
							summary = string.format('wired %s errors=+%d drops=+%d over=%ds', surface_label(id, surf), win.errors or 0, win.drops or 0, elapsed),
							surface_id = id,
							errors_delta = win.errors or 0,
							drops_delta = win.drops or 0,
							protected = true,
							elapsed_s = elapsed,
						})
						win = { started_at = tnow, errors = 0, drops = 0, last_emit = tnow }
					end
					state.counter_windows[id] = win
				end
			end
		else
			local win = state.counter_windows[id]
			if win and win.last_emit and (tnow - win.last_emit) >= COUNTER_REPEAT_S and (win.errors or 0) == 0 and (win.drops or 0) == 0 then
				local surf = snap.surfaces and snap.surfaces[id]
				if surf and surf.protected then
					state.svc:info('counter_anomaly_stable', {
						summary = string.format('wired %s counters stable for %ds', surface_label(id, surf), COUNTER_REPEAT_S),
						surface_id = id,
					})
				end
				state.counter_windows[id] = nil
			end
		end
	end
end

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
	add_vlan_value(set, list, attachment.pvid)
	add_vlan_value(set, list, attachment.vlans)
	add_vlan_value(set, list, attachment.tagged)
	add_vlan_value(set, list, attachment.untagged)
	add_vlan_value(set, list, attachment.tagged_vlans)
	add_vlan_value(set, list, attachment.untagged_vlans)
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

local function segment_ids_for_vlans(segments, vlan_list)
	local out, seen = {}, {}
	for _, vlan in ipairs(vlan_list or {}) do
		for sid, seg in pairs(segments or {}) do
			if segment_vlan_id(seg) == vlan and not seen[sid] then
				seen[sid] = true
				out[#out + 1] = sid
			end
		end
	end
	table.sort(out)
	return out
end

local function connector_label(binding)
	local c = binding and binding.connector or nil
	if type(c) == 'string' and c ~= '' then return c end
	return nil
end

local function infer_surface_semantics(_surface_id, desired, binding, observed_attachment, segments)
	local inferred = {}
	local observed, observed_list = observed_vlan_set(observed_attachment or {})
	local carried = segment_ids_for_vlans(segments, observed_list)
	if #carried > 0 then inferred.carried_segments = carried end

	if desired and desired.protected == true then
		inferred.role = 'protected-trunk'
		inferred.label = desired.name
		return inferred
	end

	local wan_vlan = segments and segments.wan and segment_vlan_id(segments.wan) or nil
	local untagged = observed_attachment and observed_attachment.untagged_vlans or nil
	local pvid = normalise_vlan_id(observed_attachment and observed_attachment.pvid)
	local untagged_wan = false
	if wan_vlan then
		if pvid == wan_vlan then untagged_wan = true end
		for _, vlan in ipairs(untagged or {}) do
			if normalise_vlan_id(vlan) == wan_vlan then untagged_wan = true end
		end
	end

	if wan_vlan and observed[wan_vlan] and untagged_wan then
		inferred.role = 'wan-uplink'
		inferred.segment_id = 'wan'
		inferred.vlan_id = wan_vlan
		local c = connector_label(binding)
		inferred.label = c and ('WAN uplink ' .. c) or 'WAN uplink'
	end

	return inferred
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

		local inferred = infer_surface_semantics(id, desired, binding, observed_attachment, segments)
		surfaces[id] = {
			surface_id = id,
			name = desired.name,
			operator_label = inferred.label,
			description = desired.description,
			kind = desired.kind,
			role = inferred.role or desired.role,
			configured_role = desired.role,
			segment_id = inferred.segment_id,
			vlan_id = inferred.vlan_id,
			carried_segments = inferred.carried_segments,
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


local function log_surface_transitions(state, before, after)
	if not state.svc then return end
	local after_surfaces = after and after.surfaces or {}
	if not has_observed_surfaces(after_surfaces) or not has_observed_link_state(after_surfaces) then return end

	local function key_for(rec)
		local link = rec and rec.link or {}
		return tostring(link_status(link) or 'unknown') .. '|' .. tostring(link_speed(link) or '') .. '|' .. tostring(link.duplex or '')
	end

	-- First observed provider snapshot establishes the baseline.  Do not narrate
	-- every initially-down LAN port as a transition.
	if not state.operator_surface_baselined then
		state.operator_surface_baselined = true
		local up, down, unknown = count_link_states(after_surfaces)
		for id, rec in pairs(after_surfaces) do state.logged_surface_state[id] = key_for(rec) end
		state.svc:info('wired_ports_ready', {
			summary = string.format('wired ports observed links_up=%d links_down=%d links_unknown=%d', up, down, unknown),
			links_up = up,
			links_down = down,
			links_unknown = unknown,
		})
		return
	end

	for id, rec in pairs(after_surfaces or {}) do
		local link = rec and rec.link or {}
		local lst = link_status(link)
		local key = key_for(rec)
		if state.logged_surface_state[id] ~= key then
			local prev_key = state.logged_surface_state[id]
			state.logged_surface_state[id] = key
			if lst == nil then
				state.svc:debug('surface_link_unknown', { surface_id = id, previous = prev_key, current = key })
			else
				local up = lst == 'up'
					local important = rec and (rec.protected == true or rec.role == 'wan-uplink')
					local level = (important and not up) and 'warn' or 'info'
				local what = up and 'link_up' or 'link_down'
					local ls = link_summary(link)
					local ss = segment_summary(rec)
				state.svc:log(level, what, {
						summary = string.format('wired %s link %s%s%s', surface_label(id, rec), up and 'up' or 'down', ls ~= '' and (' ' .. ls) or '', ss ~= '' and (' ' .. ss) or ''),
					surface_id = id,
					name = rec and rec.name,
					operator_label = rec and rec.operator_label,
					role = rec and rec.role,
					segment_id = rec and rec.segment_id,
					vlan_id = rec and rec.vlan_id,
					protected = rec and rec.protected,
					link_state = lst,
					speed = link_speed(link),
					duplex = link.duplex,
				})
			end
		end
	end
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
	local before = state.model:snapshot()
	local _changed, _version, uerr = state.model:update(function (snap)
		snap.generation = (ev and ev.generation) or (snap.generation + 1)
		snap.config = { rev = intent.rev, schema = intent.schema, config_schema = intent.config_schema, version = intent.version }
		snap.config_intent = intent
		snap.stats.config_updates = (snap.stats.config_updates or 0) + 1
		return rebuild_derived(snap)
	end)
	if uerr ~= nil then return nil, uerr end
	publisher.mark_all(state.dirty)
	if state.svc then state.svc:info('wired_config_applied', { summary = string.format('wired config applied surfaces=%s', tostring(count_map(intent.surfaces or {}))), generation = intent.generation, surfaces = count_map(intent.surfaces or {}) }) end
	-- Runtime inventory is narrated after provider observations arrive; config
	-- alone only tells us intended surfaces.
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
	local before = state.model:snapshot()
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
	log_surface_transitions(state, before, snap)
	log_wired_inventory(state, snap)
	log_protected_backhaul(state, snap)
	log_wired_summary(state, snap, 'observation')
	log_counter_anomalies(state, snap)
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
		svc = opts.svc,
		config_watch = cfg,
		net_watch = net_watch,
		assembly_watch = assembly_watch,
		observation_watch = observation_watch,
		published = publisher.new_state(),
		dirty = publisher.mark_all(publisher.new_dirty_state()),
		logged_surface_state = {},
		logged_counter_state = {},
		operator_started_at = now(),
		operator_settle_s = tonumber(opts.operator_settle_s) or OPERATOR_SETTLE_S,
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
	log_wired_inventory(state, state.model:snapshot())
	log_protected_backhaul(state, state.model:snapshot())
	publish(state)
	while true do
		local ev = fibers.perform(M.next_event_op(state))
		local ok, herr = M.handle_event(state, ev)
		if ok ~= true then error(herr or 'wired service failed', 0) end
	end
end

return M
