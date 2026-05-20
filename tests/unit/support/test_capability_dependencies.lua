-- tests/unit/support/test_capability_dependencies.lua

local fibers  = require 'fibers'
local busmod  = require 'bus'
local runfibers = require 'tests.support.run_fibers'
local deps_mod = require 'devicecode.support.capability_dependencies'

local tests = {}

local function fail(msg)
	error(msg or 'assertion failed', 2)
end

local function ok(v, msg)
	if not v then fail(msg) end
	return v
end

local function eq(a, b, msg)
	if a ~= b then
		fail((msg or 'assertion failed') .. ': expected ' .. tostring(b) .. ', got ' .. tostring(a))
	end
end

local function is_true(v, msg)
	if v ~= true then fail(msg or ('expected true, got ' .. tostring(v))) end
end

local function is_false(v, msg)
	if v ~= false then fail(msg or ('expected false, got ' .. tostring(v))) end
end

local function is_nil(v, msg)
	if v ~= nil then fail(msg or ('expected nil, got ' .. tostring(v))) end
end

local function status_topic(class, id)
	return { 'cap', class, id or 'main', 'status' }
end

local function retain_status(conn, class, id, payload)
	return conn:retain(status_topic(class, id), payload)
end

local function new_deps(conn, specs, opts)
	local deps, err = deps_mod.open(conn, specs, opts)
	return ok(deps, err)
end

function tests.test_open_creates_curated_refs_and_initial_configured_state()
	runfibers.run(function()
		local b = busmod.new()
		local conn = b:connect()
		local deps = new_deps(conn, {
			{ key = 'network_config', class = 'network-config', id = 'main' },
			{ key = 'optional_store', class = 'artifact-store', id = 'main', required = false },
		})

		ok(deps:ref('network_config'), 'capability ref expected')
		eq(deps:status('network_config'), 'configured')
		eq(deps:observed_status('network_config'), 'configured')
		is_false(deps:available('network_config'))
		is_false(deps:all_available('required'))

		local snap = deps:snapshot()
		eq(snap.network_config.class, 'network-config')
		eq(snap.network_config.id, 'main')
		is_true(snap.network_config.required)
		is_false(snap.network_config.available)
		is_false(snap.optional_store.required)

		deps:terminate('test complete')
	end)
end

function tests.test_retained_status_replay_updates_effective_availability()
	runfibers.run(function()
		local b = busmod.new()
		local writer = b:connect()
		local conn = b:connect()

		retain_status(writer, 'network-config', 'main', {
			schema = 'devicecode.cap.status/1',
			state = 'available',
			available = true,
		})

		local deps = new_deps(conn, {
			{ key = 'network_config', class = 'network-config', id = 'main' },
		})

		local ev = fibers.perform(deps:recv_op('network_config'))
		eq(ev.kind, 'capability_dependency_changed')
		eq(ev.key, 'network_config')
		eq(ev.status, 'available')
		is_true(ev.available)
		is_true(deps:available('network_config'))
		eq(deps:status('network_config'), 'available')
		is_true(deps:all_available('required'))

		deps:terminate('test complete')
	end)
end

function tests.test_route_missing_overrides_observed_available_until_next_available_status()
	runfibers.run(function()
		local b = busmod.new()
		local writer = b:connect()
		local conn = b:connect()

		retain_status(writer, 'control-store', 'update', { state = 'available', available = true })

		local deps = new_deps(conn, {
			{ key = 'job_store', class = 'control-store', id = 'update' },
		})
		fibers.perform(deps:recv_op('job_store'))
		is_true(deps:available('job_store'))
		eq(deps:observed_status('job_store'), 'available')

		local ok_mark = deps:mark_route_missing('job_store', { err = 'no_route' })
		is_true(ok_mark)
		eq(deps:observed_status('job_store'), 'available')
		eq(deps:status('job_store'), 'route_missing')
		is_false(deps:available('job_store'))
		eq(deps:reason('job_store'), 'no_route')

		retain_status(writer, 'control-store', 'update', { state = 'available', available = true })
		local ev = fibers.perform(deps:recv_op('job_store'))
		eq(ev.status, 'available')
		is_true(ev.available)
		eq(deps:status('job_store'), 'available')
		is_nil(deps:reason('job_store'))

		deps:terminate('test complete')
	end)
end

function tests.test_changed_op_reports_material_status_changes_only()
	runfibers.run(function()
		local b = busmod.new()
		local writer = b:connect()
		local conn = b:connect()
		local deps = new_deps(conn, {
			{ key = 'http', class = 'http', id = 'main' },
		})

		local seen = deps:version()
		retain_status(writer, 'http', 'main', { state = 'available', available = true })
		local ev = fibers.perform(deps:recv_op('http'))
		is_true(ev.changed)

		local version, snap, err = fibers.perform(deps:changed_op(seen))
		is_nil(err)
		ok(version and version > seen, 'version should advance')
		is_true(snap.http.available)
		seen = deps:version()

		retain_status(writer, 'http', 'main', { state = 'available', available = true })
		ev = fibers.perform(deps:recv_op('http'))
		is_false(ev.changed)
		eq(deps:version(), seen)

		deps:terminate('test complete')
	end)
end

function tests.test_snapshot_is_copied()
	runfibers.run(function()
		local b = busmod.new()
		local conn = b:connect()
		local deps = new_deps(conn, {
			{ key = 'network_config', class = 'network-config', id = 'main' },
		})

		local snap = deps:snapshot()
		snap.network_config.status = 'mutated'
		snap.network_config.topic[1] = 'mutated'

		local snap2 = deps:snapshot()
		eq(snap2.network_config.status, 'configured')
		eq(snap2.network_config.topic[1], 'cap')

		deps:terminate('test complete')
	end)
end

function tests.test_no_route_classifier_handles_nested_bus_results()
	is_true(deps_mod.is_no_route(nil, 'no_route'))
	is_true(deps_mod.is_no_route({ err = 'network HAL call failed', detail = 'no_route' }))
	is_true(deps_mod.is_no_route({ result = { reason = { err = 'no_route' } } }))
	is_false(deps_mod.is_no_route({ reason = { err = 'backend_failed' } }))
end

function tests.test_terminate_closes_change_op_and_subscriptions()
	runfibers.run(function()
		local b = busmod.new()
		local conn = b:connect()
		local deps = new_deps(conn, {
			{ key = 'network_config', class = 'network-config', id = 'main' },
		})
		local seen = deps:version()
		deps:terminate('closed_for_test')
		is_true(deps:is_terminated())
		eq(deps:why(), 'closed_for_test')

		local version, snap, err = fibers.perform(deps:changed_op(seen))
		is_nil(version)
		is_nil(snap)
		eq(err, 'closed_for_test')
	end)
end

return tests
