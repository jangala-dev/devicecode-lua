-- devicecode/support/capability_dependencies.lua
--
-- Coordinator-facing capability dependency tracker.
--
-- This helper observes capability status topics and turns them into local,
-- non-yielding facts for service coordinators.  It deliberately does not
-- start work, retry calls, degrade services, or perform policy decisions.
-- Services should treat it as a small observable model: inspect facts, wait for
-- changed_op() or event_source(), and then admit their own scoped work.

local fibers      = require 'fibers'
local op          = require 'fibers.op'
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

local function normalise_status_reason(payload)
	if type(payload) ~= 'table' then return nil end

	local reason = payload.reason
	if reason == nil then reason = payload.err end
	if reason == nil then reason = payload.error end
	if reason == nil then reason = payload.detail end

	return format_reason(reason)
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

		return status, available, normalise_status_reason(payload)
	end

	if payload == nil then return 'unavailable', false, nil end
	if payload == true then return 'available', true, nil end
	if payload == false then return 'unavailable', false, nil end

	local status = tostring(payload)
	return status, status_available(status), nil
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
		local ok, sub, sub_err = pcall(function ()
			return dep.ref:get_status_sub({
				queue_len = dep.queue_len or opts.status_queue_len or opts.queue_len or 8,
				full = dep.full or opts.status_full or opts.full or 'drop_oldest',
			})
		end)
		if ok and sub ~= nil then return sub, nil end
		if not ok then return nil, tostring(sub or 'status subscription failed') end
		return nil, tostring(sub_err or 'status subscription failed')
	end

	if conn ~= nil and dep.topic ~= nil then
		return bus_cleanup.subscribe(conn, dep.topic, {
			queue_len = dep.queue_len or opts.status_queue_len or opts.queue_len or 8,
			full = dep.full or opts.status_full or opts.full or 'drop_oldest',
		})
	end

	return nil, nil
end

local function watch_failure_policy(dep)
	if dep.watch_failure ~= nil then return dep.watch_failure end
	return dep.required and 'fail' or 'unavailable'
end

local function dependency_watch_failed_error(dep, err)
	return 'dependency_status_watch_failed:' .. tostring(dep.key) .. ':' .. tostring(err or 'status subscription failed')
end

local function record_watch_failed(dep, err, now)
	dep.observed_status = 'watch_failed'
	dep.observed_reason = tostring(err or 'status subscription failed')
	dep.effective_status = 'watch_failed'
	dep.available = false
	dep.reason = dep.observed_reason
	dep.updated_at = now
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
		required = dep.required,

		observed_status = dep.observed_status,
		observed_reason = dep.observed_reason,

		status = dep.effective_status,
		available = dep.available == true,
		reason = dep.reason,

		route_missing = dep.route_missing == true,

		updated_at = dep.updated_at,
		last_error = copy(dep.last_error),
	}
end

local function ordered_specs(specs)
	local out = {}
	for i = 1, #(specs or {}) do out[#out + 1] = specs[i] end
	return out
end

local function build_dep(conn, spec, opts, now)
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
		watch_failure = spec.watch_failure,
		queue_len = spec.queue_len,
		full = spec.full,
		ref = ref_for(conn, spec),
		topic = spec.topic,
		observed_status = nil,
		observed_available = false,
		effective_status = nil,
		available = false,
		route_missing = false,
		observed_reason = nil,
		reason = nil,
		last_error = nil,
		updated_at = nil,
		payload = nil,
	}

	if dep.topic == nil and spec.class ~= nil then dep.topic = topic_for_spec(dep) end
	dep.configured = dep.ref ~= nil
	dep.observed_status = dep.configured and (spec.initial_status or 'configured') or 'not_configured'
	dep.effective_status = dep.observed_status
	dep.available = status_available(dep.effective_status)
	dep.observed_available = dep.available
	dep.updated_at = now()

	local sub, err = subscribe_for(conn, dep, opts)
	if err ~= nil then
		if watch_failure_policy(dep) == 'fail' then
			return nil, dependency_watch_failed_error(dep, err)
		end
		record_watch_failed(dep, err, now())
	else
		dep.sub = sub
	end

	return dep, nil
