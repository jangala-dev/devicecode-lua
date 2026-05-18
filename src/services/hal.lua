-- HAL modules
local types  = require "services.hal.types.core"
local base   = require "devicecode.service_base"
local Logger = require "services.hal.logger"

-- Fibers modules
local fibers  = require "fibers"
local op      = require "fibers.op"
local channel = require "fibers.channel"
local sleep   = require "fibers.sleep"

local tablex = require 'shared.table'

local perform = fibers.perform

local SCHEMA_STANDARD = "devicecode.config/hal/1"

local DEFAULT_Q_LEN = 10
local DEFAULT_CONTROL_TIMEOUT_S = 5.0
local DEFAULT_MANAGER_START_TIMEOUT_S = 10.0
local DEFAULT_MANAGER_APPLY_TIMEOUT_S = 10.0
local DEFAULT_MANAGER_SHUTDOWN_TIMEOUT_S = 5.0

local unpack = rawget(table, 'unpack') or _G.unpack
local pack   = rawget(table, 'pack') or function (...)
	return { n = select('#', ...), ... }
end

----------------------------------------------------------------------
-- Topic namespace
----------------------------------------------------------------------

local T = {}

function T.dev_meta(class, id)        return { 'dev', class, id, 'meta' } end
function T.dev_state(class, id)       return { 'dev', class, id, 'state' } end

function T.cap_meta(class, id)        return { 'cap', class, id, 'meta' } end
function T.cap_legacy_state(class,id) return { 'cap', class, id, 'state' } end
function T.cap_status(class, id)      return { 'cap', class, id, 'status' } end
function T.cap_state(class, id, key)  return { 'cap', class, id, 'state', key } end
function T.cap_event(class, id, name) return { 'cap', class, id, 'event', name } end
function T.cap_rpc(class, id, verb)   return { 'cap', class, id, 'rpc', verb } end

function T.raw_source_meta(src)       return { 'raw', 'host', src, 'meta' } end
function T.raw_source_status(src)     return { 'raw', 'host', src, 'status' } end

function T.raw_cap_meta(src, class, id)
	return { 'raw', 'host', src, 'cap', class, id, 'meta' }
end

function T.raw_cap_status(src, class, id)
	return { 'raw', 'host', src, 'cap', class, id, 'status' }
end

function T.raw_cap_state(src, class, id, key)
	return { 'raw', 'host', src, 'cap', class, id, 'state', key }
end

function T.raw_cap_event(src, class, id, name)
	return { 'raw', 'host', src, 'cap', class, id, 'event', name }
end

function T.raw_cap_rpc(src, class, id, verb)
	return { 'raw', 'host', src, 'cap', class, id, 'rpc', verb }
end

----------------------------------------------------------------------
-- Generic helpers
----------------------------------------------------------------------

local function class_valid(class)
	return type(class) == 'string' and class ~= ''
end

local function id_valid(id)
	return (type(id) == 'string' and id ~= '') or (type(id) == 'number' and id >= 0)
end

local function validate_config(config)
	if type(config) ~= 'table' then
		return false, "config must be a table"
	end

	if config.schema ~= SCHEMA_STANDARD then
		return false, "config schema must be " .. SCHEMA_STANDARD
	end

	for key, value in pairs(config) do
		if key ~= 'schema' then
			if type(key) ~= 'string' then
				return false, "config keys must be strings"
			end
			if type(value) ~= 'table' then
				return false, "config values must be tables"
			end
		end
	end

	return true, ""
end

local shallow_copy = tablex.shallow_copy

local function path_token(x)
	local s = tostring(x or '')
	s = s:gsub('[^%w%-_%.]+', '_')
	s = s:gsub('_+', '_')
	s = s:gsub('^_+', '')
	s = s:gsub('_+$', '')
	return (s ~= '') and s or 'unknown'
end

local function device_source_id(device)
	local meta = device.meta or {}
	local candidates = {
		meta.source_id,
		meta.source,
		meta.devpath,
		meta.path,
		meta.name,
		meta.serial,
		meta.uid,
	}

	for i = 1, #candidates do
		local v = candidates[i]
		if type(v) == 'string' and v ~= '' then return path_token(v) end
		if type(v) == 'number' then return path_token(v) end
	end

	return path_token(('%s_%s'):format(tostring(device.class), tostring(device.id)))
end

----------------------------------------------------------------------
-- Manager lifecycle compatibility seam
--
-- Legacy managers:
--   start(logger, dev_ch, cap_ch) -> "" | err
--   apply_config(config)          -> true|nil, err
--   stop()                        -> nil
--
-- Strict managers:
--   api_mode = 'op_only'
--   start_op(...)
--   apply_config_op(...)
--   shutdown_op()
--   terminate(reason)             -> immediate, non-yielding cleanup
--   fault_op()                    -> Op
--
-- New strict managers must implement the strict form exactly.  This file keeps
-- the old form alive only for legacy managers that still depend on the legacy
-- HAL boundary.
----------------------------------------------------------------------

