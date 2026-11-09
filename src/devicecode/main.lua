-- devicecode/main.lua
--
-- Main runtime entrypoint logic.

local fibers = require 'fibers'
local op     = require 'fibers.op'
local sleep  = require 'fibers.sleep'
local authz  = require 'devicecode.authz'
local busmod = require 'bus'

local safe   = require 'coxpcall'

local EXIT_GRACE_PERIOD = 60.0

local M      = {}

local function require_env(name)
	local v = os.getenv(name)
	if not v or v == '' then
		error(('missing required environment variable %s'):format(name), 2)
	end
	return v
end

local function parse_csv(s)
	local out = {}
	for part in tostring(s):gmatch('[^,%s]+') do
		out[#out + 1] = part
	end
	return out
end

local function assert_unique_services(names)
	local seen = {}
	for i = 1, #names do
		local name = names[i]
		if seen[name] then
			error(('DEVICECODE_SERVICES contains duplicate service name %s'):format(tostring(name)), 2)
		end
		seen[name] = true
	end
end

local function move_to_front(list, wanted)
	local out = {}
	for i = 1, #list do
		if list[i] == wanted then
			out[#out + 1] = list[i]
		end
	end
	for i = 1, #list do
		if list[i] ~= wanted then
			out[#out + 1] = list[i]
		end
	end
	return out
end

local function cleanup_child_scope(child, reason)
	if not child then return end
	child:cancel(reason or 'cleanup')
end

local function spawn_service(child, bus, name, mod, env, extra_opts)
	return child:spawn(function()
		local conn = bus:connect({
			principal = authz.service_principal(name),
		})

		local function connect_as(principal)
			return bus:connect({
				principal = principal,
			})
		end

		mod.start(conn, {
			name         = name,
			env          = env,
			connect      = connect_as,
			services     = extra_opts and extra_opts.services or nil,
			run_http     = extra_opts and extra_opts.run_http or nil,
			verify_login = extra_opts and extra_opts.verify_login or nil,
		})

		error(('service returned unexpectedly: %s'):format(tostring(name)), 0)
	end)
end

local function build_bus()
	return busmod.new({
		q_length   = 10,
		full       = 'drop_oldest',
		s_wild     = '+',
		m_wild     = '#',
		authoriser = authz.new(),
	})
end

local function now()
	return fibers.now()
end

local function retain_main_state(conn, status, fields)
	local payload = {
		status = status,
		t      = now(),
	}
	if fields then
		for k, v in pairs(fields) do
			payload[k] = v
		end
	end
	conn:retain({ 'obs', 'state', 'main' }, payload)
end

local function retain_service_state(conn, name, status, fields)
	local payload = {
		service = name,
		status  = status,
		t       = now(),
	}
	if fields then
		for k, v in pairs(fields) do
			payload[k] = v
		end
	end
	conn:retain({ 'obs', 'state', 'service', name }, payload)
end

local function load_service(service_loader, name)
	local ok, mod = safe.pcall(service_loader, name)
	if not ok then
		return nil, mod
	end
	if type(mod) ~= 'table' or type(mod.start) ~= 'function' then
		return nil, 'service module must export start(conn, opts)'
	end
	return mod, nil
end

local function fail_boot(main_conn, service_name, what, err, extra)
	if service_name then
		retain_service_state(main_conn, service_name, 'failed', {
			what = what,
			err  = tostring(err),
		})
	end

	local payload = {
		what = what,
		err  = tostring(err),
	}
	if service_name then
		payload.service = service_name
	end
	if extra then
		for k, v in pairs(extra) do
			payload[k] = v
		end
	end

	retain_main_state(main_conn, 'failed', payload)
	main_conn:publish({ 'obs', 'log', 'main', 'error' }, payload)

	if service_name then
		error(('boot failed for service %s: %s'):format(tostring(service_name), tostring(err)), 0)
	else
		error(('boot failed: %s'):format(tostring(err)), 0)
	end
end

function M.run(scope, params)
	params = params or {}

	local env = params.env or (os.getenv('DEVICECODE_ENV') or 'dev')
	local exit_grace_period = params.exit_grace_period or EXIT_GRACE_PERIOD

	local service_names = parse_csv(params.services_csv or require_env('DEVICECODE_SERVICES'))
	if #service_names == 0 then
		error('DEVICECODE_SERVICES must contain at least one service name', 2)
	end

	assert_unique_services(service_names)

	-- Start monitor first if it is present.
	service_names = move_to_front(service_names, 'monitor')

	local bus = params.bus or build_bus()
	local service_loader = params.service_loader or function(name)
		return require('services.' .. name)
	end
	local service_opts = params.service_opts or {}

	local main_conn = bus:connect({
		principal = authz.service_principal('main'),
	})

	retain_main_state(main_conn, 'starting', {
		env      = env,
		services = service_names,
	})

	main_conn:publish({ 'obs', 'log', 'main', 'info' }, {
		what = 'starting',
		env  = env,
	})

	-- Keep recent log lines for the crash record. This is here and not in the
	-- monitor service, because monitor could be the service that fails. The HTTP
	-- service logs on the v1 topic only; the others use the legacy one.
	local crash_store = params.crash_store
	if crash_store then
		local sub_opts = { queue_len = 64, full = 'drop_oldest' }
		local legacy_sub = main_conn:subscribe({ 'obs', 'log', '#' }, sub_opts)
		local v1_sub = main_conn:subscribe({ 'obs', 'v1', '+', 'log', '#' }, sub_opts)
		scope:spawn(function()
			while true do
				local _, msg = fibers.perform(op.named_choice({
					legacy = legacy_sub:recv_op(),
					v1     = v1_sub:recv_op(),
				}))
				if not msg then return end
				local topic = msg.topic
				crash_store:note_log(topic[3], topic[#topic], msg.payload)
			end
		end)
	end

	-- A signal or other cancel of main itself stops the fibers below straight away,
	-- so this waits outside the scope's cancellation to see it happen. Records are
	-- first-wins, so a service failure already recorded stays.
	if crash_store then
		scope:spawn(function()
			local _, primary = op.perform_raw(scope:not_ok_op())
			local signal = tostring(primary):match('signal:%u+')
			if signal then
				crash_store:record_signal(signal)
			else
				crash_store:record_error(primary)
			end
		end)
	end

	-- Record now, not after unwinding: a service that won't finish cancelling can
	-- hold everything up for ever, and the process may be killed while it waits.
	local function boot_failed(name, what, err)
		if crash_store then
			crash_store:record_boot_failure({ service = name, what = what, err = err })
		end
		fail_boot(main_conn, name, what, err)
	end

	local services = {}

	for i = 1, #service_names do
		local name = service_names[i]

		retain_service_state(main_conn, name, 'starting')
		main_conn:publish({ 'obs', 'event', 'main', 'spawn' }, { service = name, t = now() })

		local mod, lerr = load_service(service_loader, name)
		if not mod then
			boot_failed(name, 'load_failed', lerr)
		end

		local child, cerr = scope:child()
		if not child then
			boot_failed(name, 'child_scope_failed', cerr)
		end

		local ok_spawn, serr = spawn_service(child, bus, name, mod, env, service_opts[name])
		if not ok_spawn then
			cleanup_child_scope(child, 'spawn_failed')
			boot_failed(name, 'spawn_failed', serr)
		end

		retain_service_state(main_conn, name, 'running')
		services[#services + 1] = { name = name, scope = child }
	end

	retain_main_state(main_conn, 'running', {
		env      = env,
		services = service_names,
	})

	scope:spawn(function()
		local ev = nil

		for i = 1, #services do
			local rec = services[i]
			local one = rec.scope:not_ok_op():wrap(function(st, primary)
				return rec, st, primary
			end)
			ev = ev and op.choice(ev, one) or one
		end

		if not ev then
			retain_main_state(main_conn, 'failed', {
				what = 'no_services_started',
			})
			scope:cancel('no_services_started')
			return
		end

		local rec, st, primary = fibers.perform(ev)
		local svc = rec.name

		-- Record now, not after the join below: a child stuck in uninterruptible
		-- sleep can hold the join for ever, and the process may be killed while it
		-- waits.
		if crash_store then
			crash_store:record_failure({ service = svc, status = st, primary = primary })
		end

		local jst, report, jprimary = fibers.perform(rec.scope:join_op())

		retain_service_state(main_conn, svc, jst, {
			primary = tostring(jprimary),
			report  = report,
		})

		retain_main_state(main_conn, 'failed', {
			what    = 'service_not_ok',
			service = svc,
			status  = jst,
			primary = tostring(jprimary),
		})

		main_conn:publish({ 'obs', 'event', 'main', 'service_exit' }, {
			service = svc,
			status  = jst,
			primary = tostring(jprimary),
			report  = report,
			t       = now(),
		})

		main_conn:publish({ 'obs', 'log', 'main', (jst == 'failed') and 'error' or 'warn' }, {
			what    = 'service_not_ok',
			service = svc,
			status  = jst,
			primary = tostring(jprimary),
		})

		sleep.sleep(exit_grace_period)

		scope:cancel(('service_not_ok:%s'):format(tostring(svc)))
	end)

	main_conn:publish({ 'obs', 'log', 'main', 'info' }, {
		what = 'services_spawned',
		n    = #services,
	})

	local n = 0
	while true do
		n = n + 1
		main_conn:publish({ 'obs', 'event', 'main', 'tick' }, {
			n = n,
			t = now(),
		})
		sleep.sleep(10.0)
	end
end

return M