end

local function recompute(dep)
	local observed_status = dep.observed_status or (dep.configured and 'configured' or 'not_configured')
	local observed_available = dep.observed_available == true

	if dep.route_missing and observed_available then
		dep.effective_status = 'route_missing'
		dep.available = false
		dep.reason = dep.reason or 'no_route'
		return
	end

	dep.effective_status = observed_status
	dep.available = observed_available

	if dep.available then
		dep.reason = nil
	else
		dep.reason = dep.observed_reason
	end
end

local function signal_if_changed(self, before)
	local after = self:snapshot()
	if tablex.deep_equal(before, after) then return false, self:version() end
	return true, self._pulse:signal()
end

local function record_status(self, key, payload, meta)
	if self._closed then return nil, self._closed_reason or 'closed' end
	local dep = self._deps[assert_key(key)]
	if not dep then return nil, 'unknown_dependency' end

	local status, available, observed_reason = normalise_status_payload(payload)
	local payload_copy = copy(payload)
	local will_clear_route_missing = available == true and dep.route_missing == true
	if dep.observed_status == status
		and dep.observed_available == (available == true)
		and dep.observed_reason == observed_reason
		and tablex.deep_equal(dep.payload, payload_copy)
		and not will_clear_route_missing
	then
		return dep.effective_status, dep.available == true, false, self:version()
	end

	local before = self:snapshot()

	dep.observed_status = status
	dep.observed_available = available == true
	dep.observed_reason = observed_reason
	dep.payload = payload_copy
	dep.updated_at = (meta and meta.at) or self._now()

	if available == true then
		dep.route_missing = false
		dep.last_error = nil
		dep.reason = nil
	elseif dep.route_missing then
		-- Explicit unavailability supersedes a previous local no_route inference.
		dep.route_missing = false
		dep.reason = nil
	end

	recompute(dep)
	local changed, version = signal_if_changed(self, before)
	return dep.effective_status, dep.available == true, changed, version
end

local function mark_route_missing(self, key, reason)
	if self._closed then return nil, self._closed_reason or 'closed' end
	local dep = self._deps[assert_key(key)]
	if not dep then return nil, 'unknown_dependency' end

	local before = self:snapshot()
	dep.route_missing = dep.observed_available == true
	dep.last_error = copy(reason or 'no_route')
	dep.reason = dep.route_missing and (format_reason(reason) or 'no_route') or nil
	dep.updated_at = self._now()
	recompute(dep)
	local changed, version = signal_if_changed(self, before)
	return true, version, changed
end

local function event_from_msg(self, key, msg, err)
	if msg == nil then
		local status = record_status(self, key, { state = 'unavailable', reason = err or 'status_closed' })
		local dep = self._deps[assert_key(key)]
		if dep ~= nil then dep.sub = nil end
		return {
			kind = self.closed_kind,
			key = key,
			status = status,
			available = self:available(key),
			reason = err or 'status_closed',
			dependency = self:dependency(key),
		}
	end

	local status, available, changed, version = record_status(self, key, msg.payload, { msg = msg })
	return {
		kind = self.changed_kind,
		key = key,
		status = status,
		available = available == true,
		changed = changed == true,
		version = version,
		dependency = self:dependency(key),
		payload = msg.payload,
		msg = msg,
	}
end

local function recv_op_for(self, key)
	local dep = self._deps[assert_key(key)]
	if not dep or not dep.sub then return op.never() end
	return dep.sub:recv_op():wrap(function (msg, err)
		return event_from_msg(self, key, msg, err)
	end)
end

