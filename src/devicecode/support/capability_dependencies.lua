-- devicecode/support/capability_dependencies.lua
--
-- Coordinator-facing capability dependency tracker.
--
-- This helper observes capability status topics and turns them into local,
-- non-yielding facts for service coordinators.  It deliberately does not
-- start work, retry calls, degrade services, or perform policy decisions.
-- Services should drain dependency recv Ops as coordinator inputs, inspect the
-- effective availability recorded here, and then admit their own scoped work.

local pulse       = require 'fibers.pulse'
local cap_sdk     = require 'services.hal.sdk.cap'
local bus_cleanup = require 'devicecode.support.bus_cleanup'
local queue       = require 'devicecode.support.queue'
local tablex      = require 'shared.table'

local M = {}
local Dependencies = {}
Dependencies.__index = Dependencies

local DEFAULT_ID = 'main'

local AVAILABLE_STATUS = {
	available = true,
	running = true,
}

local function copy(v)
	return tablex.deep_copy(v)
end

local function now_fn(opts)
	if opts and type(opts.now) == 'function' then return opts.now end
	if type(os.clock) == 'function' then return os.clock end
	return function () return 0 end
end

local function is_non_empty_string(v)
	return type(v) == 'string' and v ~= ''
end

local function assert_key(key)
	if not is_non_empty_string(key) then
		error('capability_dependencies: key must be a non-empty string', 3)
	end
	return key
end

local function status_available(status)
	return AVAILABLE_STATUS[tostring(status or '')] == true
end

local function normalise_status_payload(payload)
	if type(payload) == 'table' then
		local status
		if payload.state ~= nil then
			status = tostring(payload.state)
		elseif payload.status ~= nil then
			status = tostring(payload.status)
		elseif payload.available == true then
			status = 'available'
		elseif payload.available == false then
			status = 'unavailable'
		else
			status = 'unavailable'
		end

		local available
		if payload.available ~= nil then
			available = payload.available == true
		else
			available = status_available(status)
		end
		return status, available
	end

	if payload == nil then return 'unavailable', false end
	if payload == true then return 'available', true end
	if payload == false then return 'unavailable', false end

	local status = tostring(payload)
	return status, status_available(status)
end

local function topic_for_spec(spec)
	local id = spec.id or DEFAULT_ID
	if spec.raw_kind == 'host' then
		return { 'raw', 'host', spec.source, 'cap', spec.class, id, 'status' }
	elseif spec.raw_kind == 'member' then
		return { 'raw', 'member', spec.source, 'cap', spec.class, id, 'status' }
	end
	return { 'cap', spec.class, id, 'status' }
end

local function ref_for(conn, spec)
	if spec.ref ~= nil then return spec.ref end
	if conn == nil then return nil end
	local id = spec.id or DEFAULT_ID
	if spec.raw_kind == 'host' then
		return cap_sdk.new_raw_host_cap_ref(conn, spec.source, spec.class, id)
	elseif spec.raw_kind == 'member' then
		return cap_sdk.new_raw_member_cap_ref(conn, spec.source, spec.class, id)
	end
	return cap_sdk.new_curated_cap_ref(conn, spec.class, id)
end

local function subscribe_for(conn, dep, opts)
	if dep.watch_status == false then return nil, nil end

	-- A supplied capability ref may be a test double or a non-bus-backed ref.
	-- Prefer its own status subscription hook even when there is no bus
	-- connection.  A bus connection is needed only for the fallback topic
	-- subscription path below.
	if dep.ref ~= nil and type(dep.ref.get_status_sub) == 'function' then
		local ok, sub_or_err = pcall(function ()
			return dep.ref:get_status_sub({
				queue_len = dep.queue_len or opts.status_queue_len or opts.queue_len or 8,
				full = dep.full or opts.status_full or opts.full or 'drop_oldest',
			})
		end)
		if ok and sub_or_err ~= nil then return sub_or_err, nil end
		if not ok then return nil, tostring(sub_or_err or 'status subscription failed') end
		return nil, 'status subscription failed'
	end

	if conn ~= nil and dep.topic ~= nil then
		return bus_cleanup.subscribe(conn, dep.topic, {
			queue_len = dep.queue_len or opts.status_queue_len or opts.queue_len or 8,
			full = dep.full or opts.status_full or opts.full or 'drop_oldest',
		})
	end

	return nil, nil
end

local function format_reason(reason)
	if reason == nil then return nil end
	if type(reason) == 'table' then
		if reason.err ~= nil then return tostring(reason.err) end
		if reason.detail ~= nil then return tostring(reason.detail) end
		if reason.reason ~= nil and reason.reason ~= reason then return format_reason(reason.reason) end
		if reason.code ~= nil then return tostring(reason.code) end
		return 'route_missing'
	end
	return tostring(reason)
