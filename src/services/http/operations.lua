-- services/http/operations.lua
-- Capability operation validation and worker bodies. Coordinator code calls this
-- module to admit named scoped work; workers may perform Ops inside their own
-- scopes.

local fibers = require 'fibers'

local client = require 'services.http.client'
local websocket = require 'services.http.websocket'
local policy = require 'services.http.policy'
local listener_owner = require 'services.http.listener_owner'
local operation_owner = require 'services.http.operation_owner'
local service_events = require 'devicecode.support.service_events'

local M = {}
local perform = fibers.perform

local function copy(t)
	local out = {}
	for k, v in pairs(t or {}) do out[k] = v end
	return out
end


local function event_port_from_submit(tx, submit, identity, default_label)
	local events_port = service_events.port(tx, identity, {
		label = default_label or 'http_event_report_failed',
	})
	return {
		emit_required = function (_, ev, label)
			if type(ev) ~= 'table' then return nil, 'invalid_event' end
			return submit(events_port:event(ev), label or default_label or 'http_event_report_failed')
		end,
		event = function (_, ev, attrs)
			return events_port:event(ev, attrs)
		end,
		identity = function ()
			return events_port:identity()
		end,
	}
end

local function terminate_handle(h, reason)
	if h and type(h.terminate) == 'function' then return h:terminate(reason) end
	return true
end

local function assert_local(service, req)
	return policy.require_local_origin(req and req.origin)
end

local function policy_opts(service)
	return service._opts.policy or service._opts
end

local function normalise_verb(verb)
	return tostring(verb or ''):gsub('-', '_')
end

function M.validate_cap_request(service, verb, req)
	verb = normalise_verb(verb)
	if verb == 'status' then return true end
	if verb == 'listen' or verb == 'open_exchange' or verb == 'connect_ws' then
		local ok, lerr = assert_local(service, req)
		if not ok then return nil, lerr end
	end
	if verb == 'listen' then
		local args, err = policy.validate_listen_args(req.payload or {})
		if not args then return nil, err end
		req.payload = args
	elseif verb == 'open_exchange' or verb == 'exchange' then
		local checked, err = policy.validate_exchange_args(req.payload or {}, policy_opts(service))
		if not checked then return nil, err end
		req.payload = checked
	elseif verb == 'connect_ws' then
		local checked, err = policy.validate_connect_ws_args(req.payload or {}, policy_opts(service))
		if not checked then return nil, err end
		req.payload = checked
	else
		return nil, 'invalid_args'
	end
	return true
end

local function run_listen(service, scope, req, setup)
	local owner = setup.owner
	local args = req.payload or {}
	local opts = copy(args)
	opts.driver = service._driver
	opts.http_server = service._opts.http_server
	opts.backend_timeout = service._opts.backend_timeout
	opts.connection_setup_timeout = service._opts.connection_setup_timeout
	opts.intra_stream_timeout = service._opts.intra_stream_timeout
	opts.context_terminator = service._opts.context_terminator
	opts.max_accept_queue = args.max_accept_queue or service._opts.max_accept_queue or 64

	local handle_id = assert(service:_reserve_handle('listener', { owner = 'http_service' }))
	table.insert(setup.reserved_handles, handle_id)
	local generation = service._generation
	opts.events_port = event_port_from_submit(service._event_tx, function (ev, label)
		return service:_submit_registry_event(ev, label or 'http_listener_context_event_report_failed')
	end, {
		service_id = service._id,
		source = 'http_listener',
		source_id = handle_id,
		listener_id = handle_id,
		handle_id = handle_id,
		generation = generation,
	}, 'http_listener_context_event_report_failed')
	local component, cerr = listener_owner.start({
		lifetime_scope = service._scope,
		listen_opts = opts,
		handle_id = handle_id,
		generation = generation,
		events_port = service:_event_port({
			source = 'http_listener_owner',
			source_id = handle_id,
			listener_id = handle_id,
			handle_id = handle_id,
			generation = generation,
		}, {
			label = 'http_listener_owner_event_report_failed',
		}),
	})
	if not component then
		owner:fail_once(cerr)
		service:_remove_handle(handle_id, cerr or 'listener_start_failed')
		error(cerr or 'listener_start_failed', 0)
	end

	scope:finally(function (_, status, primary)
		if status ~= 'ok' then component:cancel(primary or status or 'listen_setup_finalised') end
	end)

	service:_register_handle('listener', component.listener, { id = handle_id, owner = 'http_service' })
	return { listener = component.listener, handle_id = handle_id }
