-- integration/devhost/main_failure_spec.lua

local fibers        = require 'fibers'
local sleep         = require 'fibers.sleep'
local busmod        = require 'bus'

local safe = require 'coxpcall'

local runfibers     = require 'tests.support.run_fibers'
local probe         = require 'tests.support.bus_probe'
local fake_hal_mod  = require 'tests.support.fake_hal'
local test_diag     = require 'tests.support.test_diag'

local mainmod       = require 'devicecode.main'

local T = {}

local function wait_retained_payload_matching(conn, topic, pred, opts)
	opts = opts or {}

	local found = nil
	local ok = probe.wait_until(function()
		local ok2, payload = safe.pcall(function()
			return probe.wait_payload(conn, topic, { timeout = 0.02 })
		end)

		if ok2 and pred(payload) then
			found = payload
			return true
		end

		return false
	end, {
		timeout  = opts.timeout or 0.75,
		interval = opts.interval or 0.01,
	})

	if ok then
		return found
	end

	return nil
end

local function make_service_loader(fake_hal, linger_box)
	return function(name)
		if name == 'hal' then
			return {
				start = function(conn, opts)
					fake_hal:start(conn, {
						name = opts and opts.name or 'hal',
						env  = opts and opts.env  or 'dev',
					})

					while true do
						sleep.sleep(3600.0)
					end
				end,
			}
		elseif name == 'linger' then
			return {
				start = function(conn, opts)
					local scope = fibers.current_scope()

					scope:finally(function(aborted, st, primary)
						linger_box.finalised = true
						linger_box.aborted   = aborted
						linger_box.status    = st
						linger_box.primary   = primary
					end)

					while true do
						sleep.sleep(3600.0)
					end
				end,
			}
		elseif name == 'boom' then
			return {
				start = function(conn, opts)
					sleep.sleep(0.02)
					error('boom exploded', 0)
				end,
			}
		end

		error('unexpected service name: ' .. tostring(name), 0)
	end
end

local function spawn_main(scope, bus, fake_hal, linger_box, services_csv)
	local child, cerr = scope:child()
	assert(child ~= nil, tostring(cerr))

	local ok_spawn, err = scope:spawn(function()
		mainmod.run(child, {
			env            = 'dev',
			services_csv   = services_csv,
			bus            = bus,
			service_loader = make_service_loader(fake_hal, linger_box),
		})
	end)
	assert(ok_spawn, tostring(err))

	return child
end

function T.devhost_main_fails_fast_when_child_service_errors()
	runfibers.run(function(scope)
		local bus  = busmod.new()
		local conn = bus:connect()

		local linger_box = {
			finalised = false,
			aborted   = nil,
			status    = nil,
			primary   = nil,
		}

		local fake_hal = fake_hal_mod.new({
			backend = 'fakehal',
			caps = {},
			scripted = {},
		})

		local diag = test_diag.for_stack(scope, bus, { obs = true, max_records = 300, fake_hal = fake_hal })
		test_diag.add_table(diag, 'linger_box', function() return linger_box end)

		local main_scope = spawn_main(scope, bus, fake_hal, linger_box, 'hal,linger,boom')

		local main_failed = wait_retained_payload_matching(conn, { 'obs', 'state', 'main' }, function(payload)
			return type(payload) == 'table'
				and payload.status == 'failed'
				and payload.what == 'service_not_ok'
				and payload.service == 'boom'
		end, { timeout = 0.75 })

		if main_failed == nil then
			diag:fail('expected main to fail because boom service errored')
		end

		local boom_failed = wait_retained_payload_matching(conn, { 'obs', 'state', 'service', 'boom' }, function(payload)
			return type(payload) == 'table'
				and payload.service == 'boom'
				and payload.status == 'failed'
				and tostring(payload.primary):match('boom exploded') ~= nil
		end, { timeout = 0.75 })

		if boom_failed == nil then
			diag:fail('expected failing boom service state to be retained')
		end

		-- Cancellation is not join. Join the main child scope so that cancelled
		-- siblings are finalised and their finalisers run.
		local jst, jrep, jprimary = fibers.perform(main_scope:join_op())
		assert(jst == 'cancelled' or jst == 'failed')

		local linger_final = probe.wait_until(function()
			return linger_box.finalised == true
				and linger_box.aborted == true
				and (linger_box.status == 'cancelled' or linger_box.status == 'failed')
		end, { timeout = 0.75, interval = 0.01 })

		if not linger_final then
			diag:fail(('expected sibling linger service to be cancelled and finalised'
				.. ' after joining main scope'
				.. ' (join_status=%s finalised=%s aborted=%s status=%s primary=%s)'):format(
					tostring(jst),
					tostring(linger_box.finalised),
					tostring(linger_box.aborted),
					tostring(linger_box.status),
					tostring(linger_box.primary)
				))
		end
	end, { timeout = 1.25 })
end

return T