end

local function has_no_route(v, seen)
	if v == nil then return false end
	local tv = type(v)
	if tv == 'string' then return v == 'no_route' or v:find('no_route', 1, true) ~= nil end
	if tv ~= 'table' then return false end

	seen = seen or {}
	if seen[v] then return false end
	seen[v] = true

	if v.err == 'no_route' or v.detail == 'no_route' or v.reason == 'no_route' or v.code == 'no_route' then
		return true
	end

	return has_no_route(v.err, seen)
		or has_no_route(v.detail, seen)
		or has_no_route(v.reason, seen)
		or has_no_route(v.code, seen)
		or has_no_route(v.result, seen)
end

local function dep_public_snapshot(dep)
	return {
		key = dep.key,
		class = dep.class,
		id = dep.id,
		raw_kind = dep.raw_kind,
		source = dep.source,
		required = dep.required,
		configured = dep.configured,
		watched = dep.sub ~= nil,
		topic = copy(dep.topic),
		observed_status = dep.observed_status,
		observed_available = dep.observed_available == true,
		effective_status = dep.effective_status,
		status = dep.effective_status,
		available = dep.available == true,
		route_missing = dep.route_missing == true,
		reason = dep.reason,
		last_error = copy(dep.last_error),
		last_error_at = dep.last_error_at,
		updated_at = dep.updated_at,
		payload = copy(dep.payload),
	}
end

local function ordered_specs(specs)
	local out = {}
	for i = 1, #(specs or {}) do out[#out + 1] = specs[i] end
	return out
end

local function build_dep(conn, spec, opts)
	if type(spec) ~= 'table' then
		return nil, 'capability_dependencies.open: each spec must be a table'
	end
	if not is_non_empty_string(spec.key) then
		return nil, 'capability_dependencies.open: spec.key must be a non-empty string'
	end
	if spec.ref == nil and not is_non_empty_string(spec.class) then
		return nil, 'capability_dependencies.open: spec.class must be a non-empty string when ref is not supplied'
	end
	if (spec.raw_kind == 'host' or spec.raw_kind == 'member') and not is_non_empty_string(spec.source) then
		return nil, 'capability_dependencies.open: raw capability specs require source'
	end

	local dep = {
		key = spec.key,
		class = spec.class,
		id = spec.id or DEFAULT_ID,
		raw_kind = spec.raw_kind,
		source = spec.source,
		required = spec.required ~= false,
		watch_status = spec.watch_status ~= false,
		queue_len = spec.queue_len,
		full = spec.full,
		ref = ref_for(conn, spec),
		topic = spec.topic,
		observed_status = nil,
		observed_available = false,
		effective_status = nil,
		available = false,
		route_missing = false,
		reason = nil,
		last_error = nil,
		last_error_at = nil,
		updated_at = nil,
		payload = nil,
	}

	if dep.topic == nil and spec.class ~= nil then dep.topic = topic_for_spec(dep) end
	dep.configured = dep.ref ~= nil
	dep.observed_status = dep.configured and (spec.initial_status or 'configured') or 'not_configured'
	dep.effective_status = dep.observed_status
	dep.available = status_available(dep.effective_status)
	dep.observed_available = dep.available
	dep.updated_at = opts._now()

	local sub, err = subscribe_for(conn, dep, opts)
	if err ~= nil then
		dep.observed_status = 'status_unavailable'
		dep.effective_status = 'status_unavailable'
		dep.available = false
		dep.reason = err
	else
		dep.sub = sub
	end

	return dep, nil
end

function M.status_available(status)
	return status_available(status)
end

function M.is_no_route(...)
	for i = 1, select('#', ...) do
		local value = select(i, ...)
		if has_no_route(value) then return true end
	end
	return false
end

