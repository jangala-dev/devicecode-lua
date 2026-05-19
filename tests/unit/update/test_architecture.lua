-- tests/unit/update/test_architecture.lua

local tests = {}

local function fail(msg) error(msg or 'assertion failed', 2) end

local function read_file(path)
	local f = assert(io.open(path, 'r'))
	local s = f:read('*a')
	f:close()
	return s
end

local function list_update_files()
	local p = io.popen("find ../src/services/update -type f -name '*.lua' | sort")
	local out = {}
	for line in p:lines() do out[#out + 1] = line end
	p:close()
	out[#out + 1] = '../src/services/update.lua'
	return out
end


function tests.test_update_service_defaults_to_control_store_job_store()
	local svc = read_file('../src/services/update/service.lua')
	if not svc:find("services.update.job_store_control_store", 1, true) then
		fail('service.lua should import the control-store-backed job store')
	end
	if not svc:find("control_store_jobs.new", 1, true) then
		fail('service.lua should build the control-store job store by default')
	end
	if not svc:find("services.update.job_store_memory", 1, true) then
		fail('service.lua should import strict memory job store for explicit tests/harness use')
	end
	if not svc:find("job_store_kind == 'memory'", 1, true) then
		fail('memory job store should be an explicit test/harness opt-in')
	end
	if svc:find("services.update.job_store_cap", 1, true) then
		fail('service.lua should not use job_store_cap compatibility wrapper')
	end
	if svc:find("services.update.artifacts.store_cap", 1, true) then
		fail('service.lua should not use artifact store compatibility wrapper')
	end
end

function tests.test_update_service_code_does_not_use_perform_raw()
	for _, path in ipairs(list_update_files()) do
		local s = read_file(path)
		if s:find('perform_raw', 1, true) then
			fail('perform_raw found in ' .. path)
		end
	end
end

function tests.test_update_service_code_does_not_call_join_op()
	for _, path in ipairs(list_update_files()) do
		local s = read_file(path)
		if s:find('join_op', 1, true) then
			fail('join_op found in ' .. path)
		end
	end
end

function tests.test_update_finalisers_do_not_call_close_op()
	for _, path in ipairs(list_update_files()) do
		local s = read_file(path)
		if s:find('close_op', 1, true) then
			fail('close_op found in ' .. path)
		end
	end
end

function tests.test_priority_event_is_used_for_service_event_selection()
	local s = read_file('../src/services/update/events.lua')
	if not s:find("devicecode.support.priority_event", 1, true) then
		fail('update events should use devicecode.support.priority_event')
	end
end


function tests.test_service_does_not_handoff_public_manager_endpoint_to_generation()
	local s = read_file('../src/services/update/service.lua')
	if s:find('manager_rx = self._manager_ep', 1, true) then
		fail('service must route manager requests through a private generation queue')
	end
end

function tests.test_generation_does_not_own_active_runtime_state()
	local s = read_file('../src/services/update/generation.lua')
	if s:find("require 'services.update.active_runtime'", 1, true)
		or s:find('_active_runtime', 1, true)
	then
		fail('generation must not own active runtime state')
	end
end

function tests.test_service_owns_active_runtime_state()
	local s = read_file('../src/services/update/service.lua')
	if not s:find("require 'services.update.active_runtime'", 1, true)
		or not s:find('_active_component = active_component', 1, true)
		or not s:find('_active_runtime = active_component:state()', 1, true)
	then
		fail('service should own active runtime state')
	end
end

function tests.test_generation_is_composition_not_role_mixing()
	local s = read_file('../src/services/update/generation.lua')
	local forbidden = {
		"services.update.manager_requests",
		"devicecode.support.scoped_work",
		"devicecode.support.request_owner",
		"devicecode.support.priority_event",
		"services.update.job_repository",
	}
	for _, needle in ipairs(forbidden) do
		if s:find(needle, 1, true) then
			fail('generation.lua should not directly depend on ' .. needle)
		end
	end
	local required = {
		"services.update.manager",
		"services.update.generation_events",
	}
	for _, needle in ipairs(required) do
		if not s:find(needle, 1, true) then
			fail('generation.lua should compose ' .. needle)
		end
	end
end

function tests.test_generation_events_is_the_priority_boundary()
	local s = read_file('../src/services/update/generation_events.lua')
	if not s:find("devicecode.support.priority_event", 1, true) then
		fail('generation_events.lua should use support.priority_event')
	end
	if not s:find('ingest_terminal', 1, true) or not s:find('manager', 1, true) then
		fail('generation_events.lua should name generation semantic sources')
	end
end

function tests.test_service_owns_durable_job_runtime()
	local svc = read_file('../src/services/update/service.lua')
	if not svc:find("services.update.job_runtime", 1, true)
		or not svc:find('_jobs = jobs', 1, true)
	then
		fail('service.lua should own the durable job runtime')
	end
	local gen = read_file('../src/services/update/generation.lua')
	if gen:find("services.update.job_runtime", 1, true) then
		fail('generation.lua should consume a service-owned job projection, not own job_runtime')
	end
	if gen:find('save_job_op', 1, true) then
		fail('generation.lua should not perform durable job saves inline')
	end
	local rt = read_file('../src/services/update/job_runtime.lua')
	if not rt:find('save_job_op', 1, true) or not rt:find('job_transition_done', 1, true) then
		fail('job_runtime.lua should own durable transition work and transition completions')
	end
end

function tests.test_manager_router_owns_request_scoped_work()
	local gen = read_file('../src/services/update/generation.lua')
	if gen:find('manager_requests', 1, true) or gen:find('request_owner', 1, true) then
		fail('generation.lua should not implement manager request bodies')
	end
	local mgr = read_file('../src/services/update/manager.lua')
	if not mgr:find('services.update.manager_requests', 1, true)
		or not mgr:find('scoped_work.start', 1, true)
	then
		fail('manager.lua should own manager request routing into scoped work')
	end
end

function tests.test_active_completion_policy_is_extracted()
	local gen = read_file('../src/services/update/generation.lua')
	if gen:find('mark_awaiting_commit', 1, true)
		or gen:find('mark_awaiting_return', 1, true)
		or gen:find('mark_terminal', 1, true)
	then
		fail('generation.lua should not encode active job state transition details')
	end
	local policy = read_file('../src/services/update/active_policy.lua')
	if not policy:find('mark_awaiting_commit', 1, true)
		or not policy:find('apply_completion', 1, true)
	then
		fail('active_policy.lua should own active completion interpretation')
	end
end

function tests.test_manager_requests_do_not_start_active_work()
	local s = read_file('../src/services/update/manager_requests.lua')
	if s:find('start_active', 1, true) or s:find('start_gate', 1, true) or s:find('active lease required', 1, true) then
		fail('manager request scopes must persist active intent, not start active work')
	end
end

function tests.test_job_runtime_exposes_immediate_admission_and_active_intent()
	local s = read_file('../src/services/update/job_runtime.lua')
	if not s:find('function Runtime:admit_transition', 1, true) then
		fail('job_runtime should expose immediate admit_transition')
	end
	if s:find('submit_transition_op', 1, true) or s:find('function Runtime:transition_op', 1, true) then
		fail('job_runtime should not expose transition Op compatibility helpers')
	end
	local body = s:match('function Runtime:admit_transition%(.+function Runtime:terminate') or ''
	if body:find('op.guard', 1, true) or body:find('fibers.perform', 1, true) then
		fail('admit_transition must allocate and admit immediately without waiting')
	end
	if not s:find('active_intent', 1, true) then
		fail('job_runtime should persist active_intent')
	end
	if s:find('cancel_handle', 1, true) or s:find('cell.cancelled', 1, true) then
		fail('caller cancellation must not cancel admitted job transitions')
	end
end

function tests.test_active_runtime_launches_active_work_from_job_runtime_state()
	local svc = read_file('../src/services/update/service.lua')
	if svc:find('launch_next_active_from_jobs', 1, true) or svc:find('route_active_completion_to_generation', 1, true) then
		fail('service should not own active launch or route active completions to generation')
	end
	local rt = read_file('../src/services/update/active_runtime.lua')
	if not rt:find('function Component:consider_jobs', 1, true)
		or not rt:find('start_intent', 1, true)
		or not rt:find('admit_transition', 1, true)
	then
		fail('active_runtime should launch persisted active intents and apply completions through job_runtime')
	end
	if rt:find('active_runner', 1, true) or rt:find('spec.runner', 1, true) then
		fail('active_runtime must not expose an active_runner bypass')
	end
end

function tests.test_update_models_use_terminate_not_close()
	local s = read_file('../src/services/update/model.lua')
	if s:find('function Model:close', 1, true) then
		fail('update model should expose terminate(reason), not close(reason)')
	end
	if not s:find('function Model:terminate', 1, true) then
		fail('update model should expose terminate(reason)')
	end
end

function tests.test_update_observer_uses_terminate_not_close()
	local s = read_file('../src/services/update/observe.lua')
	if s:find('function Observer:close', 1, true) then
		fail('observer should expose terminate(reason), not close(reason)')
	end
	if not s:find('function Observer:terminate', 1, true) then
		fail('observer should expose terminate(reason)')
	end
end

function tests.test_update_artifact_lifetime_uses_canonical_terminate_ownership()
	local s = read_file('../src/services/update/artifacts/lifetime.lua')
	for _, needle in ipairs({
		'close_now',
		'abandon_now',
		'abort_now',
		'release_now',
		'terminate_now',
		'cleanup_now',
		'mark_transferred',
		'cleanup_method',
	}) do
		if s:find(needle, 1, true) then
			fail('artifact lifetime should not use legacy cleanup name: ' .. needle)
		end
	end
	if not s:find('resource.owned', 1, true) then
		fail('artifact lifetime should delegate ownership to devicecode.support.resource')
	end
end

function tests.test_update_service_code_finalises_request_owners_from_owning_scope()
	local saw_finaliser = false
	for _, path in ipairs(list_update_files()) do
		local s = read_file(path)
		if s:find('request_owner', 1, true) then
			if s:find('owner:terminate(', 1, true)
				or s:find('request_owner.new%([^\n]-%):terminate%s*%(') then
				fail('update service code should not use request_owner:terminate(reason): ' .. path)
			end
		end
		if s:find('finalise_unresolved', 1, true) then
			saw_finaliser = true
		end
	end
	if not saw_finaliser then
		fail('update service code should finalise unresolved request owners from owning-scope finalisers')
	end
end

function tests.test_update_production_code_uses_scoped_work_not_direct_target_spawn()
	for _, path in ipairs(list_update_files()) do
		local s = read_file(path)
		if s:find(':spawn(function', 1, true) then
			fail('direct target-scope spawn found in update service code: ' .. path)
		end
	end
end

function tests.test_artifact_resolver_is_only_imported_by_worker_modules()
	local forbidden = {
		'../src/services/update/service.lua',
		'../src/services/update/generation.lua',
		'../src/services/update/events.lua',
		'../src/services/update/generation_events.lua',
		'../src/services/update/manager.lua',
		'../src/services/update/active_runtime.lua',
		'../src/services/update/ingest.lua',
	}
	for _, path in ipairs(forbidden) do
		local src = read_file(path)
		if src:find("services.update.artifacts.resolver", 1, true) then
			fail('artifact resolver imported outside worker-owned modules: ' .. path)
		end
	end
	local resolver = read_file('../src/services/update/artifacts/resolver.lua')
	if not resolver:find('function M.resolve_worker', 1, true) then
		fail('artifact resolver should expose resolve_worker')
	end
	if resolver:find('function M.resolve%(', 1, false) then
		fail('artifact resolver should not expose ambiguous resolve() entry point')
	end
end

function tests.test_update_service_generation_boundary_uses_events_not_callbacks()
	local svc = read_file('../src/services/update/service.lua')
	local gen = read_file('../src/services/update/generation.lua')
	local mgr = read_file('../src/services/update/manager.lua')
	for label, s in pairs({ service = svc, generation = gen, manager = mgr }) do
		for _, needle in ipairs({ 'params.on_snapshot', 'params.on_model', '_on_snapshot', '_on_model', 'on_changed = function', 'ctx.on_changed', 'active_snapshot = function', 'ctx.snapshot()' }) do
			if s:find(needle, 1, true) then
				fail(label .. ' should use event ports rather than callback seam ' .. needle)
			end
		end
	end
	if not svc:find('generation_snapshot', 1, true) or not gen:find('events_tx', 1, true) then
		fail('generation snapshots should be reported through service events')
	end
end


function tests.test_bus_request_scoped_work_uses_caller_cancel_op()
	local mgr = read_file('../src/services/update/manager.lua')
	if not mgr:find('cancel_op = owner:caller_cancel_op()', 1, true) then
		fail('update manager scoped request work should use caller_cancel_op')
	end
	if not mgr:find('request_owner = owner', 1, true) then
		fail('update manager should pass its canonical request owner to request workers')
	end

	local reqs = read_file('../src/services/update/manager_requests.lua')
	if not reqs:find('params.request_owner', 1, true) then
		fail('manager_requests should reuse the manager-owned request owner')
	end

	local ingest = read_file('../src/services/update/ingest.lua')
	if not ingest:find('owner = request_owner.new(req)', 1, true) then
		fail('ingest should create request owners at queue admission')
	end
	if not ingest:find('cancel_op = entry.owner and entry.owner:caller_cancel_op()', 1, true) then
		fail('ingest scoped work should use caller_cancel_op')
	end
	if not ingest:find('entry_abandoned', 1, true) then
		fail('ingest should skip requests abandoned while queued')
	end
end

return tests
