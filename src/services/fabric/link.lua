-- services/fabric/link.lua
--
-- Link-scope supervisor and standard composition.
--
-- A Fabric link owns component lifetimes and link-local policy:
--
--   * a link scope owns component lifetimes
--   * components are started as scoped work
--   * component completion is reported as data
--   * the link coordinator decides policy
--   * the coordinator has one suspending control point
--   * model updates are non-yielding
--
-- Protocol, transport, bridge, and transfer behaviour remain in their named
-- semantic owners; this module composes and supervises them.

local fibers       = require 'fibers'
local mailbox      = require 'fibers.mailbox'
local scoped_work  = require 'devicecode.support.scoped_work'
local queue        = require 'devicecode.support.queue'
local service_events = require 'devicecode.support.service_events'
local model_mod    = require 'services.fabric.model'
local io_mod       = require 'services.fabric.io'
local bridge_mod   = require 'services.fabric.bridge'
local bus_adapter  = require 'services.fabric.bus_adapter'
local session_mod  = require 'services.fabric.session'
local transfer_mod = require 'services.fabric.transfer'
local state_mod    = require 'services.fabric.state'
local resource     = require 'devicecode.support.resource'
local tablex       = require 'shared.table'

local M = {}

local Link = {}
Link.__index = Link

local DEFAULT_DONE_QUEUE = 32

local shallow_copy = tablex.shallow_copy

local function copy_component_entry(c)
	local out = shallow_copy(c)

	if type(out.result) == 'table' then
		out.result = shallow_copy(out.result)
	end

	return out
end

local function copy_components(components)
	local out = {}

	for name, c in pairs(components or {}) do
		out[name] = copy_component_entry(c)
	end

	return out
end

local function copy_snapshot(s)
	local out = shallow_copy(s or {})
	out.components = copy_components(out.components)
	return out
end

local function shallow_value_equal(a, b)
	if a == b then return true end
	if type(a) ~= 'table' or type(b) ~= 'table' then return false end

	for k, v in pairs(a) do
		if b[k] ~= v then
			return false
		end
	end

	for k in pairs(b) do
		if a[k] == nil then
			return false
		end
	end

	return true
end

local function snapshots_equal(a, b)
	if a == b then return true end
	if type(a) ~= 'table' or type(b) ~= 'table' then return false end

	if a.link_id ~= b.link_id then return false end
	if a.link_generation ~= b.link_generation then return false end
	if a.state ~= b.state then return false end
	if a.completed ~= b.completed then return false end
	if a.total ~= b.total then return false end
	if a.reason ~= b.reason then return false end

	local ac = a.components or {}
	local bc = b.components or {}

	for name, av in pairs(ac) do
		local bv = bc[name]
		if type(bv) ~= 'table' then return false end

		if av.status ~= bv.status then return false end
		if av.primary ~= bv.primary then return false end
		if not shallow_value_equal(av.result, bv.result) then return false end
	end

	for name in pairs(bc) do
		if ac[name] == nil then return false end
	end

	return true
end