local function manager_is_op_only(manager)
	return type(manager) == 'table'
		and manager.api_mode == 'op_only'
end

local STRICT_MANAGER_METHODS = {
	'start_op',
	'apply_config_op',
	'shutdown_op',
	'terminate',
	'fault_op',
}

local function validate_strict_manager(manager_name, manager)
	if not manager_is_op_only(manager) then
		return true, nil
	end

	for i = 1, #STRICT_MANAGER_METHODS do
		local method = STRICT_MANAGER_METHODS[i]
		if type(manager[method]) ~= 'function' then
			return false, ('strict manager %q missing %s'):format(
				tostring(manager_name),
				method
			)
		end
	end

	return true, nil
end

local function manager_call_op(manager_name, manager, method, ...)
	local args = pack(...)
	local op_name = method .. "_op"

	if type(manager[op_name]) == 'function' then
		local ev = manager[op_name](unpack(args, 1, args.n))
		if type(ev) ~= 'table' or getmetatable(ev) ~= op.Op then
			error(
				('manager %q method %q must return an Op, got %s (%s)'):format(
					tostring(manager_name),
					op_name,
					type(ev),
					tostring(ev)
				),
				2
			)
		end
		return ev
	end

	if manager_is_op_only(manager) then
		error(
			('manager %q must provide %q as an _op method; legacy fallback is not allowed'):format(
				tostring(manager_name),
				op_name
			),
			2
		)
	end

	if type(manager[method]) ~= 'function' then
		return op.always(false, ('manager %q does not implement %q'):format(
			tostring(manager_name),
			tostring(method)
		))
	end

	return op.guard(function ()
		local a, b = manager[method](unpack(args, 1, args.n))

		if method == 'start' and type(a) == 'string' and b == nil then
			return op.always(a == "", (a == "") and nil or a)
		end

		if method == 'stop' and a == nil and b == nil then
			return op.always(true, nil)
		end

		return op.always(a, b)
	end)
end

local function manager_call_with_timeout_op(manager_name, manager, method, timeout_s, ...)
	local has_op_method = type(manager[method .. "_op"]) == 'function'
	local ev = manager_call_op(manager_name, manager, method, ...)

	-- Only real _op manager methods can be timed out cooperatively.
	-- Legacy methods run synchronously inside manager_call_op's guard and are
	-- treated as immediate compatibility code.
	if not has_op_method or type(timeout_s) ~= 'number' or timeout_s < 0 then
		return ev
	end

	return op.named_choice({
		result  = ev,
		timeout = sleep.sleep_op(timeout_s),
	}):wrap(function(which, a, b)
		if which == 'timeout' then return false, 'timeout' end
		return a, b
	end)
end


local function manager_shutdown_op(manager_name, manager, timeout_s)
	if manager_is_op_only(manager) then
		return manager_call_with_timeout_op(
			manager_name,
			manager,
			'shutdown',
			timeout_s,
			timeout_s
		)
	end

	return manager_call_with_timeout_op(manager_name, manager, 'stop', timeout_s)
end

local function manager_terminate(manager_name, manager, reason)
	if not manager_is_op_only(manager) then
		return true, nil
	end

	if type(manager) ~= 'table' or type(manager.terminate) ~= 'function' then
		return nil, ('strict manager %q missing terminate'):format(tostring(manager_name))
	end

	local ok, a, b = pcall(function ()
		return manager.terminate(reason)
	end)

	if not ok then
		return nil, ('manager %q terminate raised: %s'):format(
			tostring(manager_name),
			tostring(a)
		)
	end

	if a == false or (a == nil and b ~= nil) then
		return nil, ('manager %q terminate failed: %s'):format(
			tostring(manager_name),
			tostring(b or 'termination failed')
		)
	end

	return true, nil
end

local function manager_fault_watch_op(manager_name, manager)
	if type(manager.fault_op) == 'function' then
		local ev = manager.fault_op()
		if type(ev) ~= 'table' or getmetatable(ev) ~= op.Op then
			error(
				('manager %q method fault_op must return an Op, got %s (%s)'):format(
					tostring(manager_name),
					type(ev),
					tostring(ev)
				),
				2
			)
		end
		return ev
	end

	if manager_is_op_only(manager) then
		error(
			('strict manager %q missing fault_op'):format(tostring(manager_name)),
			2
		)
	end

	if manager.scope and type(manager.scope.fault_op) == 'function' then
		return manager.scope:fault_op()
	end

	return op.never()
