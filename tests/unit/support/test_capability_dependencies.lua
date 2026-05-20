-- tests/unit/support/test_capability_dependencies.lua

local fibers  = require 'fibers'
local op      = require 'fibers.op'
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

local function next_event(deps)
	return fibers.perform(deps:event_source():recv_op())
end


function tests.test_open_does_not_mutate_options_table()
	runfibers.run(function()
		local b = busmod.new()
		local conn = b:connect()
		local opts = { queue_len = 4, full = 'drop_oldest' }
		local before = {}
		for k, v in pairs(opts) do before[k] = v end

		local deps = new_deps(conn, {
			{ key = 'network_config', class = 'network-config', id = 'main' },
		}, opts)

		for k, v in pairs(opts) do eq(v, before[k], 'option table value changed for ' .. tostring(k)) end
		for k, _ in pairs(before) do eq(opts[k], before[k], 'option table lost key ' .. tostring(k)) end
		is_nil(opts._now, 'open should not add private fields to caller options')
		deps:terminate('test complete')
	end)
end

function tests.test_public_contract_is_small_model_style_surface()
	runfibers.run(function()
		local b = busmod.new()
		local conn = b:connect()
		local deps = new_deps(conn, {
			{ key = 'network_config', class = 'network-config', id = 'main' },
		})

		for _, name in ipairs({
			'available', 'status', 'dependency', 'snapshot',
			'version', 'changed_op', 'event_source',
			'ref', 'classify_call_failure', 'terminate',
		}) do
			if type(deps[name]) ~= 'function' then fail('expected public method ' .. name) end
		end

		for _, name in ipairs({
			'close', 'is_terminated', 'why', 'keys', 'observed_status', 'reason',
			'all_available', 'record_status', 'mark_route_missing', 'clear_route_missing',
			'recv_op', 'try_recv_now', 'event_sources',
		}) do
			if deps[name] ~= nil then fail('unexpected public method ' .. name) end
		end

		deps:terminate('test complete')
	end)
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
		is_false(deps:available('network_config'))

		local snap = deps:snapshot()
		eq(snap.network_config.key, 'network_config')
		eq(snap.network_config.class, 'network-config')
		eq(snap.network_config.id, 'main')
		eq(snap.network_config.observed_status, 'configured')
		eq(snap.network_config.status, 'configured')
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

		local ev = next_event(deps)
		eq(ev.kind, 'capability_dependency_changed')
		eq(ev.key, 'network_config')
		eq(ev.status, 'available')
		is_true(ev.available)
		is_true(deps:available('network_config'))
		eq(deps:status('network_config'), 'available')

		local dep = deps:dependency('network_config')
		eq(dep.observed_status, 'available')
		eq(dep.status, 'available')
		is_true(dep.available)

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
		next_event(deps)
		is_true(deps:available('job_store'))
		eq(deps:dependency('job_store').observed_status, 'available')

		local class = deps:classify_call_failure('job_store', { err = 'no_route' })
		eq(class, 'route_missing')
		eq(deps:dependency('job_store').observed_status, 'available')
		eq(deps:status('job_store'), 'route_missing')
		is_false(deps:available('job_store'))
		eq(deps:dependency('job_store').reason, 'no_route')

		retain_status(writer, 'control-store', 'update', { state = 'available', available = true })
		local ev = next_event(deps)
		eq(ev.status, 'available')
		is_true(ev.available)
		eq(deps:status('job_store'), 'available')
		is_nil(deps:dependency('job_store').reason)

		deps:terminate('test complete')
	end)
end

