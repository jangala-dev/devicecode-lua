-- main.lua
--
-- Entrypoint.
--
-- Required env:
--   DEVICECODE_SERVICES   comma-separated service module names (e.g. "hal,config,monitor")
--   DEVICECODE_STATE_DIR  persisted state root directory
--
-- Optional env:
--   DEVICECODE_ENV        "dev" | "prod" (default: dev)

local function add_path(prefix)
	package.path = prefix .. '?.lua;' .. prefix .. '?/init.lua;' .. package.path
end

local env = os.getenv('DEVICECODE_ENV') or 'dev'
if env == 'prod' then
	add_path('./lib/')
else
	add_path('../vendor/lua-fibers/src/')
	add_path('../vendor/lua-bus/src/')
	add_path('../vendor/lua-trie/src/')
	add_path('./')
end

local fibers = require 'fibers'
local op     = require 'fibers.op'
local sleep  = require 'fibers.sleep'
local busmod = require 'bus'

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

local function main(scope)
	require_env('DEVICECODE_STATE_DIR')

	local service_names = parse_csv(require_env('DEVICECODE_SERVICES'))
	if #service_names == 0 then
		error('DEVICECODE_SERVICES must contain at least one service name', 2)
	end

	-- Start monitor first if it is present.
	service_names = move_to_front(service_names, 'monitor')

	local bus = busmod.new({
		q_length = 10,
		full     = 'drop_oldest',
		s_wild   = '+',
		m_wild   = '#',
	})

	-- Main’s own connection (lives in root scope for correct cancellation).
	local main_conn = bus:connect()

	-- Retained “boot marker” so monitor will replay it on subscribe.
	main_conn:retain({ 'obs', 'state', 'main', 'boot' }, {
		env      = env,
		services = service_names,
		at       = os.date('%Y-%m-%d %H:%M:%S'),
	})

	main_conn:publish({ 'obs', 'log', 'main', 'info' }, 'devicecode starting')

	local services = {}

	local function cleanup_child_scope(child, reason)
		if not child then return end
		child:cancel(reason or 'cleanup')
		-- Intentional: this scope is being retired immediately.
		op.perform_raw(child:join_op())
	end

	local function spawn_service(child, name, mod)
		return child:spawn(function()
			local conn = bus:connect()
			mod.start(conn, { name = name, env = env })

			-- Long-lived services are not expected to return normally.
			error(('service returned unexpectedly: %s'):format(tostring(name)), 0)
		end)
	end

	for i = 1, #service_names do
		local name = service_names[i]
		local mod  = require('services.' .. name)

		main_conn:publish({ 'obs', 'event', 'main', 'spawn' }, { service = name })

		local child, cerr = scope:child()
		if not child then
			main_conn:publish({ 'obs', 'log', 'main', 'error' },
				{ what = 'child_scope_failed', service = name, err = tostring(cerr) })
		else
			local ok_spawn, serr = spawn_service(child, name, mod)

			if not ok_spawn then
				main_conn:publish({ 'obs', 'log', 'main', 'error' },
					{ what = 'spawn_failed', service = name, err = tostring(serr) })
				cleanup_child_scope(child, 'spawn_failed')
			else
				services[#services + 1] = { name = name, scope = child }
			end
		end
	end

	scope:spawn(function()
		-- Build a choice op from the current set of services.
		local function build_choice()
			local ev = nil
			for i = 1, #services do
				local rec = services[i]
				if rec and rec.scope then
					local one = rec.scope:not_ok_op():wrap(function(st, primary)
						return rec, st, primary
					end)
					ev = ev and op.choice(ev, one) or one
				end
			end
			return ev
		end

		while true do
			if #services == 0 then
				main_conn:publish({ 'obs', 'log', 'main', 'warn' }, 'no services left to supervise')
				return
			end

			local ev = build_choice()
			if not ev then return end

			local rec, st, primary = op.perform_raw(ev)
			local svc = rec.name

			-- Now that the scope is not-ok, retire it fully. Calling join_op()
			-- here is safe: the service has already failed/cancelled, so we are
			-- no longer trying to preserve normal admission.
			local jst, report, jprimary = op.perform_raw(rec.scope:join_op())

			-- Log to monitor.
			main_conn:publish({ 'obs', 'event', 'main', 'service_exit' }, {
				service = svc,
				status  = jst,
				primary = tostring(jprimary),
				report  = report,
				at      = os.date('%Y-%m-%d %H:%M:%S'),
			})

			main_conn:publish({ 'obs', 'log', 'main', (jst == 'failed') and 'error' or 'warn' }, {
				what    = 'service_not_ok',
				service = svc,
				status  = jst,
				primary = tostring(jprimary),
			})

			-- Remove it so we do not immediately re-fire on the same retired scope.
			for i = #services, 1, -1 do
				if services[i] == rec then
					table.remove(services, i)
					break
				end
			end
		end
	end)

	main_conn:publish({ 'obs', 'log', 'main', 'info' }, 'services spawned; entering sleep')

	-- Heartbeat in root scope; cancellation interrupts sleep/perform naturally.
	local n = 0
	while true do
		n = n + 1
		main_conn:publish({ 'obs', 'event', 'main', 'tick' }, { n = n })
		sleep.sleep(10.0)
	end
end

fibers.run(main)