local function component_list(params)
	local list = params.components
	if type(list) ~= 'table' then
		error('fabric.link: components array required', 3)
	end

	local out = {}

	for _, c in ipairs(list) do
		if type(c) ~= 'table' then
			error('fabric.link: component entry must be a table', 3)
		end

		if type(c.name) ~= 'string' or c.name == '' then
			error('fabric.link: component.name must be a non-empty string', 3)
		end

		if type(c.run) ~= 'function' then
			error('fabric.link: component.run must be a function', 3)
		end

		if out[c.name] ~= nil then
			error('fabric.link: duplicate component name: ' .. c.name, 3)
		end

		out[#out + 1] = c
		out[c.name] = c
	end

	if #out == 0 then
		error('fabric.link: at least one component required', 3)
	end

	return out
end

local function initial_snapshot(link_id, link_generation, components)
	local cs = {}

	for _, c in ipairs(components) do
		cs[c.name] = {
			status = 'starting',
		}
	end

	return {
		link_id         = link_id,
		link_generation = link_generation,
		state           = 'starting',
		total           = #components,
		completed       = 0,
		components      = cs,
	}
end

local function public_snapshot(self)
	return self._model:snapshot()
end

local function publish_state(self)
	return state_mod.admit_link_snapshot_now(
		self._state_tx,
		self._link_id,
		self._link_generation,
		public_snapshot(self),
		'fabric_link_state_admit_failed'
	)
end

local function publish_state_checked(self)
	local ok, err = publish_state(self)
	if ok ~= true then
		error(err or 'fabric_link_state_admit_failed', 0)
	end
	return true
end

local function set_state(self, state, reason)
	local changed = self._model:update(function (s)
		s.state = state
		s.reason = reason
	end)

	if changed then
		publish_state_checked(self)
	end
end

local function advance_completion_state(s)
	if s.state == 'failed' or s.state == 'cancelling' then
		return
	end

	if s.completed >= s.total then
		s.state = 'completed'
	else
		s.state = 'running'
	end
end

local function record_component_done(self, ev)
	local accepted = false

	local changed = self._model:update(function (s)
		local c = s.components[ev.component]

		if not c then
			return
		end

		if c.status == 'ok' or c.status == 'failed' or c.status == 'cancelled' then
			return
		end

		c.status = ev.status

		if ev.status == 'ok' then
			if type(ev.result) == 'table' then
				c.result = shallow_copy(ev.result)
			else
				c.result = ev.result
			end
		else
			c.primary = ev.primary
		end

		s.completed = (s.completed or 0) + 1
		advance_completion_state(s)
		accepted = true
	end)

	if changed then
		publish_state_checked(self)
	end

	return accepted
end

local function default_policy(_, ev)
	if ev.kind ~= 'component_done' or ev.status == 'ok' then
		return { action = 'continue' }
	end

	if ev.status == 'failed' then
		return {
			action = 'fail',
			reason = ('component %s failed: %s'):format(
				tostring(ev.component),
				tostring(ev.primary or 'failed')
			),
		}
	end

	if ev.status == 'cancelled' then
		return {
			action = 'fail',
			reason = ('component %s cancelled unexpectedly: %s'):format(
				tostring(ev.component),
				tostring(ev.primary or 'cancelled')
			),
		}
	end

	return {
		action = 'fail',
		reason = ('component %s ended with invalid status: %s'):format(
			tostring(ev.component),
			tostring(ev.status)
		),
	}
end

local function apply_policy(self, ev)
	local decision = (self._policy or default_policy)(self, ev) or { action = 'continue' }
	local action = decision.action or 'continue'

	if action == 'continue' then
		return
	end

	if action == 'fail' then
		local reason = decision.reason or 'link policy failure'
		set_state(self, 'failed', reason)
		error(reason, 0)
	end

	if action == 'cancel' then
		local reason = decision.reason or 'link policy cancellation'
		set_state(self, 'cancelling', reason)

		for _, h in pairs(self._components) do
			if h and h.cancel then
				h:cancel(reason)
			end
		end

		return
	end

	error('fabric.link: unknown policy action: ' .. tostring(action), 0)
end

local function make_component_identity(self, component)
	return {
		kind            = 'component_done',
		link_id         = self._link_id,
		link_generation = self._link_generation,
		component       = component.name,
	}
end

local function make_link_caps(self, component)
	return {
		link_id         = self._link_id,
		link_generation = self._link_generation,
		component       = component and component.name or nil,

		snapshot = public_snapshot(self),
	}
end

local function start_component(self, component)
	local handle, err = scoped_work.start {
		lifetime_scope = self._scope,
		reaper_scope   = self._scope,
		report_scope   = self._scope,

		identity = make_component_identity(self, component),

		run = function (component_scope)
			return component.run(component_scope, make_link_caps(self, component))
		end,

		report = service_events.reporter_for(
			self._done_tx,
			make_component_identity(self, component),
			{ label = 'link_component_completion_report_failed' }
		),
	}

	if not handle then
		return nil, err
	end

	self._components[component.name] = handle
	return handle, nil
end

local function start_all_components(self, components)
	for _, component in ipairs(components) do
		local h, err = start_component(self, component)

		if not h then
			set_state(self, 'failed', err or 'component_start_failed')
			error(err or 'component_start_failed', 0)
		end
	end

	set_state(self, 'running')
end

local function close_state_tx(self, reason)
	if not self._state_tx_owned or self._state_tx_closed then
		return true, nil
	end

	self._state_tx_closed = true
	if self._state_tx and type(self._state_tx.close) == 'function' then
		self._state_tx:close(reason or 'fabric link state projector closed')
	end
	return true, nil
end

local function start_state_projector(self, params)
	local rx = params.state_projector_rx
	if rx == nil then
		self._state_projector_done = true
		return true, nil
	end

	local handle, err = scoped_work.start {
		lifetime_scope = self._scope,
		reaper_scope   = self._scope,
		report_scope   = self._scope,

		identity = {
			kind            = 'state_projector_done',
			link_id         = self._link_id,
			link_generation = self._link_generation,
		},

		run = function (projector_scope)
			return state_mod.run_projector(projector_scope, {
				conn = params.state_projector_conn,
				state_rx = rx,
			})
		end,

		report = service_events.reporter_for(
			self._done_tx,
			{
				kind = 'state_projector_done',
				link_id = self._link_id,
				link_generation = self._link_generation,
				source = 'fabric_link_state_projector',
				source_id = self._link_id,
			},
			{ label = 'link_state_projector_completion_report_failed' }
		),
	}

	if not handle then
		return nil, err or 'state_projector_start_failed'
	end

	self._state_projector_handle = handle
	self._state_projector_done = false
	return true, nil
end

local function components_complete(self)
	local snap = public_snapshot(self)
	return (snap.completed or 0) >= (snap.total or 0)
end

local function maybe_close_state_projector(self)
	if components_complete(self) then
		close_state_tx(self, 'fabric link components completed')
	end
end

local function handle_state_projector_done(self, ev)
	if ev.link_id ~= self._link_id or ev.link_generation ~= self._link_generation then
		return
	end

	self._state_projector_done = true
	self._state_projector_handle = nil

	if ev.status ~= 'ok' then
		local reason = ev.primary or ev.status or 'state_projector_failed'
		set_state(self, 'failed', reason)
		error(reason, 0)
	end
end

local function next_event_op(self)
	return self._done_rx:recv_op():wrap(function (ev)
		if ev == nil then
			return {
				kind = 'done_queue_closed',
			}
		end

		return ev
	end)
end

local function coordinator_loop(self)
	while not self._complete do
		local ev = fibers.perform(next_event_op(self))

		-- Own-scope cancellation is not a service event. Scope-aware perform
		-- exits through the scope machinery before this branch is reached.

		if ev.kind == 'done_queue_closed' then
			error('link completion queue closed', 0)
		end

		if ev.kind == 'component_done' then
			if ev.link_id ~= self._link_id or ev.link_generation ~= self._link_generation then
				-- Stale or foreign completion. Ignore it.
			else
				local accepted = record_component_done(self, ev)

				if accepted then
					apply_policy(self, ev)
				end
			end
		elseif ev.kind == 'state_projector_done' then
			handle_state_projector_done(self, ev)
		else
			error('fabric.link: unknown event kind: ' .. tostring(ev.kind), 0)
		end

		maybe_close_state_projector(self)
		if components_complete(self) and self._state_projector_done then
			self._complete = true
		end
	end

	return {
		link_id         = self._link_id,
		link_generation = self._link_generation,
		snapshot        = public_snapshot(self),
	}
end

--------------------------------------------------------------------------------
-- Composed link wiring
--------------------------------------------------------------------------------

local DEFAULT_FRAME_QUEUE = 32
local DEFAULT_OUTBOUND_QUEUE = 32

local function qlen(params, name, default)
	local queues = params.queues or {}
	if type(queues) ~= 'table' then
		error('fabric.link.run_composed: queues must be a table', 3)
	end

	local n = queues[name]
	if n == nil then
		return default
	end

	if type(n) ~= 'number' or n <= 0 or n % 1 ~= 0 then
		error('fabric.link.run_composed: queues.' .. tostring(name) .. ' must be a positive integer', 3)
	end

	return n
end

local function closed_rx(reason)
	local tx, rx = mailbox.new(1, { full = 'reject_newest' })
	tx:close(reason or 'closed')
	return rx
end

local function has_terminate_contract(x)
	return type(x) == 'table' and type(x.terminate) == 'function'
end

local function is_frame_transport(x)
	return type(x) == 'table'
		and type(x.read_frame_op) == 'function'
		and type(x.write_frame_op) == 'function'
		and has_terminate_contract(x)
end

local function require_transport(scope, transport)
	if not is_frame_transport(transport) then
		error('fabric.link.run_composed: transport must be a Fabric frame transport', 3)
	end

	scope:finally(function (_, status, primary)
		resource.terminate_checked(
			transport,
			primary or status or 'fabric link closed',
			'fabric transport cleanup failed'
		)
	end)

	return transport
end

local function bus_conn_from(params, service_caps)
	return params.conn or (service_caps and service_caps.conn)
end

local function bridge_params_from(params, local_rx, session_rx, outbound, bus_tx, state_tx, service_caps)
	local b = shallow_copy(params.bridge or {})

	b.link_id = params.link_id
	b.link_generation = params.link_generation
	b.local_rx = local_rx
	b.session_rx = session_rx
	b.outbound = outbound
	b.conn = bus_conn_from(params, service_caps)
	b.bus_tx = bus_tx
	b.state_tx = state_tx
	b.component_name = 'rpc_bridge'

	return b
end

local function transfer_params_from(params, admission_rx, session_rx, outbound, state_tx)
	local t = shallow_copy(params.transfer or {})

	t.manager_id = t.manager_id or (params.link_id .. ':transfer')
	t.link_id = params.link_id
	t.link_generation = params.link_generation
	t.admission_rx = admission_rx
	t.session_rx = session_rx
	t.outbound = outbound
	t.state_tx = state_tx
	t.component_name = 'transfer_manager'
	t.receive_targets = t.receive_targets or params.receive_targets

	return t
end

-- Build the standard Fabric link component set around an already-open frame
-- transport.
--
-- The composed link has these components:
--   reader           transport -> raw inbound frame queue
--   session          hello/ack/ping/pong, liveness and semantic frame tagging
--   writer           control/rpc/bulk outbound lanes -> transport
--   rpc_bridge       local/RPC-frame semantic events -> session outbound gate
--   transfer_manager transfer slot admission and transfer-frame lane -> session outbound gate
--
-- The reader owns closing the raw inbound frame queue. Session owns the raw
-- outbound writer lanes and exposes only generation-checked admission to bridge
-- and transfer. This lets dependent components finish naturally without the link
-- coordinator joining inline or performing cross-component waits.
function M.composed_components(scope, params, service_caps)
	params = params or {}

	params.link_id = params.link_id or 'link'
	params.link_generation = params.link_generation or 1

	local transport = require_transport(scope, params.transport)

	local state_conn = bus_conn_from(params, service_caps)
	local state_tx
	if state_conn ~= nil then
		local projector_tx, projector_rx = state_mod.new_queue(qlen(params, 'state', DEFAULT_OUTBOUND_QUEUE))
		state_tx = projector_tx
		params.state_tx = state_tx
		params.state_projector_conn = state_conn
		params.state_projector_rx = projector_rx
		params.state_tx_owned = true
	else
		state_tx = params.state_tx
	end
	local read_frame_op = function ()
		return transport:read_frame_op()
	end
	local write_frame_op = function (frame)
		return transport:write_frame_op(frame)
	end
	local flush_op
	if type(transport.flush_op) == 'function' then
		flush_op = function ()
			return transport:flush_op()
		end
	end

	local inbound_frame_tx, inbound_frame_rx = mailbox.new(
		qlen(params, 'frame_in', DEFAULT_FRAME_QUEUE),
		{ full = 'reject_newest' }
	)

	local bridge_session_tx, bridge_session_rx = mailbox.new(
		qlen(params, 'rpc_in', DEFAULT_FRAME_QUEUE),
		{ full = 'reject_newest' }
	)

	local transfer_session_tx, transfer_session_rx = mailbox.new(
		qlen(params, 'xfer_in', DEFAULT_FRAME_QUEUE),
		{ full = 'reject_newest' }
	)

	local outbound_control_tx, outbound_control_rx = mailbox.new(
		qlen(params, 'tx_control', DEFAULT_OUTBOUND_QUEUE),
		{ full = 'reject_newest' }
	)

	local outbound_rpc_tx, outbound_rpc_rx = mailbox.new(
		qlen(params, 'tx_rpc', DEFAULT_OUTBOUND_QUEUE),
		{ full = 'reject_newest' }
	)

	local outbound_bulk_tx, outbound_bulk_rx = mailbox.new(
		qlen(params, 'tx_bulk', DEFAULT_OUTBOUND_QUEUE),
		{ full = 'reject_newest' }
	)

	local outbound_gate = session_mod.new_outbound_gate {
		tx_control = outbound_control_tx,
		tx_rpc     = outbound_rpc_tx,
		tx_bulk    = outbound_bulk_tx,
	}

	local local_rx = params.local_rx
	if local_rx == nil and bus_conn_from(params, service_caps) == nil then
		local_rx = closed_rx('no local fabric events')
	end

	local admission_rx = params.transfer_admission_rx or closed_rx('no transfer slot admissions')

	local session_cfg = params.session or {}
	local reader_cfg = params.reader or {}
	local writer_cfg = params.writer or {}
	if type(session_cfg) ~= 'table' then
		error('fabric.link.run_composed: session must be a table', 2)
	end
	if type(reader_cfg) ~= 'table' then
		error('fabric.link.run_composed: reader must be a table', 2)
	end
	if type(writer_cfg) ~= 'table' then
		error('fabric.link.run_composed: writer must be a table', 2)
	end

	local components = {}

	components[#components + 1] = {
		name = 'reader',
		run = function (component_scope)
			component_scope:finally(function ()
				inbound_frame_tx:close('reader closed')
			end)

			return io_mod.run_reader(component_scope, {
				read_frame_op = read_frame_op,
				downstream_tx = inbound_frame_tx,
			})
		end,
	}

	components[#components + 1] = {
		name = 'session',
		run = function (component_scope)
			component_scope:finally(function ()
				bridge_session_tx:close('session closed')
				transfer_session_tx:close('session closed')
			end)

			return session_mod.run(component_scope, {
				link_id = params.link_id,
				link_generation = params.link_generation,
				peer_id = params.peer_id,
				local_node = session_cfg.local_node,
				local_sid = session_cfg.local_sid,
				identity_claim = session_cfg.identity_claim,
				auth_claim = session_cfg.auth_claim,
				frame_rx = inbound_frame_rx,
				tx_control = outbound_control_tx,
				outbound = outbound_gate,
				rpc_tx = bridge_session_tx,
				transfer_tx = transfer_session_tx,
				hello_interval_s = session_cfg.hello_interval_s,
				ping_interval_s = session_cfg.ping_interval_s,
				liveness_timeout_s = session_cfg.liveness_timeout_s,
				bad_frame_limit = reader_cfg.bad_frame_limit,
				bad_frame_window_s = reader_cfg.bad_frame_window_s,
				state_tx = state_tx,
				component_name = 'session',
			})
		end,
	}

	components[#components + 1] = {
		name = 'writer',
		run = function (component_scope)
			return io_mod.run_lane_writer(component_scope, {
				control_rx = outbound_control_rx,
				rpc_rx = outbound_rpc_rx,
				bulk_rx = outbound_bulk_rx,
				write_frame_op = write_frame_op,
				flush_op = flush_op,
				flush_each = params.flush_each,
				rpc_quota = writer_cfg.rpc_quota,
				bulk_quota = writer_cfg.bulk_quota,
			})
		end,
	}

	components[#components + 1] = {
		name = 'rpc_bridge',
		run = function (component_scope)
			local runtime
			local bus_tx
			local bridge_local_rx = local_rx
			local bridge_conn = bus_conn_from(params, service_caps)

			if bridge_local_rx == nil and bridge_conn ~= nil then
				runtime = bus_adapter.local_runtime(component_scope, bridge_conn, params.bridge or params)
				bridge_local_rx = runtime.local_rx
				bus_tx = runtime.command_tx
			end

			local bp = bridge_params_from(
				params,
				bridge_local_rx,
				bridge_session_rx,
				outbound_gate,
				bus_tx,
				state_tx,
				service_caps
			)

			local result = bridge_mod.run(component_scope, bp)
			if runtime ~= nil then
				local ok, err = runtime:terminate('bridge completed')
				if ok ~= true then
					error(err or 'fabric bus adapter cleanup failed', 0)
				end
			end
			return result
		end,
	}

	components[#components + 1] = {
		name = 'transfer_manager',
		run = function (component_scope)
			local tp = transfer_params_from(
				params,
				admission_rx,
				transfer_session_rx,
				outbound_gate,
				state_tx
			)
			return transfer_mod.run(component_scope, tp)
		end,
	}

	return components
end

--- Run a standard Fabric link composition.
function M.run_composed(scope, params, service_caps)
	if type(scope) ~= 'table' then
		error('fabric.link.run_composed: scope required', 2)
	end
	if type(params) ~= 'table' then
		error('fabric.link.run_composed: params table required', 2)
	end

	local run_params = shallow_copy(params)
	run_params.link_id = run_params.link_id or 'link'
	run_params.link_generation = run_params.link_generation or 1
	run_params.components = M.composed_components(scope, run_params, service_caps)

	return M.run(scope, run_params)
end

--- Run a Fabric link inside an already-created link scope.
---
--- params:
---   link_id?: string
---   link_generation?: integer
---   components: array of { name: string, run: function(scope, link_caps) -> table }
---   policy?: function(link, ev) -> { action = ... }
---   done_queue_len?: integer
---   state_tx?: mailbox sender-like object
---   state_projector_conn?: Connection
---   state_projector_rx?: mailbox receiver-like object
---   state_tx_owned?: boolean
---
---@param scope Scope
---@param params table
---@return table result
function M.run(scope, params)
	if type(scope) ~= 'table' then
		error('fabric.link.run: scope required', 2)
	end

	if type(params) ~= 'table' then
		error('fabric.link.run: params table required', 2)
	end

	local components = component_list(params)

	local link_id = params.link_id or 'link'
	local link_generation = params.link_generation or 1

	local initial = initial_snapshot(link_id, link_generation, components)
	local model = model_mod.new(initial, {
		copy = copy_snapshot,
		equals = snapshots_equal,
		label = 'fabric.link',
	})

	scope:finally(function (_, status, primary)
		model:terminate(primary or status or 'link closed')
	end)

	local done_tx, done_rx = mailbox.new(
		params.done_queue_len or math.max(DEFAULT_DONE_QUEUE, #components + 4),
		{ full = 'reject_newest' }
	)

	scope:finally(function ()
		done_tx:close('link closed')
	end)

	local self = setmetatable({
		_scope                  = scope,
		_link_id                = link_id,
		_link_generation        = link_generation,
		_model                  = model,
		_state_tx               = params.state_tx,
		_state_tx_owned         = not not params.state_tx_owned,
		_state_tx_closed        = false,
		_state_projector_handle = nil,
		_state_projector_done   = params.state_projector_rx == nil,
		_done_tx                = done_tx,
		_done_rx                = done_rx,
		_policy                 = params.policy,
		_components             = {},
		_complete               = false,
	}, Link)

	scope:finally(function (_, status, primary)
		close_state_tx(self, primary or status or 'link closed')
	end)

	local state_ok, state_err = start_state_projector(self, params)
	if state_ok ~= true then
		set_state(self, 'failed', state_err or 'state_projector_start_failed')
		error(state_err or 'state_projector_start_failed', 0)
	end

	publish_state_checked(self)

	start_all_components(self, components)

	return coordinator_loop(self)
end

return M
