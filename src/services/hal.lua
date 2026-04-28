-- HAL modules
local types  = require "services.hal.types.core"
local base   = require "devicecode.service_base"
local Logger = require "services.hal.logger"

-- Fibers modules
local fibers  = require "fibers"
local op      = require "fibers.op"
local channel = require "fibers.channel"

local perform = fibers.perform
local spawn   = fibers.spawn

local SCHEMA_STANDARD = "devicecode.config/hal/1"

local DEFAULT_Q_LEN = 10

local unpack = rawget(table, 'unpack') or _G.unpack
local pack   = rawget(table, 'pack') or function (...)
	return { n = select('#', ...), ... }
end

----------------------------------------------------------------------
-- Topic helpers
----------------------------------------------------------------------

---@param class DeviceClass
---@param id DeviceId
---@return string[] topic
local function t_dev_meta(class, id)
	return { 'dev', class, id, 'meta' }
end

---@param class DeviceClass
---@param id DeviceId
---@return string[] topic
local function t_dev_state(class, id)
	return { 'dev', class, id, 'state' }
end

-- Legacy public capability discovery surface.
---@param class CapabilityClass
---@param id CapabilityId
---@return string[] topic
local function t_cap_meta(class, id)
	return { 'cap', class, id, 'meta' }
end

---@param class CapabilityClass
---@param id CapabilityId
---@return string[] topic
local function t_cap_legacy_state(class, id)
	return { 'cap', class, id, 'state' }
end

-- New curated public capability surface.
---@param class CapabilityClass
---@param id CapabilityId
---@return string[] topic
local function t_cap_status(class, id)
	return { 'cap', class, id, 'status' }
end

---@param class CapabilityClass
---@param id CapabilityId
---@param field string
---@return string[] topic
local function t_cap_state_field(class, id, field)
	return { 'cap', class, id, 'state', field }
end

---@param class CapabilityClass
---@param id CapabilityId
---@param name string
---@return string[] topic
local function t_cap_event(class, id, name)
	return { 'cap', class, id, 'event', name }
end

---@param class CapabilityClass
---@param id CapabilityId
---@param verb string
---@return string[] topic
local function t_cap_rpc(class, id, verb)
	return { 'cap', class, id, 'rpc', verb }
end

-- Raw host source surface.
---@param source string
---@return string[] topic
local function t_raw_host_source_meta(source)
	return { 'raw', 'host', source, 'meta' }
end

---@param source string
---@return string[] topic
local function t_raw_host_source_status(source)
	return { 'raw', 'host', source, 'status' }
end

-- Raw host capability surface.
---@param source string
---@param class CapabilityClass
---@param id CapabilityId
---@return string[] topic
local function t_raw_host_cap_meta(source, class, id)
	return { 'raw', 'host', source, 'cap', class, id, 'meta' }
end

---@param source string
---@param class CapabilityClass
---@param id CapabilityId
---@return string[] topic
local function t_raw_host_cap_status(source, class, id)
	return { 'raw', 'host', source, 'cap', class, id, 'status' }
end

---@param source string
---@param class CapabilityClass
---@param id CapabilityId
---@param field string
---@return string[] topic
local function t_raw_host_cap_state(source, class, id, field)
	return { 'raw', 'host', source, 'cap', class, id, 'state', field }
end

---@param source string
---@param class CapabilityClass
---@param id CapabilityId
---@param name string
---@return string[] topic
local function t_raw_host_cap_event(source, class, id, name)
	return { 'raw', 'host', source, 'cap', class, id, 'event', name }
end

---@param source string
---@param class CapabilityClass
---@param id CapabilityId
---@param verb string
---@return string[] topic
local function t_raw_host_cap_rpc(source, class, id, verb)
	return { 'raw', 'host', source, 'cap', class, id, 'rpc', verb }
end

----------------------------------------------------------------------
-- Types / helpers
----------------------------------------------------------------------

---@alias CapabilityEntry {
---  inst: Capability,
---  rpc: table<string, Endpoint>,
---  raw_rpc: table<string, Endpoint>,
---  source_kind: '"host"'|nil,
---  source: string|nil,
---  state_keys: table<string, boolean>,
---  meta_fields: table<string, any>
---}