end

----------------------------------------------------------------------
-- Bus request/reply and control-dispatch helpers
----------------------------------------------------------------------

local function fallback_reply(reason)
	return select(1, types.new.Reply(false, tostring(reason or 'control failed')))
end

local function fail_request(req, reason, fallback_to_reply)
	local msg = tostring(reason or 'failed')

	if fallback_to_reply and req and req.reply then
		local reply = fallback_reply(msg)
		if reply and req:reply(reply) then return true end
	end

	if req and req.fail then
		return not not req:fail(msg)
	end

	return false
end

local function reply_control_failure(req, reason)
	local reply = fallback_reply(reason)
		or assert(select(1, types.new.Reply(false, 'control failed')))

	if req and type(req.reply) == 'function' then
		return req:reply(reply)
	end

	return false
end

local function remaining_sleep_op(deadline)
	return op.guard(function()
		local now = fibers.now()
		if deadline <= now then return op.always() end
		return sleep.sleep_op(deadline - now)
	end)
end

local function dispatch_cap_ctrl(cap_entry, verb, payload, timeout_s, bus_req)
	timeout_s = (type(timeout_s) == 'number' and timeout_s >= 0)
		and timeout_s
		or DEFAULT_CONTROL_TIMEOUT_S

	if not cap_entry or cap_entry.alive == false then
		return nil, 'capability unavailable'
	end

	local reply_ch = channel.new()
	local caller_cancel_op = nil
	if type(bus_req) == 'table' and type(bus_req.done_op) == 'function' then
		caller_cancel_op = bus_req:done_op():wrap(function (status, _value, err)
			if status == 'abandoned' then return 'caller_abandoned' end
			return false
		end)
	end
	local control_req, ctrl_req_err = types.new.ControlRequest(verb, payload, reply_ch, caller_cancel_op)
	if not control_req then
		return nil, tostring(ctrl_req_err or 'invalid control request')
	end

	local deadline = fibers.now() + timeout_s

	local send_choices = {
		sent = cap_entry.inst.control_ch:put_op(control_req):wrap(function()
			return true
		end),

		timeout = remaining_sleep_op(deadline):wrap(function()
			return false, 'timeout'
		end),
	}
	if caller_cancel_op ~= nil then send_choices.cancel = caller_cancel_op end

	local which, a, b = perform(op.named_choice(send_choices))

	if which == 'timeout' then
		return nil, 'timeout'
	end
	if which == 'cancel' and a ~= nil and a ~= false then
		return nil, tostring(a or 'caller_abandoned')
	end
	if which ~= 'sent' or a ~= true then
		return nil, tostring(b or 'control channel closed')
	end

	local reply_choices = {
		reply = reply_ch:get_op(),
		timeout = remaining_sleep_op(deadline):wrap(function()
			return nil, 'timeout'
		end),
	}
	if caller_cancel_op ~= nil then reply_choices.cancel = caller_cancel_op end

	local which2, reply_or_status, err_or_reason = perform(op.named_choice(reply_choices))

	if which2 == 'timeout' then
		return nil, 'timeout'
	end
	if which2 == 'cancel' and reply_or_status ~= nil and reply_or_status ~= false then
		return nil, tostring(reply_or_status or 'caller_abandoned')
	end
	if not reply_or_status then
		return nil, tostring(err_or_reason or 'reply channel closed')
	end

	return reply_or_status, nil
end

----------------------------------------------------------------------
-- Bus projection payloads and capability routing
--
-- Public projection:
--   cap/<class>/<id>/...
--
-- Raw host provenance projection:
--   raw/host/<source>/cap/<class>/<id>/...
--
-- The public projection is the stable capability surface. The raw projection
-- records where the host discovered it.
----------------------------------------------------------------------

local function availability_state(event_type)
	if event_type == 'added' then return 'available' end
	if event_type == 'removed' then return 'removed' end
	return tostring(event_type)
end

local function availability_flag(event_type)
	return event_type == 'added'
end

local function availability_payload(event_type, extra)
	local out = {
		state     = availability_state(event_type),
		available = availability_flag(event_type),
	}
	if type(extra) == 'table' then
		for k, v in pairs(extra) do out[k] = v end
	end
	return out
end

local function raw_source_meta_payload(device, source)
	local meta = shallow_copy(device.meta)
	meta.class  = device.class
	meta.id     = device.id
	meta.source = source
	return meta
end

local function raw_source_status_payload(event_type, source, device)
	return availability_payload(event_type, {
		source = source,
		class  = device.class,
		id     = device.id,
	})
end

