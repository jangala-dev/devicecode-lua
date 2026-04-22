-- services/device.lua
--
-- Device service shell.
--
-- Responsibilities:
--   * consume retained cfg/device
--   * maintain one observer child per configured component
--   * publish retained device state under:
--       state/device/self
--       state/device/components
--       state/device/component/<name>/*
--   * expose command endpoints under:
--       cmd/device/get
--       cmd/device/component/list
--       cmd/device/component/get
--       cmd/device/component/do
--
-- Ownership split:
--   * device.lua      -> shell, publication, endpoint handling
--   * model.lua       -> config/state mutation and dirty tracking
--   * projection.lua  -> public retained payload shapes
--   * observers.lua   -> provider lifetime and failure boundary
--   * providers/*     -> concrete observation sources
--   * proxy.lua       -> op-first call helpers for status/actions
--
-- Design notes:
--   * the main shell should stay responsive; potentially blocking component
--     calls are run in helper fibres
--   * helpers report completion back to the shell over a mailbox
--   * only the shell mutates service state and publishes retained state
--   * retained publication flows through the changed pulse only

local fibers     = require 'fibers'
local pulse      = require 'fibers.pulse'
local mailbox    = require 'fibers.mailbox'
local base       = require 'devicecode.service_base'
local model      = require 'services.device.model'
local projection = require 'services.device.projection'
local observers  = require 'services.device.observers'
local proxy      = require 'services.device.proxy'

local M = {}
local SCHEMA = 'devicecode.config/device/1'

----------------------------------------------------------------------
-- Small helpers
----------------------------------------------------------------------

local function send_required(tx, value, what)
	local ok, reason = tx:send(value)
	if ok ~= true then
		error((what or 'mailbox_send_failed') .. ': ' .. tostring(reason or 'closed'), 0)
	end
end

local function spawn_required(fn, what)
	local ok, err = fibers.spawn(fn)
	if ok ~= true then
		error((what or 'spawn_failed') .. ': ' .. tostring(err or 'spawn_failed'), 0)
	end
end

----------------------------------------------------------------------
-- Shell event selection
----------------------------------------------------------------------

-- shell_state contains the live service-owned event sources:
--   * cfg_watch
--   * obs_rx
--   * work_rx
--   * self_ep / list_ep / get_ep / do_ep
--   * changed pulse and last-seen version
local function next_device_event_op(shell_state)
	return fibers.named_choice({
		cfg = shell_state.cfg_watch:recv_op(),
		obs = shell_state.obs_rx:recv_op(),
		work = shell_state.work_rx:recv_op(),
		self_req = shell_state.self_ep:recv_op(),
		list_req = shell_state.list_ep:recv_op(),
		get_req = shell_state.get_ep:recv_op(),
		do_req = shell_state.do_ep:recv_op(),
		changed = shell_state.changed:changed_op(shell_state.seen),
	})
end

----------------------------------------------------------------------
-- Publication helpers
----------------------------------------------------------------------

local function publish_component(conn, svc, state, name)
	local rec = state.components[name]
	if not rec then return end

	local ts = svc:now()
	conn:retain(projection.component_topic(name), projection.component_view(name, rec, ts))
	conn:retain(projection.component_software_topic(name), projection.software_payload(name, rec, ts))
	conn:retain(projection.component_update_topic(name), projection.update_payload(name, rec, ts))
	model.clear_component_dirty(state, name)
end

local function publish_summary(conn, svc, state)
	local ts = svc:now()
	conn:retain(projection.summary_topic(), projection.summary_payload(state, ts))
	conn:retain(projection.self_topic(), projection.self_payload(state, ts))
	model.set_summary_clean(state)
end

local function publish_dirty(conn, svc, state)
	for name in pairs(state.dirty_components) do
		publish_component(conn, svc, state, name)
	end
	if state.summary_dirty then
		publish_summary(conn, svc, state)
	end
end

----------------------------------------------------------------------
-- Observer lifecycle
----------------------------------------------------------------------

local function close_observers(observer_scopes)
	for _, child in pairs(observer_scopes) do
		child:cancel('rebuild observers')
	end
end

local function rebuild_observers(service_scope, conn, svc, state, obs_tx, observer_scopes)
	close_observers(observer_scopes)

	local next_scopes = {}
	for name, rec in pairs(state.components) do
		local child, err = observers.spawn_component(service_scope, conn, name, rec, obs_tx)
		if child then
			next_scopes[name] = child
		else
			svc:obs_log('warn', {
				what = 'observer_spawn_failed',
				component = name,
				err = tostring(err),
			})
		end
	end

	return next_scopes
end

----------------------------------------------------------------------
-- Config and observer events
----------------------------------------------------------------------

local function apply_cfg(service_scope, conn, svc, state, changed, obs_tx, observer_scopes, payload)
	local old = {}
	for name in pairs(state.components) do
		old[name] = true
	end

	model.apply_cfg(state, payload)

	for name in pairs(old) do
		if not state.components[name] then
			conn:unretain(projection.component_topic(name))
			conn:unretain(projection.component_software_topic(name))
			conn:unretain(projection.component_update_topic(name))
		end
	end

	local next_scopes = rebuild_observers(service_scope, conn, svc, state, obs_tx, observer_scopes)
	changed:signal()
	return next_scopes
end

local function handle_cfg_event(service_scope, conn, svc, state, changed, obs_tx, observer_scopes, ev, err)
	if not ev then
		svc:status('failed', { reason = tostring(err or 'cfg_watch_closed') })
		error('device cfg watch closed: ' .. tostring(err), 0)
	end

	if ev.op == 'retain' then
		return apply_cfg(service_scope, conn, svc, state, changed, obs_tx, observer_scopes, ev.payload)
	elseif ev.op == 'unretain' then
		return apply_cfg(service_scope, conn, svc, state, changed, obs_tx, observer_scopes, nil)
	end

	return observer_scopes
end

local function handle_observer_event(state, changed, ev)
	if ev and ev.tag == 'raw_changed' then
		model.note_status(state, ev.component, ev.payload)
		changed:signal()
	elseif ev and ev.tag == 'source_down' then
		model.note_source_down(state, ev.component, ev.reason)
		changed:signal()
	end
end

----------------------------------------------------------------------
-- Request helpers
----------------------------------------------------------------------

-- Helper completion events are reported back to the shell:
--   * get_done -> { tag, req, component, ok, value|err }
--   * do_done  -> { tag, req, component, ok, value|err }
--
-- Helpers are bounded units of work:
--   * spawned under the service scope
--   * execute the blocking call inside fibers.run_scope(...)
--   * never mutate shared service state directly

local function spawn_get_helper(work_tx, conn, req, name, rec, payload)
	spawn_required(function()
		local st, _report, value, err = fibers.run_scope(function()
			return proxy.fetch_status(conn, rec, payload.args or {}, payload.timeout)
		end)

		if st == 'cancelled' then
			return
		end

		if st == 'failed' then
			send_required(work_tx, {
				tag = 'get_done',
				req = req,
				component = name,
				ok = false,
				err = tostring(value or 'helper_failed'),
			}, 'device_get_done_overflow')
			return
		end

		if value == nil then
			send_required(work_tx, {
				tag = 'get_done',
				req = req,
				component = name,
				ok = false,
				err = err,
			}, 'device_get_done_overflow')
			return
		end

		send_required(work_tx, {
			tag = 'get_done',
			req = req,
			component = name,
			ok = true,
			value = value,
		}, 'device_get_done_overflow')
	end, 'device_get_helper_spawn')
end

local function spawn_do_helper(work_tx, conn, req, name, rec, action, payload)
	spawn_required(function()
		local st, _report, value, err = fibers.run_scope(function()
			return proxy.perform_action(conn, rec, action, payload.args or {}, payload.timeout)
		end)

		if st == 'cancelled' then
			return
		end

		if st == 'failed' then
			send_required(work_tx, {
				tag = 'do_done',
				req = req,
				component = name,
				ok = false,
				err = tostring(value or 'helper_failed'),
			}, 'device_do_done_overflow')
			return
		end

		if value == nil then
			send_required(work_tx, {
				tag = 'do_done',
				req = req,
				component = name,
				ok = false,
				err = err,
			}, 'device_do_done_overflow')
			return
		end

		send_required(work_tx, {
			tag = 'do_done',
			req = req,
			component = name,
			ok = true,
			value = value,
		}, 'device_do_done_overflow')
	end, 'device_do_helper_spawn')
end

----------------------------------------------------------------------
-- Endpoint handlers
----------------------------------------------------------------------

local function handle_self_req(req, err, state, svc)
	if not req then
		error('device self endpoint closed: ' .. tostring(err), 0)
	end

	req:reply({ ok = true, device = projection.self_payload(state, svc:now()) })
end

local function handle_list_req(req, err, state, svc)
	if not req then
		error('device list endpoint closed: ' .. tostring(err), 0)
	end

	local items = {}
	for name, rec in pairs(state.components) do
		items[#items + 1] = projection.component_view(name, rec, svc:now())
	end
	table.sort(items, function(x, y)
		return tostring(x.component) < tostring(y.component)
	end)

	req:reply({ ok = true, components = items })
end

local function handle_get_req(work_tx, conn, req, err, state, svc)
	if not req then
		error('device get endpoint closed: ' .. tostring(err), 0)
	end

	local payload = req.payload or {}
	local name = payload.component
	local rec = state.components[name]

	if type(name) ~= 'string' or not rec then
		req:fail('unknown_component')
		return
	end

	-- Fast path: answer from cached/raw state already observed by providers.
	if rec.raw_status ~= nil then
		req:reply(projection.component_view(name, rec, svc:now()))
		return
	end

	-- Slow path: fetch in a helper so the shell remains responsive.
	spawn_get_helper(work_tx, conn, req, name, rec, payload)
end

local function handle_do_req(work_tx, conn, req, err, state)
	if not req then
		error('device do endpoint closed: ' .. tostring(err), 0)
	end

	local payload = req.payload or {}
	local name = payload.component
	local action = payload.action
	local rec = state.components[name]

	if type(name) ~= 'string' or not rec then
		req:fail('unknown_component')
		return
	end

	spawn_do_helper(work_tx, conn, req, name, rec, action, payload)
end

local function handle_work_event(state, changed, ev, svc)
	if not ev then
		error('device work mailbox closed', 0)
	end

	if ev.tag == 'get_done' then
		local req = ev.req
		local name = ev.component
		local rec = state.components[name]

		if not req or req:done() then
			return
		end

		if not ev.ok then
			req:fail(ev.err)
			return
		end

		if not rec then
			req:fail('unknown_component')
			return
		end

		model.note_status(state, name, ev.value)
		changed:signal()
		req:reply(projection.component_view(name, rec, svc:now()))
		return
	end

	if ev.tag == 'do_done' then
		local req = ev.req
		if not req or req:done() then
			return
		end

		if not ev.ok then
			req:fail(ev.err)
		else
			req:reply(ev.value)
		end
	end
end

----------------------------------------------------------------------
-- Service shell
----------------------------------------------------------------------

function M.start(conn, opts)
	opts = opts or {}

	local service_scope = assert(fibers.current_scope())
	local svc = base.new(conn, { name = opts.name or 'device', env = opts.env })

	svc:status('starting')
	svc:spawn_heartbeat((opts.heartbeat_s or 30.0), 'tick')

	local state = model.new_state(SCHEMA)
	local changed = pulse.scoped({ close_reason = 'device service stopping' })

	local cfg_watch = conn:watch_retained({ 'cfg', 'device' }, {
		replay = true,
		queue_len = 8,
		full = 'drop_oldest',
	})

	local obs_tx, obs_rx = mailbox.new(128, { full = 'drop_oldest' })
	local work_tx, work_rx = mailbox.new(64, { full = 'reject_newest' })

	local observer_scopes = {}

	local self_ep = conn:bind({ 'cmd', 'device', 'get' }, { queue_len = 32 })
	local list_ep = conn:bind({ 'cmd', 'device', 'component', 'list' }, { queue_len = 32 })
	local get_ep = conn:bind({ 'cmd', 'device', 'component', 'get' }, { queue_len = 32 })
	local do_ep = conn:bind({ 'cmd', 'device', 'component', 'do' }, { queue_len = 32 })

	local shell_state = {
		cfg_watch = cfg_watch,
		obs_rx = obs_rx,
		work_rx = work_rx,
		self_ep = self_ep,
		list_ep = list_ep,
		get_ep = get_ep,
		do_ep = do_ep,
		changed = changed,
		seen = changed:version(),
	}

	observer_scopes = apply_cfg(service_scope, conn, svc, state, changed, obs_tx, observer_scopes, nil)

	svc:status('running')

	fibers.current_scope():finally(function()
		close_observers(observer_scopes)

		cfg_watch:unwatch()

		self_ep:unbind()
		list_ep:unbind()
		get_ep:unbind()
		do_ep:unbind()

		for name in pairs(state.components) do
			conn:unretain(projection.component_topic(name))
			conn:unretain(projection.component_software_topic(name))
			conn:unretain(projection.component_update_topic(name))
		end

		conn:unretain(projection.self_topic())
		conn:unretain(projection.summary_topic())
	end)

	while true do
		local which, a, b = fibers.perform(next_device_event_op(shell_state))

		if which == 'cfg' then
			observer_scopes = handle_cfg_event(
				service_scope, conn, svc, state, changed, obs_tx, observer_scopes, a, b
			)

		elseif which == 'obs' then
			handle_observer_event(state, changed, a)

		elseif which == 'work' then
			handle_work_event(state, changed, a, svc)

		elseif which == 'changed' then
			shell_state.seen = a or shell_state.seen
			publish_dirty(conn, svc, state)

		elseif which == 'self_req' then
			handle_self_req(a, b, state, svc)

		elseif which == 'list_req' then
			handle_list_req(a, b, state, svc)

		elseif which == 'get_req' then
			handle_get_req(work_tx, conn, a, b, state, svc)

		elseif which == 'do_req' then
			handle_do_req(work_tx, conn, a, b, state)
		end
	end
end

return M