local function try_recv_for(self, key)
	local dep = self._deps[assert_key(key)]
	if not dep then return nil, 'unknown_dependency' end
	if not dep.sub then return nil, 'not_watched' end
	local msg, err = queue.try_recv_now(dep.sub)
	if msg ~= nil then return event_from_msg(self, key, msg, nil), nil end
	if err == 'not_ready' then return nil, 'not_ready' end
	return event_from_msg(self, key, nil, err), nil
end

local function try_recv_any(self)
	for i = 1, #self._order do
		local key = self._order[i]
		if self._deps[key].sub ~= nil then
			local ev, err = try_recv_for(self, key)
			if ev ~= nil then return ev, nil end
			if err ~= 'not_ready' and err ~= 'not_watched' then return nil, err end
		end
	end
	return nil, 'not_ready'
end

local function recv_any_op(self)
	local arms = {}
	for i = 1, #self._order do
		local key = self._order[i]
		if self._deps[key].sub ~= nil then
			arms[key] = recv_op_for(self, key)
		end
	end
	if next(arms) == nil then return op.never() end
	return fibers.named_choice(arms):wrap(function (_key, ev)
		return ev
	end)
end

local function has_active_source(self)
	if self._closed then return false end
	for i = 1, #self._order do
		if self._deps[self._order[i]].sub ~= nil then return true end
	end
	return false
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

function M.classify_call_failure(reply, err)
	if M.is_no_route(reply, err) then return 'route_missing', err or reply or 'no_route' end
	return 'failure', err or reply
end

function M.open(conn, specs, opts)
	local supplied_opts = opts or {}
	local open_opts = {}
	for k, v in pairs(supplied_opts) do open_opts[k] = v end
	if type(specs) ~= 'table' then
		return nil, 'capability_dependencies.open: specs must be a table'
	end
	local now = now_fn(open_opts)

	local deps = {}
	local order = {}
	local mgr = setmetatable({
		conn = conn,
		_deps = deps,
		_order = order,
		_pulse = pulse.new(0),
		_closed = false,
		_closed_reason = nil,
		_now = now,
		changed_kind = open_opts.changed_kind or 'capability_dependency_changed',
		closed_kind = open_opts.closed_kind or 'capability_dependency_closed',
	}, Dependencies)

	for _, spec in ipairs(ordered_specs(specs)) do
		local dep, err = build_dep(conn, spec, open_opts, now)
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

function Dependencies:version()
	return self._pulse:version()
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

-- status() is diagnostic.  Coordinators should use available() for
-- admission decisions because an observed status such as 'running' may still
-- carry available=false, or may be overridden locally by route_missing.
function Dependencies:status(key)
	local dep = self._deps[assert_key(key)]
	return dep and dep.effective_status or 'not_configured'
end

function Dependencies:available(key)
	local dep = self._deps[assert_key(key)]
	return dep and dep.available == true or false
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

function Dependencies:event_source(opts)
	opts = opts or {}
	local name = opts.name or 'capability_dependencies'
	return {
		name = name,
		enabled = function () return has_active_source(self) end,
		try_now = function ()
			while true do
				local ev = try_recv_any(self)
				if ev == nil then return nil end
				if ev.changed ~= false or ev.kind == self.closed_kind then return ev end
			end
		end,
		recv_op = function () return recv_any_op(self) end,
	}
end

function Dependencies:classify_call_failure(key, reply, err)
	local class, reason = M.classify_call_failure(reply, err)
	if class == 'route_missing' then
		local ok, version, changed = mark_route_missing(self, key, reason or 'no_route')
		return 'route_missing', reason or 'no_route', self:dependency(key), ok, version, changed
	end
	return class, reason, self:dependency(key), false, nil, false
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

M.Dependencies = Dependencies
M._test = {
	normalise_status_payload = normalise_status_payload,
	topic_for_spec = topic_for_spec,
	has_no_route = has_no_route,
}

return M