---@class HalService
---@field name string
local HalService = {}

--- Validates class string.
---@param class CapabilityClass|DeviceClass
---@return boolean
local function class_valid(class)
	return type(class) == 'string' and class ~= ''
end

--- Validates id string or number.
---@param id CapabilityId|DeviceId
---@return boolean
local function id_valid(id)
	return (type(id) == 'string' and id ~= '') or (type(id) == 'number' and id >= 0)
end

--- Checks that HAL config is valid.
---@param config table
---@return boolean
---@return string error
local function validate_config(config)
	if type(config) ~= 'table' then
		return false, "config must be a table"
	end

	if config.schema ~= SCHEMA_STANDARD then
		return false, "config schema must be " .. SCHEMA_STANDARD
	end
	config.schema = nil

	for key, value in pairs(config) do
		if type(key) ~= 'string' then
			return false, "config keys must be strings"
		end
		if type(value) ~= 'table' then
			return false, "config values must be tables"
		end
	end

	return true, ""
end

---@param x any
---@return string
local function path_token(x)
	local s = tostring(x or '')
	s = s:gsub('[^%w%-_%.]+', '_')
	s = s:gsub('_+', '_')
	s = s:gsub('^_+', '')
	s = s:gsub('_+$', '')
	if s == '' then
		s = 'unknown'
	end
	return s
end

---@param device Device
---@return string
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
		if type(v) == 'string' and v ~= '' then
			return path_token(v)
		elseif type(v) == 'number' then
			return path_token(v)
		end
	end

	return path_token(('%s_%s'):format(tostring(device.class), tostring(device.id)))
end

---@param t table|nil
---@return table
local function shallow_copy(t)
	local out = {}
	if type(t) == 'table' then
		for k, v in pairs(t) do
			out[k] = v
		end
	end
	return out
end

---@param event_type EventType
---@return string
local function availability_state(event_type)
	if event_type == 'added' then
		return 'available'
	elseif event_type == 'removed' then
		return 'removed'
	end
	return tostring(event_type)
end

---@param event_type EventType
---@return boolean
local function availability_flag(event_type)
	return event_type == 'added'
end

---@param device Device
---@param source string
---@return table
local function raw_source_meta_payload(device, source)
	local meta = shallow_copy(device.meta)
	meta.class = device.class
	meta.id    = device.id
	meta.source = source
	return meta
end

---@param event_type EventType
---@param source string
---@param device Device
---@return table
local function raw_source_status_payload(event_type, source, device)
	return {
		state      = availability_state(event_type),
		available  = availability_flag(event_type),
		source     = source,
		class      = device.class,
		id         = device.id,
	}
end

---@param cap Capability
---@param entry CapabilityEntry
---@return table
local function public_cap_meta_payload(cap, entry)
	local out = {
		offerings = cap.offerings,
	}
	for k, v in pairs(entry.meta_fields or {}) do
		out[k] = v
	end
	return out
end

---@param event_type EventType
---@param source_kind '"host"'|nil
---@param source string|nil
---@return table
local function public_cap_status_payload(event_type, source_kind, source)
	return {
		state       = availability_state(event_type),
		available   = availability_flag(event_type),
		source_kind = source_kind,
		source      = source,
	}
end

---@param cap Capability
---@param source_kind '"host"'|nil
---@param source string|nil
---@param entry CapabilityEntry
---@return table
local function raw_cap_meta_payload(cap, source_kind, source, entry)
	local out = {
		offerings   = cap.offerings,
		source_kind = source_kind,
		source      = source,
	}
	for k, v in pairs(entry.meta_fields or {}) do
		out[k] = v
	end
	return out
end

---@param event_type EventType
---@param source_kind '"host"'|nil
---@param source string|nil
---@return table
local function raw_cap_status_payload(event_type, source_kind, source)
	return {
		state       = availability_state(event_type),
		available   = availability_flag(event_type),
		source_kind = source_kind,
		source      = source,
	}
end

---@param topic Topic
---@return string|nil route
---@return CapabilityClass|nil class
---@return CapabilityId|nil id
---@return string|nil verb
---@return string|nil source
local function parse_cap_ctrl_topic(topic)
	if topic[1] == 'cap'
		and topic[4] == 'rpc'
	then
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
-- Compatibility boundary helpers
----------------------------------------------------------------------