local function cap_public_meta_payload(cap, entry)
	local out = { offerings = cap.offerings }
	for k, v in pairs(entry.meta_fields or {}) do out[k] = v end
	return out
end

local function cap_raw_meta_payload(cap, entry)
	local out = cap_public_meta_payload(cap, entry)
	out.source_kind = entry.source_kind
	out.source      = entry.source
	return out
end

local function cap_status_payload(event_type, entry)
	return availability_payload(event_type, {
		source_kind = entry.source_kind,
		source      = entry.source,
	})
end

-- Some host-discovered capabilities are deliberately kept raw until a higher
-- level appliance composer curates them into a public capability.  For wired
-- providers, Device owns the public cap/wired-provider/... surface; HAL only
-- publishes raw/host/<source>/cap/wired-provider/... and raw RPC.
local function public_cap_projection_enabled(class)
	return class ~= 'wired-provider'
end

local function parse_cap_ctrl_topic(topic)
	if topic[1] == 'cap' and topic[4] == 'rpc' then
		return 'public', topic[2], topic[3], topic[5], nil
	end

	if topic[1] == 'raw'
		and topic[2] == 'host'
		and topic[4] == 'cap'
		and topic[7] == 'rpc'
	then
		return 'raw-host', topic[5], topic[6], topic[8], topic[3]
	end

	return nil, nil, nil, nil, nil
end

----------------------------------------------------------------------
-- HAL service
----------------------------------------------------------------------

local HalService = {}