function tests.test_explicit_unavailable_supersedes_route_missing()
	runfibers.run(function()
		local b = busmod.new()
		local writer = b:connect()
		local conn = b:connect()

		retain_status(writer, 'control-store', 'update', { state = 'available', available = true })
		local deps = new_deps(conn, {
			{ key = 'job_store', class = 'control-store', id = 'update' },
		})
		next_event(deps)
		deps:classify_call_failure('job_store', { err = 'no_route' })
		eq(deps:status('job_store'), 'route_missing')

		retain_status(writer, 'control-store', 'update', {
			state = 'unavailable',
			available = false,
			reason = 'driver_stopped',
		})
		local ev = next_event(deps)
		eq(ev.status, 'unavailable')
		is_false(ev.available)
		eq(deps:dependency('job_store').observed_status, 'unavailable')
		eq(deps:status('job_store'), 'unavailable')
		eq(deps:dependency('job_store').reason, 'driver_stopped')

		local snap = deps:dependency('job_store')
		eq(snap.observed_reason, 'driver_stopped')
		eq(snap.reason, 'driver_stopped')
		is_false(snap.route_missing)

		deps:terminate('test complete')
	end)
end

function tests.test_explicit_available_false_overrides_running_state()
	runfibers.run(function()
		local b = busmod.new()
		local writer = b:connect()
		local conn = b:connect()
		local deps = new_deps(conn, {
			{ key = 'network_state', class = 'network-state', id = 'main' },
		})

		retain_status(writer, 'network-state', 'main', { state = 'running', available = false })
		local ev = next_event(deps)
		eq(ev.status, 'running')
		is_false(ev.available)
		is_false(deps:available('network_state'))
		eq(deps:status('network_state'), 'running')

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
		local ev = next_event(deps)
		is_true(ev.changed)

		local version, snap, err = fibers.perform(deps:changed_op(seen))
		is_nil(err)
		ok(version and version > seen, 'version should advance')
		is_true(snap.http.available)
		seen = deps:version()

		retain_status(writer, 'http', 'main', { state = 'available', available = true })
		ev = next_event(deps)
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

		local class = deps:classify_call_failure('network_config', { err = 'no_route' })
		eq(class, 'route_missing')

		local snap = deps:snapshot()
		snap.network_config.status = 'mutated'
		snap.network_config.last_error.err = 'mutated'

		local snap2 = deps:snapshot()
		eq(snap2.network_config.status, 'configured')
		eq(snap2.network_config.last_error.err, 'no_route')

		deps:terminate('test complete')
	end)
end

function tests.test_no_route_classifier_handles_only_canonical_call_shapes()
	is_true(deps_mod.is_no_route(nil, 'no_route'))
	is_true(deps_mod.is_no_route({ err = 'network HAL call failed', detail = 'no_route' }))
	is_true(deps_mod.is_no_route({ result = { err = 'no_route' } }))
	is_false(deps_mod.is_no_route({ reason = { err = 'no_route' } }))
	is_false(deps_mod.is_no_route({ reason = { err = 'backend_failed' } }))
	is_false(deps_mod.is_no_route({ primary = { err = 'no_route' } }))
	is_false(deps_mod.is_no_route({ report = { primary = { err = 'no_route' } } }))
	is_false(deps_mod.is_no_route({ children = { { primary = { err = 'no_route' } } } }))
end

function tests.test_classify_call_failure_marks_route_missing()
	runfibers.run(function()
		local b = busmod.new()
		local writer = b:connect()
		local conn = b:connect()
		retain_status(writer, 'control-store', 'update', { state = 'available', available = true })
		local deps = new_deps(conn, {
			{ key = 'job_store', class = 'control-store', id = 'update' },
		})
		next_event(deps)

		local class, reason, dep = deps:classify_call_failure('job_store', { result = { err = 'no_route' } })
		eq(class, 'route_missing')
		ok(reason, 'reason expected')
		is_false(dep.available)
		eq(deps:status('job_store'), 'route_missing')
		is_false(deps:available('job_store'))

		class = deps:classify_call_failure('job_store', { reason = { err = 'backend_failed' } })
		eq(class, 'failure')

		deps:terminate('test complete')
	end)
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

		local version, snap, err = fibers.perform(deps:changed_op(seen))
		is_nil(version)
		is_nil(snap)
		eq(err, 'closed_for_test')
	end)
end