local function manager_is_op_only(manager)
  return manager.__op_only == true or manager.api_mode == 'op_only'
end

--- Box explicitly-allowed legacy immediate manager methods and newer `_op`
--- methods behind one local op-shaped seam.
---
--- This is a compatibility boundary local to `hal.lua`.
---
--- Rules:
---   * if <method>_op exists, it is always used
---   * otherwise, fallback to the immediate method is allowed only for an
---     explicit legacy manager/method pair in LEGACY_MANAGER_METHODS
---   * all new managers must provide `_op` methods
---
--- Contract of the returned Op:
---   ok:boolean, err_or_nil:any
---
---@param manager_name string
---@param manager any
---@param method string
---@param ... any
---@return Op
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

	-- Compatibility path for legacy managers.
	-- Important: call directly in the current scope at perform time.
	return op.guard(function ()
		local a, b = manager[method](unpack(args, 1, args.n))

		-- Legacy start() returns "" on success, or an error string.
		if method == 'start' and type(a) == 'string' and b == nil then
			if a == "" then
				return op.always(true, nil)
			end
			return op.always(false, a)
		end

		-- Some older stop() methods return nothing.
		if method == 'stop' and a == nil and b == nil then
			return op.always(true, nil)
		end

		return op.always(a, b)
	end)
end

--- Best-effort manager fault watcher across legacy and new manager styles.
---
--- Supported styles:
---   * legacy: manager.scope:fault_op()
---   * new:    manager.fault_op()
---
---@param manager_name string
---@param manager any
---@return Op
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

	if manager.scope and type(manager.scope.fault_op) == 'function' then
		return manager.scope:fault_op()
	end

	return op.never()
end

--- Build a fallback negative reply, best-effort.
---@param reason any
---@return Reply|nil
local function fallback_reply(reason)
	local reply = select(1, types.new.Reply(false, tostring(reason or 'control failed')))
	return reply
end

--- Boundary op for one capability control request.
---
--- This is intentionally local to `hal.lua`: enqueue request to the target
--- capability, await the reply, and normalise the result for the outer request
--- worker.
---
--- Return shape:
---   reply: Reply|nil
---   err  : string|nil
---
---@param cap_entry CapabilityEntry
---@param verb string
---@param payload any
---@return Op
local function dispatch_cap_ctrl_op(cap_entry, verb, payload)
	return op.guard(function ()
		local reply_ch = channel.new()
		local control_req, ctrl_req_err = types.new.ControlRequest(verb, payload, reply_ch)
		if not control_req then
			return op.always(nil, tostring(ctrl_req_err or 'invalid control request'))
		end

		-- This is a real structured sub-activity at the request boundary:
		--   1. send request to capability control channel
		--   2. await exactly one reply
		--   3. abort cleanly if the subtree fails
		return fibers.run_scope_op(function(scope)
			local which, sent_ok, stop_reason = perform(op.named_choice{
				sent = cap_entry.inst.control_ch:put_op(control_req):wrap(function()
					return true
				end),
				stop = scope:not_ok_op(),
			})

			if which == 'stop' then
				return nil, tostring(stop_reason or sent_ok or 'stopping')
			end

			if sent_ok ~= true then
				return nil, tostring(stop_reason or 'control channel closed')
			end

			local which2, reply_or_nil, reply_err_or_reason = perform(op.named_choice{
				reply = reply_ch:get_op(),
				stop  = scope:not_ok_op(),
			})

			if which2 == 'stop' then
				return nil, tostring(reply_err_or_reason or reply_or_nil or 'stopping')
			end

			if not reply_or_nil then
				return nil, tostring(reply_err_or_reason or 'reply channel closed')
			end

			return reply_or_nil, nil
		end):wrap(function(st, rep, reply, err)
			if st == 'ok' then
				return reply, err
			end
			return nil, tostring(err or reply or rep)
		end)
	end)
end

----------------------------------------------------------------------
-- Service
----------------------------------------------------------------------

