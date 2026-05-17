-- services/hal/backends/network/providers/openwrt/observer.lua
--
-- Event-led observation infrastructure for the OpenWrt network provider.
--
-- Low-level OpenWrt event sources are treated as wake-up signals only.  This
-- module coalesces them by semantic subject, takes a provider-owned snapshot,
-- and emits a curated observed-state event to the HAL capability event surface.

local fibers = require 'fibers'
local sleep = require 'fibers.sleep'
local mailbox = require 'fibers.mailbox'
local socket = require 'fibers.io.socket'
local exec = require 'fibers.io.exec'
local cjson = require 'cjson.safe'
local safe = require 'coxpcall'

local perform = fibers.perform

local M = {}
local Observer = {}
Observer.__index = Observer

local function now()
	return fibers.now()
end

local function copy_plain(v, seen)
	if type(v) ~= 'table' then return v end
	if getmetatable(v) ~= nil then return v end
	seen = seen or {}
	if seen[v] then return seen[v] end
	local out = {}
	seen[v] = out
	for k, val in pairs(v) do out[copy_plain(k, seen)] = copy_plain(val, seen) end
	return out
end

local function sorted_keys(t)
	local ks = {}
	for k in pairs(t or {}) do ks[#ks + 1] = k end
	table.sort(ks, function(a, b) return tostring(a) < tostring(b) end)
	return ks
end

local function log(self, level, payload)
	local logger = self.logger
	if type(logger) == 'function' then return logger(level, payload) end
	if logger and type(logger[level]) == 'function' then return logger[level](logger, payload) end
end

local function subject_from_trigger(trigger)
	trigger = trigger or {}
	local source = trigger.source
	local env = trigger.env or trigger.payload or trigger
	local action = env.ACTION or env.action
	local iface = env.INTERFACE or env.interface
	local dev = env.DEVICE or env.DEVICENAME or env.DEVNAME or env.device or env.name

	if trigger.subject then return tostring(trigger.subject) end
	if source == 'mwan3' or trigger.kind == 'mwan3' then
		return 'mwan:' .. tostring(iface or dev or 'unknown')
	end
	if source == 'ubus' or trigger.kind == 'ubus' then
		if iface then return 'interface:' .. tostring(iface) end
		if dev then return 'device:' .. tostring(dev) end
		return 'ubus:network'
	end
	if source == 'hotplug' or trigger.kind == 'hotplug' then
		local subsystem = env.SUBSYSTEM or trigger.subsystem
		if trigger.directory == 'iface' or subsystem == 'iface' or iface then
			return 'interface:' .. tostring(iface or dev or 'unknown')
		end
		if trigger.directory == 'net' or subsystem == 'net' then
			return 'device:' .. tostring(dev or iface or 'unknown')
		end
		if trigger.directory == 'dhcp' or subsystem == 'dhcp' then return 'dhcp' end
		if trigger.directory == 'firewall' or subsystem == 'firewall' then return 'firewall' end
		if trigger.directory == 'tty' or trigger.directory == 'usb' or subsystem == 'tty' or subsystem == 'usb' then
			return 'modem-device:' .. tostring(dev or iface or 'unknown')
		end
	end
	if action == 'ifup' or action == 'ifdown' or action == 'ifupdate' or action == 'iflink' then
		return 'interface:' .. tostring(iface or dev or 'unknown')
	end
	return 'network'
end

local function classify_event(subject, trigger, observed)
	trigger = trigger or {}
	local source = trigger.source
	local env = trigger.env or trigger.payload or trigger
	local action = env.ACTION or env.action
	if subject:match('^interface:') then return 'interface_changed' end
	if subject:match('^device:') then return 'device_changed' end
	if subject:match('^mwan:') then return 'mwan_member_changed' end
	if subject == 'dhcp' then return 'dhcp_changed' end
	if subject == 'firewall' then return 'firewall_changed' end
	if source == 'snapshot' or action == 'snapshot' or observed then return 'snapshot_done' end
	return 'network_changed'
end

local function build_event(self, subject, trigger, snapshot)
	trigger = copy_plain(trigger or {})
	local observed = snapshot and snapshot.observed or nil
	local event_kind = classify_event(subject, trigger, observed)

	return {
		schema = 'devicecode.net.observation/1',
		kind = event_kind,
		event_id = tostring(self.next_event_id),
		source = trigger.source or 'snapshot',
		subject = subject,
		seq = self.next_event_id,
		monotonic = now(),
		trigger = trigger,
		observed = observed,
		snapshot = snapshot and snapshot.ok == true,
		backend = snapshot and snapshot.backend or 'openwrt',
		err = snapshot and snapshot.err or nil,
	}
end

local function decode_ubus_line(line)
	local obj = cjson.decode(line or '')
	if type(obj) ~= 'table' then return nil end
	local payload = obj['network.interface'] or obj.network_interface or obj.network
	if type(payload) ~= 'table' then
		for k, v in pairs(obj) do
			if tostring(k):match('^network%.') and type(v) == 'table' then
				payload = v
				break
			end
		end
	end
	if type(payload) ~= 'table' then payload = obj end
	return {
		source = 'ubus',
		kind = 'ubus',
		payload = payload,
		action = payload.action,
		interface = payload.interface,
		device = payload.device,
	}
end

local function normalise_hotplug_record(rec)
	if type(rec) ~= 'table' then return nil end
	local env = rec.env or rec
	return {
		source = rec.source or 'hotplug',
		kind = rec.kind or 'hotplug',
		directory = rec.directory or rec.subsystem or env.SUBSYSTEM,
		env = copy_plain(env),
	}
end

function M.new(opts)
	opts = opts or {}
	local tx, rx = mailbox.new(opts.queue_len or 64, { full = opts.full or 'drop_oldest' })
	return setmetatable({
		tx = tx,
		rx = rx,
		closed = false,
		scope = nil,
		listener = nil,
		logger = opts.logger,
		emit = opts.emit,
		snapshot = opts.snapshot,
		socket_path = opts.socket_path or '/var/run/devicecode-net-observe.sock',
		debounce_s = opts.debounce_s or 0.15,
		enable_socket = opts.enable_socket ~= false,
		enable_ubus = opts.enable_ubus == true,
		initial_snapshot = opts.initial_snapshot ~= false,
		next_event_id = 1,
		active_streams = {},
		ubus_cmd = nil,
		ubus_stream = nil,
	}, Observer), nil
end

function Observer:ingest(trigger)
	if self.closed then return false, 'observer closed' end
	return self.tx:send(trigger)
end

function Observer:emit_event(ev)
	if type(self.emit) == 'function' then
		local ok, err = safe.pcall(function() return self.emit(ev) end)
		if not ok then return nil, tostring(err) end
		if err ~= nil and err ~= true then return nil, tostring(err) end
	end
	return true, nil
end

function Observer:take_snapshot(subject, trigger)
	if type(self.snapshot) ~= 'function' then
		return { ok = false, backend = 'openwrt', err = 'snapshot callback unavailable' }
	end
	local ok, result = safe.pcall(function() return self.snapshot(subject, trigger) end)
	if not ok then return { ok = false, backend = 'openwrt', err = tostring(result) } end
	if type(result) == 'table' then return result end
	return { ok = result == true, backend = 'openwrt', result = result }
end

function Observer:flush_subject(subject, trigger)
	local snapshot = self:take_snapshot(subject, trigger)
	local ev = build_event(self, subject, trigger, snapshot)
	self.next_event_id = self.next_event_id + 1
	local ok, err = self:emit_event(ev)
	if ok ~= true then
		log(self, 'warn', { what = 'network_observer_emit_failed', err = tostring(err), subject = subject })
		return nil, err
	end
	return true, nil
end

function Observer:coalescer()
	local pending = {}
	if self.initial_snapshot then
		pending.network = { source = 'snapshot', kind = 'snapshot', action = 'initial' }
	end

	while true do
		local wait_s = nil
		local due_subject = nil
		local due_record = nil
		local t = now()

		for _, subject in ipairs(sorted_keys(pending)) do
			local rec = pending[subject]
			local due = rec.due or t
			local dt = due - t
			if dt <= 0 then
				due_subject = subject
				due_record = rec
				break
			end
			if wait_s == nil or dt < wait_s then wait_s = dt end
		end

		if due_subject then
			pending[due_subject] = nil
			self:flush_subject(due_subject, due_record.trigger)
		else
			local trigger
			if wait_s == nil then
				trigger = perform(self.rx:recv_op())
			else
				local which, val = perform(fibers.named_choice {
					event = self.rx:recv_op(),
					timer = sleep.sleep_op(wait_s),
				})
				if which == 'event' then trigger = val else trigger = false end
			end

			if trigger == nil then return end
			if trigger ~= false then
				local subject = subject_from_trigger(trigger)
				pending[subject] = {
					trigger = trigger,
					due = now() + self.debounce_s,
				}
			end
		end
	end
end

local function close_stream(st)
	if not st then return true, nil end
	if st.close then return st:close() end
	return true, nil
end

local function terminate_stream(st, reason)
	if not st then return true, nil end
	if st.terminate then
		st:terminate(reason or 'terminated')
		return true, nil
	end
	if st.close then
		-- Fallback for non-Stream-like objects.  Avoid ordinary pcall here: close()
		-- may be an Op-performing wrapper under PUC Lua.
		return st:close()
	end
	return true, nil
end

function Observer:_track_stream(st)
	if st then self.active_streams[st] = true end
	return st
end

function Observer:_untrack_stream(st)
	if st then self.active_streams[st] = nil end
end

function Observer:_stop_ubus_listener()
	local stream = self.ubus_stream
	self.ubus_stream = nil
	terminate_stream(stream, 'ubus listener stopped')

	local cmd = self.ubus_cmd
	self.ubus_cmd = nil
	if cmd and cmd.kill then pcall(function () cmd:kill() end) end
end

function Observer:ubus_listener()
	while not self.closed do
		local cmd = exec.command('ubus', 'listen', 'network.interface')
		cmd:set_stdout('pipe')
		cmd:set_stderr('stdout')
		cmd:set_shutdown_grace(0.2)
		self.ubus_cmd = cmd
		local stream, err = cmd:stdout_stream()
		if not stream then
			self.ubus_cmd = nil
			log(self, 'warn', { what = 'ubus_listen_start_failed', err = tostring(err) })
			perform(sleep.sleep_op(5.0))
		else
			self.ubus_stream = stream
			while not self.closed do
				local line, rerr = perform(stream:read_line_op())
				if line == nil then
					if rerr and not self.closed then log(self, 'warn', { what = 'ubus_listen_read_failed', err = tostring(rerr) }) end
					break
				end
				local trig = decode_ubus_line(line)
				if trig then self:ingest(trig) end
			end
			if self.ubus_stream == stream then self.ubus_stream = nil end
			if self.ubus_cmd == cmd then self.ubus_cmd = nil end
			close_stream(stream)
			pcall(function () cmd:kill() end)
			if not self.closed then perform(sleep.sleep_op(1.0)) end
		end
	end
	self:_stop_ubus_listener()
end

function Observer:handle_socket_stream(st)
	self:_track_stream(st)
	while not self.closed do
		local line = perform(st:read_line_op())
		if line == nil then break end
		local rec = cjson.decode(line)
		local trig = normalise_hotplug_record(rec)
		if trig then self:ingest(trig) end
	end
	self:_untrack_stream(st)
	close_stream(st)
end

function Observer:socket_server()
	pcall(os.remove, self.socket_path)
	local s, err = socket.listen_unix(self.socket_path, { ephemeral = true })
	if not s then
		log(self, 'warn', { what = 'hotplug_socket_listen_failed', path = self.socket_path, err = tostring(err) })
		return
	end
	self.listener = s
	log(self, 'info', { what = 'hotplug_socket_listening', path = self.socket_path })
	while not self.closed do
		local st, aerr = perform(s:accept_op())
		if st then
			self.scope:spawn(function () self:handle_socket_stream(st) end)
		elseif aerr and not self.closed then
			log(self, 'warn', { what = 'hotplug_socket_accept_failed', err = tostring(aerr) })
			perform(sleep.sleep_op(0.5))
		end
	end
	s:close()
end

function Observer:start(scope)
	if self.closed then return nil, 'observer closed' end
	if self.scope then return true, nil end
	if type(scope) ~= 'table' then return nil, 'scope required' end
	local child, err = scope:child()
	if not child then return nil, err or 'observer scope create failed' end
	self.scope = child
	child:spawn(function () self:coalescer() end)
	if self.enable_socket then child:spawn(function () self:socket_server() end) end
	if self.enable_ubus then child:spawn(function () self:ubus_listener() end) end
	return true, nil
end

function Observer:terminate(reason)
	if self.closed then return true, nil end
	self.closed = true
	self.tx:close(reason or 'observer terminated')
	self:_stop_ubus_listener()
	for st in pairs(self.active_streams) do terminate_stream(st, reason or 'observer terminated') end
	self.active_streams = {}
	if self.listener and self.listener.close then self.listener:close() end
	if self.scope then self.scope:cancel(reason or 'observer terminated') end
	pcall(os.remove, self.socket_path)
	return true, nil
end

return M