function tests.test_closed_status_feed_disables_event_source()
	runfibers.run(function()
		local fake_sub = {}
		function fake_sub:recv_op()
			return op.always(nil, 'closed_for_test')
		end
		function fake_sub:why()
			return 'closed_for_test'
		end

		local fake_ref = {}
		function fake_ref:get_status_sub()
			return fake_sub
		end

		local deps = new_deps(nil, {
			{ key = 'closed_dep', ref = fake_ref },
		})
		is_true(deps:event_source().enabled())

		local ev = next_event(deps)
		eq(ev.kind, 'capability_dependency_closed')
		eq(ev.key, 'closed_dep')
		eq(ev.reason, 'closed_for_test')
		eq(ev.status, 'unavailable')
		is_false(ev.available)
		is_false(deps:event_source().enabled())

		deps:terminate('test complete')
	end)
end

function tests.test_required_status_watch_failure_fails_open()
	runfibers.run(function()
		local fake_ref = {}
		function fake_ref:get_status_sub()
			error('boom')
		end

		local deps, err = deps_mod.open(nil, {
			{ key = 'required_dep', ref = fake_ref, required = true },
		})
		is_nil(deps)
		ok(tostring(err):find('dependency_status_watch_failed:required_dep', 1, true), err)
		ok(tostring(err):find('boom', 1, true), err)
	end)
end

function tests.test_get_status_sub_returned_error_is_preserved()
	runfibers.run(function()
		local fake_ref = {}
		function fake_ref:get_status_sub()
			return nil, 'detail_from_ref'
		end

		local deps, err = deps_mod.open(nil, {
			{ key = 'required_dep', ref = fake_ref, required = true },
		})
		is_nil(deps)
		ok(tostring(err):find('dependency_status_watch_failed:required_dep', 1, true), err)
		ok(tostring(err):find('detail_from_ref', 1, true), err)
	end)
end

function tests.test_optional_status_watch_failure_is_reported_in_snapshot()
	runfibers.run(function()
		local fake_ref = {}
		function fake_ref:get_status_sub()
			return nil
		end

		local deps = new_deps(nil, {
			{ key = 'optional_dep', ref = fake_ref, required = false },
		})
		local snap = deps:snapshot()
		eq(snap.optional_dep.status, 'watch_failed')
		is_false(snap.optional_dep.available)
		eq(snap.optional_dep.observed_status, 'watch_failed')
		ok(snap.optional_dep.observed_reason, 'observed_reason expected')
		deps:terminate('test complete')
	end)
end

function tests.test_required_watch_failure_can_be_made_unavailable_explicitly()
	runfibers.run(function()
		local fake_ref = {}
		function fake_ref:get_status_sub()
			return nil
		end

		local deps = new_deps(nil, {
			{ key = 'required_dep', ref = fake_ref, required = true, watch_failure = 'unavailable' },
		})
		local snap = deps:snapshot()
		eq(snap.required_dep.status, 'watch_failed')
		is_false(snap.required_dep.available)
		eq(snap.required_dep.observed_status, 'watch_failed')
		deps:terminate('test complete')
	end)
end


function tests.test_ensure_adds_dynamic_dependency_and_receives_status()
	runfibers.run(function()
		local b = busmod.new()
		local conn = b:connect()
		local deps = new_deps(conn, {
			{ key = 'first', class = 'first', id = 'main' },
		})

		local ok_add, err, dep = deps:ensure({ key = 'dynamic', class = 'dynamic', id = 'main' })
		is_true(ok_add, err)
		eq(dep.key, 'dynamic')
		eq(deps:status('dynamic'), 'configured')
		is_false(deps:available('dynamic'))

		retain_status(conn, 'dynamic', 'main', { state = 'available' })
		local ev = next_event(deps)
		eq(ev.key, 'dynamic')
		is_true(ev.available)
		is_true(deps:available('dynamic'))

		local ok_again = deps:ensure({ key = 'dynamic', class = 'dynamic', id = 'main' })
		is_true(ok_again)
		deps:terminate('test complete')
	end)
end

return tests