end

local function run_open_exchange(service, scope, req, setup)
	local owner = setup.owner
	local handle_id = assert(service:_reserve_handle('exchange', { owner = 'http_service' }))
	table.insert(setup.reserved_handles, handle_id)
	local opts = copy(service._opts)
	for k, v in pairs(opts.policy or {}) do opts[k] = v end
	opts.origin = req.origin
	opts.principal = req.origin and req.origin.principal
	opts.body_registry = service._body_registry
	opts.on_terminate = function (_, reason)
		service:_remove_handle(handle_id, reason or 'exchange_terminated')
	end
	local ex, err = perform(client.open_exchange_op(service._driver, req.payload or {}, opts))
	if not ex then owner:fail_once(err); service:_remove_handle(handle_id, err or 'open_exchange_failed'); error(err or 'open_exchange_failed', 0) end

	scope:finally(function (_, status, primary)
		if status ~= 'ok' then terminate_handle(ex, primary or status or 'open_exchange_finalised') end
	end)

	service:_register_handle('exchange', ex, { id = handle_id, owner = 'http_service' })
	return { exchange = ex, handle_id = handle_id }
end

local function run_exchange(service, _scope, req, _setup)
	local opts = copy(service._opts)
	for k, v in pairs(opts.policy or {}) do opts[k] = v end
	opts.origin = req.origin
	opts.principal = req.origin and req.origin.principal
	opts.body_registry = service._body_registry
	local result, err = perform(client.exchange_op(service._driver, req.payload or {}, opts))
	if not result then error(err or 'exchange_failed', 0) end
	return { result = result }
end

local function run_connect_ws(service, scope, req, setup)
	local owner = setup.owner
	local handle_id = assert(service:_reserve_handle('websocket', { owner = 'http_service' }))
	table.insert(setup.reserved_handles, handle_id)
	local opts = copy(service._opts)
	opts.origin = req.origin
	opts.principal = req.origin and req.origin.principal
	opts.on_terminate = function (_, reason)
		service:_remove_handle(handle_id, reason or 'websocket_terminated')
	end
	local ws, err = perform(websocket.connect_op(service._driver, req.payload or {}, opts))
	if not ws then owner:fail_once(err); service:_remove_handle(handle_id, err or 'connect_ws_failed'); error(err or 'connect_ws_failed', 0) end

	scope:finally(function (_, status, primary)
		if status ~= 'ok' then terminate_handle(ws, primary or status or 'connect_ws_finalised') end
	end)

	service:_register_handle('websocket', ws, { id = handle_id, owner = 'http_service' })
	return { websocket = ws, handle_id = handle_id }
end

function M.start_operation(service, verb, req, request_id, owner)
	verb = normalise_verb(verb)
	local run
	if verb == 'listen' then run = function (scope, setup) return run_listen(service, scope, req, setup) end
	elseif verb == 'open_exchange' then run = function (scope, setup) return run_open_exchange(service, scope, req, setup) end
	elseif verb == 'exchange' then run = function (scope, setup) return run_exchange(service, scope, req, setup) end
	elseif verb == 'connect_ws' then run = function (scope, setup) return run_connect_ws(service, scope, req, setup) end
	else return service:_reject_request(request_id, owner, 'invalid_args') end
	return operation_owner.start(service, verb, req, request_id, owner, run)
end

return M