function M.open(conn, specs, opts)
	opts = opts or {}
	if type(specs) ~= 'table' then
		return nil, 'capability_dependencies.open: specs must be a table'
	end
	opts._now = now_fn(opts)

	local deps = {}
	local order = {}
	local mgr = setmetatable({
		conn = conn,
		_deps = deps,
		_order = order,
		_pulse = pulse.new(0),
		_closed = false,
		_closed_reason = nil,
		_now = opts._now,
		changed_kind = opts.changed_kind or 'capability_dependency_changed',
		closed_kind = opts.closed_kind or 'capability_dependency_closed',
	}, Dependencies)

	for _, spec in ipairs(ordered_specs(specs)) do
		local dep, err = build_dep(conn, spec, opts)
		if not dep then
			mgr:terminate('open_failed')
			return nil, err
		end
		if deps[dep.key] ~= nil then
			mgr:terminate('open_failed')
			return nil, 'capability_dependencies.open: duplicate key ' .. tostring(dep.key)
		end
		deps[dep.key] = dep
		order[#order + 1] = dep.key
	end

	return mgr, nil
end

function Dependencies:is_closed()
	return self._closed == true
end

function Dependencies:is_terminated()
	return self:is_closed()
end

function Dependencies:why()
	return self._closed_reason
end

function Dependencies:version()
	return self._pulse:version()
end

function Dependencies:keys()
	local out = {}
	for i = 1, #self._order do out[i] = self._order[i] end
	return out
end

function Dependencies:ref(key)
	local dep = self._deps[assert_key(key)]
	return dep and dep.ref or nil
end

function Dependencies:dependency(key)
	local dep = self._deps[assert_key(key)]
	return dep and dep_public_snapshot(dep) or nil
end

function Dependencies:snapshot()
	local out = {}
	for i = 1, #self._order do
		local key = self._order[i]
		out[key] = dep_public_snapshot(self._deps[key])
	end
	return out
end

function Dependencies:status(key)
	local dep = self._deps[assert_key(key)]
	return dep and dep.effective_status or 'not_configured'
end

function Dependencies:observed_status(key)
	local dep = self._deps[assert_key(key)]
	return dep and dep.observed_status or 'not_configured'
end

function Dependencies:available(key)
	local dep = self._deps[assert_key(key)]
	return dep and dep.available == true or false
end

function Dependencies:reason(key)
	local dep = self._deps[assert_key(key)]
	return dep and dep.reason or nil
end

function Dependencies:all_available(which)
	local required_only = which == nil or which == true or which == 'required'
	for i = 1, #self._order do
		local dep = self._deps[self._order[i]]
		if (not required_only or dep.required) and dep.available ~= true then
			return false
		end
	end
	return true
end

function Dependencies:_signal_if_changed(before)
	local after = self:snapshot()
	if tablex.deep_equal(before, after) then return false, self:version() end
	return true, self._pulse:signal()
end

function Dependencies:_recompute(dep)
	local observed_status = dep.observed_status or (dep.configured and 'configured' or 'not_configured')
	local observed_available = dep.observed_available == true

	-- An explicit unavailability from the publisher is a stronger fact than a
	-- previous local no_route inference.  Keep last_error for diagnostics, but
	-- do not continue presenting route_missing as the effective state once the
	-- capability owner has said it is unavailable.
	if dep.route_missing and observed_available then
		dep.effective_status = 'route_missing'
		dep.available = false
		dep.reason = dep.reason or 'no_route'
		return
	end

	dep.effective_status = observed_status
	-- Availability is an observed fact when a status payload carries an
	-- explicit available field.  Do not infer true from state='running' or
	-- state='available' when the publisher explicitly said available=false.
	dep.available = observed_available
	if dep.available then dep.reason = nil end
end

function Dependencies:record_status(key, payload, meta)
	if self._closed then return nil, self._closed_reason or 'closed' end
	local dep = self._deps[assert_key(key)]
	if not dep then return nil, 'unknown_dependency' end

	local status, available = normalise_status_payload(payload)
	local payload_copy = copy(payload)
	local will_clear_route_missing = available == true and dep.route_missing == true
	if dep.observed_status == status
		and dep.observed_available == (available == true)
		and tablex.deep_equal(dep.payload, payload_copy)
		and not will_clear_route_missing
	then
		return dep.effective_status, dep.available == true, false, self:version()
	end

	local before = self:snapshot()
	dep.observed_status = status
	dep.observed_available = available == true
	dep.payload = payload_copy
	dep.updated_at = (meta and meta.at) or self._now()

	if available == true then
		dep.route_missing = false
		dep.last_error = nil
		dep.last_error_at = nil
		dep.reason = nil
	elseif dep.route_missing then
		-- Explicit unavailability supersedes a previous local no_route inference.
		dep.route_missing = false
		dep.reason = nil
	end

	self:_recompute(dep)
	local changed, version = self:_signal_if_changed(before)
	return dep.effective_status, dep.available == true, changed, version
end

function Dependencies:mark_route_missing(key, reason)
	if self._closed then return nil, self._closed_reason or 'closed' end
	local dep = self._deps[assert_key(key)]
	if not dep then return nil, 'unknown_dependency' end

	local before = self:snapshot()
	-- A no_route result is an availability override only when the publisher most
	-- recently said the capability was available.  If the publisher already says
	-- unavailable, keep that explicit observation as the effective state and record
	-- the route failure only as diagnostic detail.
	dep.route_missing = dep.observed_available == true
	dep.last_error = copy(reason or 'no_route')
	dep.last_error_at = self._now()
	dep.reason = dep.route_missing and (format_reason(reason) or 'no_route') or nil
	dep.updated_at = dep.last_error_at
	self:_recompute(dep)
	local changed, version = self:_signal_if_changed(before)
	return true, version, changed
end

function Dependencies:clear_route_missing(key)
	if self._closed then return nil, self._closed_reason or 'closed' end
	local dep = self._deps[assert_key(key)]
	if not dep then return nil, 'unknown_dependency' end

	local before = self:snapshot()
	dep.route_missing = false
	dep.last_error = nil
	dep.last_error_at = nil
	dep.reason = nil
	dep.updated_at = self._now()
	self:_recompute(dep)
	local changed, version = self:_signal_if_changed(before)
	return true, version, changed
end

function M.classify_call_failure(reply, err)
	if M.is_no_route(reply, err) then return 'route_missing', err or reply or 'no_route' end
	return 'failure', err or reply
end

function Dependencies:classify_call_failure(key, reply, err)
	local class, reason = M.classify_call_failure(reply, err)
	if class == 'route_missing' then
		local ok, version, changed = self:mark_route_missing(key, reason or 'no_route')
		return 'route_missing', reason or 'no_route', self:dependency(key), ok, version, changed
	end
	return class, reason, self:dependency(key), false, nil, false
end

function Dependencies:_event_from_msg(key, msg, err)
	if msg == nil then
		local status = self:record_status(key, { state = 'unavailable', reason = err or 'status_closed' })
		local dep = self._deps[assert_key(key)]
		if dep ~= nil then
			-- A closed status feed is a terminal observation for that feed.  Remove
			-- it from future coordinator event-source sets so callers do not spin on
			-- an already-ready closed recv_op().  The feed is already closed; normal
			-- finaliser cleanup remains idempotent for real bus subscriptions.
			dep.sub = nil
		end
		return {
			kind = self.closed_kind,
			key = key,
			status = status,
			available = self:available(key),
			reason = err or 'status_closed',
			dependency = self:dependency(key),
		}
	end

	local status, available, changed, version = self:record_status(key, msg.payload, { msg = msg })
	return {
		kind = self.changed_kind,
		key = key,
		status = status,
		available = available == true,
		changed = changed == true,
		version = version,
		dependency = self:dependency(key),
		msg = msg,
	}
end

function Dependencies:recv_op(key)
	local dep = self._deps[assert_key(key)]
	if not dep then error('unknown dependency: ' .. tostring(key), 2) end
	if not dep.sub then error('dependency is not watched: ' .. tostring(key), 2) end
	return dep.sub:recv_op():wrap(function (msg, err)
		return self:_event_from_msg(key, msg, err)
	end)
end

function Dependencies:try_recv_now(key)
	local dep = self._deps[assert_key(key)]
	if not dep then return nil, 'unknown_dependency' end
	if not dep.sub then return nil, 'not_watched' end
	local msg, err = queue.try_recv_now(dep.sub)
	if msg ~= nil then return self:_event_from_msg(key, msg, nil), nil end
	if err == 'not_ready' then return nil, 'not_ready' end
	return self:_event_from_msg(key, nil, err), nil
end

function Dependencies:event_source(key, opts)
	opts = opts or {}
	assert_key(key)
	local name = opts.name or ('capability_dependency:' .. key)
	return {
		name = name,
		try_now = function ()
			local ev = self:try_recv_now(key)
			return ev
		end,
		recv_op = function ()
			return self:recv_op(key)
		end,
	}
end

function Dependencies:event_sources(opts)
	opts = opts or {}
	local out = {}
	for i = 1, #self._order do
		local key = self._order[i]
		if self._deps[key].sub ~= nil then
			out[#out + 1] = self:event_source(key, {
				name = opts.prefix and (opts.prefix .. ':' .. key) or nil,
			})
		end
	end
	return out
end

function Dependencies:changed_op(last_seen)
	if type(last_seen) ~= 'number' or last_seen < 0 or last_seen % 1 ~= 0 then
		error('capability_dependencies.changed_op: last_seen must be a non-negative integer', 2)
	end
	return self._pulse:changed_op(last_seen):wrap(function (version, reason)
		if version == nil then
			return nil, nil, reason or self._closed_reason or 'closed'
		end
		return version, self:snapshot(), nil
	end)
end

function Dependencies:terminate(reason)
	if self._closed then return true, nil end
	self._closed = true
	self._closed_reason = reason or 'closed'
	for i = 1, #self._order do
		local dep = self._deps[self._order[i]]
		if dep.sub ~= nil then
			bus_cleanup.unsubscribe(self.conn, dep.sub)
			dep.sub = nil
		end
	end
	self._pulse:close(self._closed_reason)
	return true, nil
end

function Dependencies:close(reason)
	return self:terminate(reason or 'closed')
end

M.Dependencies = Dependencies
M._test = {
	normalise_status_payload = normalise_status_payload,
	topic_for_spec = topic_for_spec,
	has_no_route = has_no_route,
}

return M