--- Spawns all HAL service long running fibres.
---@param conn Connection
---@param opts any
function HalService.start(conn, opts)
	opts = opts or {}

	local svc = base.new(conn, { name = opts.name or "hal", env = opts.env })
	HalService.name = svc.name

	local service_scope = fibers.current_scope()

	local heartbeat_s = (type(opts.heartbeat_s) == 'number') and opts.heartbeat_s or 30.0

	local cap_emit_ch = channel.new(DEFAULT_Q_LEN)
	local dev_ev_ch   = channel.new(DEFAULT_Q_LEN)

	local managers     = {}
	local devices      = {}
	local capabilities = {}

	local function obs_emitter(level, payload)
		svc:obs_log(level, payload)
	end

	--- Gets the device instance or returns nil.
	---@param class DeviceClass
	---@param id DeviceId
	---@return Device?
	local function get_device(class, id)
		local class_devices = devices[class]
		if not class_devices then return nil end
		return class_devices[id]
	end

	--- Sets the device instance.
	---@param class DeviceClass
	---@param id DeviceId
	---@param device_inst Device
	---@return string? error
	local function set_device(class, id, device_inst)
		devices[class] = devices[class] or {}
		if devices[class][id] then
			return "device already exists"
		end
		devices[class][id] = device_inst
	end

	--- Removes the device instance.
	---@param class DeviceClass
	---@param id DeviceId
	---@return string? error
	local function remove_device(class, id)
		local class_devices = devices[class]
		if not class_devices or not class_devices[id] then
			return "device does not exist"
		end
		class_devices[id] = nil
	end

	--- Gets the capability entry or returns nil.
	---@param class CapabilityClass
	---@param id CapabilityId
	---@return CapabilityEntry?
	local function get_cap(class, id)
		local caps = capabilities[class]
		if not caps then return nil end
		return caps[id]
	end

	--- Sets the capability instance.
	---@param class CapabilityClass
	---@param id CapabilityId
	---@param cap_inst Capability
	---@param source_kind '"host"'|nil
	---@param source string|nil
	---@return string? error
	local function set_cap(class, id, cap_inst, source_kind, source)
		capabilities[class] = capabilities[class] or {}
		if capabilities[class][id] then
			return "capability already exists"
		end

		local entry = {
			inst        = cap_inst,
			rpc         = {},
			raw_rpc     = {},
			source_kind = source_kind,
			source      = source,
			state_keys  = {},
			meta_fields = {},
		}
		capabilities[class][id] = entry

		for offering, _ in pairs(cap_inst.offerings) do
			entry.rpc[offering] = conn:bind(t_cap_rpc(class, id, offering))

			if source_kind == 'host' and source then
				entry.raw_rpc[offering] = conn:bind(t_raw_host_cap_rpc(source, class, id, offering))
			end
		end
	end

	--- Removes the capability instance and unpublishes retained state owned here.
	---@param class CapabilityClass
	---@param id CapabilityId
	---@return string? error
	local function remove_cap(class, id)
		local caps = capabilities[class]
		if not caps or not caps[id] then
			return "capability does not exist"
		end

		local entry = caps[id]

		for _, rpc_sub in pairs(entry.rpc) do
			---@cast rpc_sub Endpoint
			rpc_sub:unbind()
		end
		for _, rpc_sub in pairs(entry.raw_rpc) do
			---@cast rpc_sub Endpoint
			rpc_sub:unbind()
		end

		-- Unretain dynamic field state projections.
		for key, _ in pairs(entry.state_keys) do
			conn:unretain(t_cap_state_field(class, id, key))
			if entry.source_kind == 'host' and entry.source then
				conn:unretain(t_raw_host_cap_state(entry.source, class, id, key))
			end
		end

		caps[id] = nil
	end

	---@param event_type EventType
	---@param device Device
	local function retain_raw_source(event_type, device)
		local source = device_source_id(device)
		conn:retain(t_raw_host_source_status(source), raw_source_status_payload(event_type, source, device))

		if event_type == 'added' then
			conn:retain(t_raw_host_source_meta(source), raw_source_meta_payload(device, source))
		else
			conn:unretain(t_raw_host_source_meta(source))
		end
	end

	---@param event_type EventType
	---@param class CapabilityClass
	---@param id CapabilityId
	---@param entry CapabilityEntry
	local function retain_curated_cap(event_type, class, id, entry)
		conn:retain(t_cap_legacy_state(class, id), event_type)
		conn:retain(t_cap_status(class, id), public_cap_status_payload(event_type, entry.source_kind, entry.source))

		if event_type == 'added' then
			conn:retain(t_cap_meta(class, id), public_cap_meta_payload(entry.inst, entry))
		else
			conn:unretain(t_cap_meta(class, id))
		end
	end

	---@param event_type EventType
	---@param class CapabilityClass
	---@param id CapabilityId
	---@param entry CapabilityEntry
	local function retain_raw_cap(event_type, class, id, entry)
		if entry.source_kind ~= 'host' or not entry.source then
			return
		end

		conn:retain(
			t_raw_host_cap_status(entry.source, class, id),
			raw_cap_status_payload(event_type, entry.source_kind, entry.source)
		)

		if event_type == 'added' then
			conn:retain(
				t_raw_host_cap_meta(entry.source, class, id),
				raw_cap_meta_payload(entry.inst, entry.source_kind, entry.source, entry)
			)
		else
			conn:unretain(t_raw_host_cap_meta(entry.source, class, id))
		end
	end

	--- Adds a device and its capabilities to HAL and broadcasts event to bus.
	---@param event_type EventType
	---@param device Device
	local function register_device(event_type, device)
		local set_err = set_device(device.class, device.id, device)
		if set_err then
			svc:obs_log('warn', {
				what  = 'register_device_skipped',
				err   = set_err,
				class = device.class,
				id    = device.id,
			})
			return
		end

		local source_kind = 'host'
		local source      = device_source_id(device)

		retain_raw_source(event_type, device)

		for _, cap in ipairs(device.capabilities) do
			local cap_set_err = set_cap(cap.class, cap.id, cap, source_kind, source)
			if cap_set_err then
				svc:obs_log('warn', {
					what  = 'register_capability_skipped',
					err   = cap_set_err,
					class = cap.class,
					id    = cap.id,
				})
			else
				local entry = assert(get_cap(cap.class, cap.id), 'capability missing after set_cap')

				svc:obs_event('capability_registered', {
					class  = cap.class,
					id     = cap.id,
					source = source,
				})

				retain_curated_cap(event_type, cap.class, cap.id, entry)
				retain_raw_cap(event_type, cap.class, cap.id, entry)
			end
		end

		conn:retain(t_dev_meta(device.class, device.id), device.meta)
		conn:retain(t_dev_state(device.class, device.id), event_type)
		svc:obs_event('device_registered', {
			class      = device.class,
			id         = device.id,
			event_type = event_type,
			source     = source,
		})
	end

	--- Removes a device and its capabilities from HAL and broadcasts event to bus.
	---@param event_type EventType
	---@param device Device
	local function unregister_device(event_type, device)
		local source = device_source_id(device)

		for _, cap in ipairs(device.capabilities) do
			local entry = get_cap(cap.class, cap.id)

			if not entry then
				svc:obs_log('warn', {
					what  = 'remove_capability_skipped',
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

				retain_curated_cap(event_type, cap.class, cap.id, entry)
				retain_raw_cap(event_type, cap.class, cap.id, entry)

				local cap_remove_err = remove_cap(cap.class, cap.id)
				if cap_remove_err then
					svc:obs_log('warn', {
						what  = 'remove_capability_skipped',
						err   = cap_remove_err,
						class = cap.class,
						id    = cap.id,
					})
				end
			end
		end

		local remove_err = remove_device(device.class, device.id)
		if remove_err then
			svc:obs_log('warn', {
				what  = 'remove_device_skipped',
				err   = remove_err,
				class = device.class,
				id    = device.id,
			})
			return
		end

		conn:unretain(t_dev_meta(device.class, device.id))
		conn:retain(t_dev_state(device.class, device.id), event_type)

		retain_raw_source(event_type, device)

		svc:obs_event('device_unregistered', {
			class      = device.class,
			id         = device.id,
			event_type = event_type,
			source     = source,
		})
	end

	--- Handle one capability control request.
	---
	--- This runs in a spawned request worker fibre, which is the correct place to
	--- express the sequential control path at the request boundary:
	---   * validate/request a per-call reply channel
	---   * dispatch to the capability control channel
	---   * await one reply
	---   * deliver that reply back to the caller
	---
	---@param req Request
	---@param class CapabilityClass
	---@param id CapabilityId
	---@param verb string
	---@param cap_entry CapabilityEntry
	local function serve_cap_ctrl(req, class, id, verb, cap_entry)
		local reply, reply_err = perform(dispatch_cap_ctrl_op(cap_entry, verb, req.payload))

		if not reply then
			svc:obs_log('warn', {
				what  = 'control_dispatch_failed',
				err   = tostring(reply_err),
				class = class,
				id    = id,
				verb  = verb,
			})
			req:reply(fallback_reply(reply_err) or assert(select(1, types.new.Reply(false, 'control failed'))))
			return
		end

		local ok = req:reply(reply)
		if not ok then
			svc:obs_log('error', {
				what  = 'control_reply_deliver_failed',
				class = class,
				id    = id,
				verb  = verb,
			})
		end
	end

	--- Handles running driver functions for control requests.
	---@param req Request
	local function on_cap_ctrl(req)
		local route, class, id, verb, source = parse_cap_ctrl_topic(req.topic)
		if not route then
			return
		end

		if not class_valid(class) then
			svc:obs_log('warn', { what = 'invalid_cap_class', class = tostring(class) })
			return
		end

		if not id_valid(id) then
			svc:obs_log('warn', { what = 'invalid_cap_id', class = tostring(class), id = tostring(id) })
			return
		end

		local cap_entry = get_cap(class, id)
		-- A missing cap is not inherently a HAL error here; it may be owned elsewhere.
		if not cap_entry then
			return
		end

		if route == 'raw-host' then
			if cap_entry.source_kind ~= 'host' or cap_entry.source ~= source then
				req:fail('raw capability route unavailable')
				return
			end
		end

		if not cap_entry.inst.offerings[verb] then
			svc:obs_log('warn', {
				what  = 'control_verb_unavailable',
				class = class,
				id    = id,
				verb  = verb,
			})
			req:fail('control verb unavailable')
			return
		end

		spawn(function()
			serve_cap_ctrl(req, class, id, verb, cap_entry)
		end)
	end

	---@param emit Emit
	local function on_cap_emit(emit)
		if getmetatable(emit) ~= types.Emit then
			svc:obs_log('warn', { what = 'invalid_emit_message' })
			return
		end

		local cap_entry = get_cap(emit.class, emit.id)
		if not cap_entry then
			svc:obs_log('warn', {
				what  = 'cap_emit_missing_capability',
				class = tostring(emit.class),
				id    = tostring(emit.id),
				mode  = tostring(emit.mode),
				key   = tostring(emit.key),
			})
			return
		end

		if emit.mode == 'event' then
			conn:publish(t_cap_event(emit.class, emit.id, emit.key), emit.data)

			if cap_entry.source_kind == 'host' and cap_entry.source then
				conn:publish(
					t_raw_host_cap_event(cap_entry.source, emit.class, emit.id, emit.key),
					emit.data
				)
			end

		elseif emit.mode == 'state' then
			cap_entry.state_keys[emit.key] = true

			conn:retain(t_cap_state_field(emit.class, emit.id, emit.key), emit.data)

			if cap_entry.source_kind == 'host' and cap_entry.source then
				conn:retain(
					t_raw_host_cap_state(cap_entry.source, emit.class, emit.id, emit.key),
					emit.data
				)
			end

		elseif emit.mode == 'meta' then
			cap_entry.meta_fields[emit.key] = emit.data

			conn:retain(t_cap_meta(emit.class, emit.id), public_cap_meta_payload(cap_entry.inst, cap_entry))

			if cap_entry.source_kind == 'host' and cap_entry.source then
				conn:retain(
					t_raw_host_cap_meta(cap_entry.source, emit.class, emit.id),
					raw_cap_meta_payload(cap_entry.inst, cap_entry.source_kind, cap_entry.source, cap_entry)
				)
			end

		else
			svc:obs_log('warn', {
				what  = 'cap_emit_unhandled_mode',
				class = tostring(emit.class),
				id    = tostring(emit.id),
				mode  = tostring(emit.mode),
				key   = tostring(emit.key),
			})
		end
	end

	---@param device_event DeviceEvent
	local function on_device_event(device_event)
		if getmetatable(device_event) ~= types.DeviceEvent then
			svc:obs_log('warn', { what = 'invalid_device_event_message' })
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
				svc:obs_log('warn', {
					what  = 'device_instance_invalid',
					err   = tostring(dev_err),
					class = device_event.class,
					id    = device_event.id,
				})
				return
			end
			register_device(device_event.event_type, dev_inst)

		elseif device_event.event_type == 'removed' then
			local dev_inst = get_device(device_event.class, device_event.id)
			if not dev_inst then
				svc:obs_log('warn', {
					what  = 'device_missing',
					class = device_event.class,
					id    = device_event.id,
				})
				return
			end
			unregister_device(device_event.event_type, dev_inst)

		else
			svc:obs_log('warn', {
				what       = 'device_event_unhandled',
				class      = device_event.class,
				id         = device_event.id,
				event_type = device_event.event_type,
			})
		end
	end

	--- Uses config to set up managers.
	---@param config table
	local function on_config(config)
		svc:obs_event('config_begin', {})

		local valid, valid_err = validate_config(config)
		if not valid then
			svc:obs_log('warn', { what = 'config_invalid', err = valid_err })
			svc:obs_event('config_end', { ok = false, err = valid_err })
			return
		end

		for name, manager_config in pairs(config) do
			if not managers[name] then
				local ok, manager = pcall(require, "services.hal.managers." .. name)
				if not ok then
					svc:obs_log('error', { what = 'manager_require_failed', manager = name, err = manager })
				else
					---@cast manager any
					local manager_logger = Logger.new(obs_emitter, {
						service   = svc.name,
						component = 'manager',
						manager   = name,
					})

					local start_ok, start_err = perform(manager_call_op(name, manager, 'start', manager_logger, dev_ev_ch, cap_emit_ch))
					if start_ok ~= true then
						svc:obs_log('error', {
							what    = 'manager_start_failed',
							manager = name,
							err     = tostring(start_err),
						})
					else
						managers[name] = manager
						svc:obs_event('manager_started', { manager = name })
					end
				end
			end

			local manager = managers[name]
			if manager then
				local ok, apply_err = perform(manager_call_op(name, manager, 'apply_config', manager_config))
				if ok ~= true then
					svc:obs_log('error', {
						what    = 'manager_apply_failed',
						manager = name,
						err     = tostring(apply_err),
					})
				end
			end
		end

		for name, manager in pairs(managers) do
			if not config[name] then
				managers[name] = nil
				svc:obs_event('manager_stopping', { manager = name, reason = 'removed_from_config' })

				service_scope:spawn(function()
					local ok, stop_err = perform(manager_call_op(name, manager, 'stop'))
					if ok ~= true then
						svc:obs_log('warn', {
							what    = 'manager_stop_failed',
							manager = name,
							err     = tostring(stop_err),
						})
					end
				end)
			end
		end

		svc:obs_event('config_end', { ok = true })
	end

	--- Creates initial utilities required for loading config which will bring up the rest of HAL.
	local function bootstrap()
		svc:obs_event('bootstrap_begin', {})

		local fs_manager = require "services.hal.managers.filesystem"
		---@cast fs_manager any

		local start_ok, start_err = perform(manager_call_op(
			'filesystem',
			fs_manager,
			'start',
			Logger.new(obs_emitter, {
				service   = svc.name,
				component = 'manager',
				manager   = 'filesystem',
			}),
			dev_ev_ch,
			cap_emit_ch
		))

		if start_ok ~= true then
			svc:status('failed', { reason = 'filesystem manager start failed', err = tostring(start_err) })
			svc:obs_log('error', {
				what  = 'bootstrap_failed',
				err   = tostring(start_err),
				phase = 'start_filesystem_manager',
			})
			error("HAL bootstrap failed: Failed to start filesystem manager: " .. tostring(start_err))
		end

		local ok, cfg_err = perform(manager_call_op('filesystem', fs_manager, 'apply_config', {
			{
				name = "config",
				root = os.getenv("DEVICECODE_CONFIG_DIR"),
			}
		}))

		if ok ~= true then
			svc:status('failed', {
				reason = 'filesystem manager config failed',
				err    = tostring(cfg_err),
			})
			svc:obs_log('error', {
				what  = 'bootstrap_failed',
				err   = tostring(cfg_err),
				phase = 'apply_filesystem_config',
			})
			error("HAL bootstrap failed: " .. tostring(cfg_err))
		end

		managers["filesystem"] = fs_manager
		svc:obs_event('bootstrap_end', { ok = true })
	end

	svc:obs_state('boot', { at = svc:wall(), ts = svc:now(), state = 'entered' })
	svc:obs_log('info', 'service start() entered')
	svc:status('starting')
	svc:spawn_heartbeat(heartbeat_s, 'tick')

	service_scope:finally(function()
		local st, primary = service_scope:status()
		if st == 'failed' then
			svc:obs_log('error', { what = 'scope_failed', err = tostring(primary), status = st })
		end

		for _, class_caps in pairs(capabilities) do
			for _, cap_entry in pairs(class_caps) do
				for _, rpc_sub in pairs(cap_entry.rpc) do
					rpc_sub:unbind()
				end
				for _, rpc_sub in pairs(cap_entry.raw_rpc) do
					rpc_sub:unbind()
				end
			end
		end

		svc:status('stopped', { reason = tostring(primary or 'scope_exit') })
		svc:obs_log('info', 'service stopped')
	end)

	bootstrap()
	svc:status('running')
	svc:obs_log('info', 'bootstrap successful')

	local config_sub = conn:subscribe({ 'cfg', svc.name })
	svc:obs_log('info', { what = 'subscribed', topic = 'cfg/' .. svc.name })

	while true do
		local ops = {
			cap_emit     = cap_emit_ch:get_op(),
			device_event = dev_ev_ch:get_op(),
			config       = config_sub:recv_op(),
			stop         = service_scope:not_ok_op(),
		}

		local rpc_ops = {}
		for _, class_caps in pairs(capabilities) do
			for _, cap_entry in pairs(class_caps) do
				for _, rpc_sub in pairs(cap_entry.rpc) do
					table.insert(rpc_ops, rpc_sub:recv_op())
				end
				for _, rpc_sub in pairs(cap_entry.raw_rpc) do
					table.insert(rpc_ops, rpc_sub:recv_op())
				end
			end
		end
		if #rpc_ops > 0 then
			ops.rpc = op.choice(unpack(rpc_ops))
		end

		local manager_fault_ops = {}
		for name, manager in pairs(managers) do
			table.insert(manager_fault_ops, manager_fault_watch_op(name, manager):wrap(function ()
				return name
			end))
		end
		if #manager_fault_ops > 0 then
			ops.manager_fault = op.choice(unpack(manager_fault_ops))
		end

		local source, a, b = perform(op.named_choice(ops))

		if source == 'stop' then
			local status, reason_or_primary = a, b
			svc:obs_log('info', {
				what   = 'hal_loop_stopping',
				status = tostring(status),
				reason = tostring(reason_or_primary),
			})
			return

		elseif source == 'rpc' then
			on_cap_ctrl(a)

		elseif source == 'cap_emit' then
			on_cap_emit(a)

		elseif source == 'device_event' then
			on_device_event(a)

		elseif source == 'config' then
			local msg = a
			local cfg_data = msg and msg.payload and msg.payload.data
			if type(cfg_data) == 'table' then
				on_config(cfg_data)
			else
				svc:obs_log('warn', { what = 'config_bad_shape', payload = msg and msg.payload })
			end

		elseif source == 'manager_fault' then
			local name = a
			local manager = managers[name]
			if manager then
				svc:status('degraded', { reason = 'manager_fault', manager = name })
				svc:obs_log('error', { what = 'manager_fault', manager = name })

				managers[name] = nil
				service_scope:spawn(function()
					local ok, stop_err = perform(manager_call_op(name, manager, 'stop'))
					if ok ~= true then
						svc:obs_log('warn', {
							what    = 'manager_stop_failed',
							manager = name,
							err     = tostring(stop_err),
						})
					end
				end)
			end

		else
			svc:obs_log('error', { what = 'unknown_operation_source', source = tostring(source) })
		end
	end
end

return HalService