function HalService.start(conn, opts)
	opts = opts or {}

	local svc = base.new(conn, { name = opts.name or "hal", env = opts.env })
	HalService.name = svc.name

	local service_scope = fibers.current_scope()

	local heartbeat_s = (type(opts.heartbeat_s) == 'number') and opts.heartbeat_s or 30.0
	local control_timeout_s = (type(opts.control_timeout_s) == 'number')
		and opts.control_timeout_s
		or DEFAULT_CONTROL_TIMEOUT_S
	local manager_start_timeout_s = (type(opts.manager_start_timeout_s) == 'number')
		and opts.manager_start_timeout_s
		or DEFAULT_MANAGER_START_TIMEOUT_S
	local manager_apply_timeout_s = (type(opts.manager_apply_timeout_s) == 'number')
		and opts.manager_apply_timeout_s
		or DEFAULT_MANAGER_APPLY_TIMEOUT_S
	local manager_shutdown_timeout_s = (type(opts.manager_shutdown_timeout_s) == 'number')
		and opts.manager_shutdown_timeout_s
		or DEFAULT_MANAGER_SHUTDOWN_TIMEOUT_S

	local cap_emit_ch = channel.new(DEFAULT_Q_LEN)
	local dev_ev_ch   = channel.new(DEFAULT_Q_LEN)

	local managers = {}
	local registry = {
		devices = {},
		caps    = {},
	}

	local function obs_emitter(level, payload)
		svc:obs_log(level, payload)
	end

	local function log(level, what, fields)
		local payload = fields or {}
		payload.what = what
		svc:obs_log(level, payload)
	end

	local function reject_rpc(req, what, reason, fields)
		fields = fields or {}
		fields.err = tostring(reason)
		log('warn', what, fields)
		fail_request(req, reason, true)
	end

	local function spawn_service_worker(label, req, fn)
		local ok, err = fibers.spawn(fn)
		if ok then return true end

		local reason = tostring(err or 'service not accepting work')
		log('warn', 'worker_spawn_rejected', { label = tostring(label), err = reason })
		if req then fail_request(req, reason, true) end
		return false
	end

	local function shutdown_manager_async(name, manager, reason)
		return spawn_service_worker('manager_shutdown', nil, function()
			local ok, shutdown_err = perform(manager_shutdown_op(name, manager, manager_shutdown_timeout_s))
			if ok ~= true then
				log('warn', 'manager_shutdown_failed', {
					manager = name,
					reason  = reason,
					err     = tostring(shutdown_err),
				})

				local terminated, terminate_err = manager_terminate(name, manager, shutdown_err or reason)
				if terminated ~= true then
					log('warn', 'manager_terminate_failed', {
						manager = name,
						reason  = reason,
						err     = tostring(terminate_err),
					})
				end
			end
		end)
	end

	local function unbind_cap_endpoints(entry)
		if not entry then return end

		for _, ep in pairs(entry.rpc or {}) do ep:unbind() end
		for _, ep in pairs(entry.raw_rpc or {}) do ep:unbind() end
	end

	function registry:get_device(class, id)
		local class_devices = self.devices[class]
		return class_devices and class_devices[id] or nil
	end

	function registry:set_device(device)
		self.devices[device.class] = self.devices[device.class] or {}
		if self.devices[device.class][device.id] then
			return nil, 'device already exists'
		end
		self.devices[device.class][device.id] = device
		return true
	end

	function registry:remove_device(class, id)
		local class_devices = self.devices[class]
		if not class_devices or not class_devices[id] then
			return nil, 'device does not exist'
		end
		class_devices[id] = nil
		return true
	end

	function registry:get_cap(class, id)
		local class_caps = self.caps[class]
		return class_caps and class_caps[id] or nil
	end

	function registry:set_cap(class, id, cap_inst, source_kind, source)
		self.caps[class] = self.caps[class] or {}
		if self.caps[class][id] then
			return nil, 'capability already exists'
		end

		local entry = {
			inst        = cap_inst,
			rpc         = {},
			raw_rpc     = {},
			source_kind = source_kind,
			source      = source,
			state_keys  = {},
			meta_fields = {},
			alive       = true,
		}

		self.caps[class][id] = entry

		local expose_public = public_cap_projection_enabled(class)
		for offering in pairs(cap_inst.offerings) do
			if expose_public then
				entry.rpc[offering] = conn:bind(T.cap_rpc(class, id, offering))
			end
			if source_kind == 'host' and source then
				entry.raw_rpc[offering] = conn:bind(T.raw_cap_rpc(source, class, id, offering))
			end
		end

		return entry, nil
	end

	function registry:remove_cap(class, id)
		local class_caps = self.caps[class]
		local entry = class_caps and class_caps[id]
		if not entry then return nil, 'capability does not exist' end

		entry.alive = false
		unbind_cap_endpoints(entry)

		for key in pairs(entry.state_keys) do
			if public_cap_projection_enabled(class) then
				conn:unretain(T.cap_state(class, id, key))
			end
			if entry.source_kind == 'host' and entry.source then
				conn:unretain(T.raw_cap_state(entry.source, class, id, key))
			end
		end

		class_caps[id] = nil
		return true
	end

	function registry:rpc_ops()
		local out = {}
		for _, class_caps in pairs(self.caps) do
			for _, entry in pairs(class_caps) do
				for _, ep in pairs(entry.rpc) do out[#out + 1] = ep:recv_op() end
				for _, ep in pairs(entry.raw_rpc) do out[#out + 1] = ep:recv_op() end
			end
		end
		return out
	end

	function registry:terminate_caps(_reason)
		-- reason is accepted for finaliser-shaped call sites; bus endpoints
		-- expose immediate unbind without a reason parameter.
		for _, class_caps in pairs(self.caps) do
			for _, entry in pairs(class_caps) do
				entry.alive = false
				unbind_cap_endpoints(entry)
			end
		end
	end

	local function retain_raw_source(event_type, device)
		local source = device_source_id(device)
		conn:retain(T.raw_source_status(source), raw_source_status_payload(event_type, source, device))

		if event_type == 'added' then
			conn:retain(T.raw_source_meta(source), raw_source_meta_payload(device, source))
		else
			conn:unretain(T.raw_source_meta(source))
		end
	end

	local function retain_cap_projection(event_type, class, id, entry)
		if public_cap_projection_enabled(class) then
			conn:retain(T.cap_legacy_state(class, id), event_type)
			conn:retain(T.cap_status(class, id), cap_status_payload(event_type, entry))

			if event_type == 'added' then
				conn:retain(T.cap_meta(class, id), cap_public_meta_payload(entry.inst, entry))
			else
				conn:unretain(T.cap_meta(class, id))
			end
		else
			-- Defensive cleanup in case an earlier build exposed this class publicly.
			conn:unretain(T.cap_legacy_state(class, id))
			conn:unretain(T.cap_status(class, id))
			conn:unretain(T.cap_meta(class, id))
		end

		if entry.source_kind ~= 'host' or not entry.source then return end

		local source = entry.source
		conn:retain(T.raw_cap_status(source, class, id), cap_status_payload(event_type, entry))

		if event_type == 'added' then
			conn:retain(T.raw_cap_meta(source, class, id), cap_raw_meta_payload(entry.inst, entry))
		else
			conn:unretain(T.raw_cap_meta(source, class, id))
		end
	end

	local function publish_cap_event(entry, class, id, name, payload)
		if public_cap_projection_enabled(class) then
			conn:publish(T.cap_event(class, id, name), payload)
		end

		if entry.source_kind == 'host' and entry.source then
			conn:publish(T.raw_cap_event(entry.source, class, id, name), payload)
		end
	end

	local function retain_cap_state(entry, class, id, key, payload)
		entry.state_keys[key] = true
		if public_cap_projection_enabled(class) then
			conn:retain(T.cap_state(class, id, key), payload)
		end

		if entry.source_kind == 'host' and entry.source then
			conn:retain(T.raw_cap_state(entry.source, class, id, key), payload)
		end
	end

	local function retain_cap_meta(entry, class, id)
		if public_cap_projection_enabled(class) then
			conn:retain(T.cap_meta(class, id), cap_public_meta_payload(entry.inst, entry))
		end

		if entry.source_kind == 'host' and entry.source then
			conn:retain(T.raw_cap_meta(entry.source, class, id), cap_raw_meta_payload(entry.inst, entry))
		end
	end

	local function register_device(event_type, device)
		local ok, set_err = registry:set_device(device)
		if not ok then
			log('warn', 'register_device_skipped', {
				err   = set_err,
				class = device.class,
				id    = device.id,
			})
			return
		end

		local source_kind = 'host'
		local source = device_source_id(device)

		retain_raw_source(event_type, device)

		for _, cap in ipairs(device.capabilities) do
			local entry, cap_set_err = registry:set_cap(cap.class, cap.id, cap, source_kind, source)
			if not entry then
				log('warn', 'register_capability_skipped', {
					err   = cap_set_err,
					class = cap.class,
					id    = cap.id,
				})
			else
				svc:obs_event('capability_registered', {
					class  = cap.class,
					id     = cap.id,
					source = source,
				})
				retain_cap_projection(event_type, cap.class, cap.id, entry)
			end
		end

		conn:retain(T.dev_meta(device.class, device.id), device.meta)
		conn:retain(T.dev_state(device.class, device.id), event_type)

		svc:obs_event('device_registered', {
			class      = device.class,
			id         = device.id,
			event_type = event_type,
			source     = source,
		})
	end

	local function unregister_device(event_type, device)
		local source = device_source_id(device)

		for _, cap in ipairs(device.capabilities) do
			local entry = registry:get_cap(cap.class, cap.id)
			if not entry then
				log('warn', 'remove_capability_skipped', {
					err   = 'capability does not exist',
					class = cap.class,
					id    = cap.id,
				})
			else
				svc:obs_event('capability_unregistered', {
					class  = cap.class,
					id     = cap.id,
					source = source,
				})

				retain_cap_projection(event_type, cap.class, cap.id, entry)

				local ok, cap_remove_err = registry:remove_cap(cap.class, cap.id)
				if not ok then
					log('warn', 'remove_capability_skipped', {
						err   = cap_remove_err,
						class = cap.class,
						id    = cap.id,
					})
				end
			end
		end

		local ok, remove_err = registry:remove_device(device.class, device.id)
		if not ok then
			log('warn', 'remove_device_skipped', {
				err   = remove_err,
				class = device.class,
				id    = device.id,
			})
			return
		end

		conn:unretain(T.dev_meta(device.class, device.id))
		conn:retain(T.dev_state(device.class, device.id), event_type)
		retain_raw_source(event_type, device)

		svc:obs_event('device_unregistered', {
			class      = device.class,
			id         = device.id,
			event_type = event_type,
			source     = source,
		})
	end

	local function serve_cap_ctrl(req, class, id, verb, cap_entry)
		if not cap_entry or cap_entry.alive == false then
			fail_request(req, 'capability unavailable', true)
			return
		end

		local reply, reply_err = dispatch_cap_ctrl(cap_entry, verb, req.payload, control_timeout_s, req)
		if not reply then
			if tostring(reply_err) == 'caller_abandoned' then return end
			log('warn', 'control_dispatch_failed', {
				err   = tostring(reply_err),
				class = class,
				id    = id,
				verb  = verb,
			})
			reply_control_failure(req, reply_err)
			return
		end

		if not req:reply(reply) then
			log('warn', 'control_reply_deliver_failed', {
				class = class,
				id    = id,
				verb  = verb,
			})
		end
	end

	local function on_cap_ctrl(req)
		if not req or type(req) ~= 'table' or type(req.topic) ~= 'table' then
			return reject_rpc(req, 'invalid_rpc_request', 'invalid rpc request')
		end

		local route, class, id, verb, source = parse_cap_ctrl_topic(req.topic)
		if not route then
			return reject_rpc(req, 'invalid_cap_rpc_route', 'invalid capability rpc route', { topic = req.topic })
		end
		if not class_valid(class) then
			return reject_rpc(req, 'invalid_cap_class', 'invalid capability class', { class = tostring(class) })
		end
		if not id_valid(id) then
			return reject_rpc(req, 'invalid_cap_id', 'invalid capability id', { class = tostring(class), id = tostring(id) })
		end
		if type(verb) ~= 'string' or verb == '' then
			return reject_rpc(req, 'invalid_control_verb', 'invalid control verb', {
				class = tostring(class),
				id    = tostring(id),
				verb  = tostring(verb),
			})
		end

		local cap_entry = registry:get_cap(class, id)
		if not cap_entry or cap_entry.alive == false then
			return reject_rpc(req, 'control_capability_unavailable', 'capability unavailable', {
				class = class,
				id    = id,
				verb  = verb,
				route = route,
			})
		end

		if route == 'raw-host' and (cap_entry.source_kind ~= 'host' or cap_entry.source ~= source) then
			return reject_rpc(req, 'raw_capability_route_unavailable', 'raw capability route unavailable', {
				class  = class,
				id     = id,
				verb   = verb,
				source = tostring(source),
			})
		end

		if not cap_entry.inst.offerings[verb] then
			return reject_rpc(req, 'control_verb_unavailable', 'control verb unavailable', {
				class = class,
				id    = id,
				verb  = verb,
			})
		end

		spawn_service_worker('cap_ctrl', req, function()
			serve_cap_ctrl(req, class, id, verb, cap_entry)
		end)
	end

	local function on_cap_emit(emit)
		if getmetatable(emit) ~= types.Emit then
			log('warn', 'invalid_emit_message')
			return
		end

		local entry = registry:get_cap(emit.class, emit.id)
		if not entry then
			log('warn', 'cap_emit_missing_capability', {
				class = tostring(emit.class),
				id    = tostring(emit.id),
				mode  = tostring(emit.mode),
				key   = tostring(emit.key),
			})
			return
		end

		if emit.mode == 'event' then
			publish_cap_event(entry, emit.class, emit.id, emit.key, emit.data)
			return
		end

		if emit.mode == 'state' then
			retain_cap_state(entry, emit.class, emit.id, emit.key, emit.data)
			return
		end

		if emit.mode == 'meta' then
			entry.meta_fields[emit.key] = emit.data
			retain_cap_meta(entry, emit.class, emit.id)
			return
		end

		log('warn', 'cap_emit_unhandled_mode', {
			class = tostring(emit.class),
			id    = tostring(emit.id),
			mode  = tostring(emit.mode),
			key   = tostring(emit.key),
		})
	end

	local function on_device_event(device_event)
		if getmetatable(device_event) ~= types.DeviceEvent then
			log('warn', 'invalid_device_event_message')
			return
		end

		if device_event.event_type == 'added' then
			local dev_inst, dev_err = types.new.Device(
				device_event.class,
				device_event.id,
				device_event.meta,
				device_event.capabilities
			)
			if not dev_inst then
				log('warn', 'device_instance_invalid', {
					err   = tostring(dev_err),
					class = device_event.class,
					id    = device_event.id,
				})
				return
			end
			register_device(device_event.event_type, dev_inst)
			if device_event.ready_cond then
				device_event.ready_cond:signal()
			end
			return
		end

		if device_event.event_type == 'removed' then
			local dev_inst = registry:get_device(device_event.class, device_event.id)
			if not dev_inst then
				log('warn', 'device_missing', { class = device_event.class, id = device_event.id })
				return
			end
			unregister_device(device_event.event_type, dev_inst)
			return
		end

		log('warn', 'device_event_unhandled', {
			class      = device_event.class,
			id         = device_event.id,
			event_type = device_event.event_type,
		})
	end

	local function start_manager(name, manager)
		local valid, valid_err = validate_strict_manager(name, manager)
		if not valid then
			error(valid_err, 0)
		end

		local manager_logger = Logger.new(obs_emitter, {
			service   = svc.name,
			component = 'manager',
			manager   = name,
		})

		return perform(manager_call_with_timeout_op(
			name,
			manager,
			'start',
			manager_start_timeout_s,
			manager_logger,
			dev_ev_ch,
			cap_emit_ch,
			conn
		))
	end

	local function apply_manager_config(name, manager, manager_config)
		return perform(manager_call_with_timeout_op(
			name,
			manager,
			'apply_config',
			manager_apply_timeout_s,
			manager_config
		))
	end

	local function on_config(config)
		svc:obs_event('config_begin', {})

		local valid, valid_err = validate_config(config)
		if not valid then
			log('warn', 'config_invalid', { err = valid_err })
			svc:obs_event('config_end', { ok = false, err = valid_err })
			return
		end

		for name, manager_config in pairs(config) do
			if name ~= 'schema' then
				if not managers[name] then
					local ok, manager = pcall(require, "services.hal.managers." .. name)
					if not ok then
						log('error', 'manager_require_failed', { manager = name, err = tostring(manager) })
					else
						local start_ok, start_err = start_manager(name, manager)
						if start_ok ~= true then
							log('error', 'manager_start_failed', { manager = name, err = tostring(start_err) })
						else
							managers[name] = manager
							svc:obs_event('manager_started', { manager = name })
						end
					end
				end

				local manager = managers[name]
				if manager then
					local ok, apply_err = apply_manager_config(name, manager, manager_config)
					if ok ~= true then
						log('error', 'manager_apply_failed', { manager = name, err = tostring(apply_err) })
					end
				end
			end
		end

		for name, manager in pairs(managers) do
			if not config[name] then
				managers[name] = nil
				svc:obs_event('manager_stopping', { manager = name, reason = 'removed_from_config' })
				shutdown_manager_async(name, manager, 'removed_from_config')
			end
		end

		svc:obs_event('config_end', { ok = true })
	end

	local function bootstrap()
		svc:obs_event('bootstrap_begin', {})

		local fs_manager = require "services.hal.managers.filesystem"
		local start_ok, start_err = start_manager('filesystem', fs_manager)

		if start_ok ~= true then
			svc:status('failed', { reason = 'filesystem manager start failed', err = tostring(start_err) })
			log('error', 'bootstrap_failed', { err = tostring(start_err), phase = 'start_filesystem_manager' })
			error("HAL bootstrap failed: Failed to start filesystem manager: " .. tostring(start_err))
		end

		local ok, cfg_err = apply_manager_config('filesystem', fs_manager, {
			{
				name = "config",
				root = os.getenv("DEVICECODE_CONFIG_DIR"),
			}
		})

		if ok ~= true then
			svc:status('failed', { reason = 'filesystem manager config failed', err = tostring(cfg_err) })
			log('error', 'bootstrap_failed', { err = tostring(cfg_err), phase = 'apply_filesystem_config' })
			error("HAL bootstrap failed: " .. tostring(cfg_err))
		end

		managers.filesystem = fs_manager
		svc:obs_event('bootstrap_end', { ok = true })
	end

	local function manager_fault_ops()
		local out = {}
		for name, manager in pairs(managers) do
			out[#out + 1] = manager_fault_watch_op(name, manager):wrap(function ()
				return name
			end)
		end
		return out
	end

	local function on_manager_fault(name)
		local manager = managers[name]
		if not manager then return end

		svc:status('degraded', { reason = 'manager_fault', manager = name })
		log('error', 'manager_fault', { manager = name })

		managers[name] = nil
		shutdown_manager_async(name, manager, 'manager_fault')
	end

	local function on_config_message(msg)
		local cfg_data = msg and msg.payload and msg.payload.data
		if type(cfg_data) == 'table' then
			on_config(cfg_data)
		else
			log('warn', 'config_bad_shape', { payload = msg and msg.payload })
		end
	end

	local config_sub

	svc:obs_state('boot', { at = svc:wall(), ts = svc:now(), state = 'entered' })
	svc:obs_log('info', 'service start() entered')
	svc:status('starting')
	svc:spawn_heartbeat(heartbeat_s, 'tick')

	service_scope:finally(function()
		local st, primary = service_scope:status()
		if st == 'failed' then
			log('error', 'scope_failed', { err = tostring(primary), status = st })
		end

		registry:terminate_caps(primary or 'scope_exit')

		for name, manager in pairs(managers) do
			local ok, err = manager_terminate(name, manager, primary or 'scope_exit')
			if ok ~= true then
				log('warn', 'manager_terminate_failed', {
					manager = name,
					reason  = tostring(primary or 'scope_exit'),
					err     = tostring(err),
				})
			end
			managers[name] = nil
		end

		if config_sub then
			config_sub:unsubscribe()
			config_sub = nil
		end

		svc:status('stopped', { reason = tostring(primary or 'scope_exit') })
		svc:obs_log('info', 'service stopped')
	end)

	bootstrap()
	svc:status('running')
	svc:obs_log('info', 'bootstrap successful')

	config_sub = conn:subscribe({ 'cfg', svc.name })
	svc:obs_log('info', { what = 'subscribed', topic = 'cfg/' .. svc.name })

	while true do
		local source, a = perform(op.named_choice({
			rpc           = op.choice(registry:rpc_ops()),
			manager_fault = op.choice(manager_fault_ops()),
			cap_emit      = cap_emit_ch:get_op(),
			device_event  = dev_ev_ch:get_op(),
			config        = config_sub:recv_op(),
		}))

		if source == 'rpc' then
			on_cap_ctrl(a)
		elseif source == 'cap_emit' then
			on_cap_emit(a)
		elseif source == 'device_event' then
			on_device_event(a)
		elseif source == 'config' then
			on_config_message(a)
		elseif source == 'manager_fault' then
			on_manager_fault(a)
		else
			log('error', 'unknown_operation_source', { source = tostring(source) })
		end
	end
end

return HalService
