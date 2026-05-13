-- tests/unit/device/test_static.lua

local tests = {}

local function fail(msg) error(msg or 'assertion failed', 2) end
local function assert_false(v, msg) if v ~= false then fail(msg or ('expected false, got ' .. tostring(v))) end end

local files = {
	'../src/services/device.lua',
	'../src/services/device/service.lua',
	'../src/services/device/observer.lua',
	'../src/services/device/observer_manager.lua',
	'../src/services/device/action_manager.lua',
	'../src/services/device/action_worker.lua',
	'../src/services/device/model.lua',
	'../src/services/device/publisher.lua',
	'../src/services/device/projection.lua',
	'../src/services/device/catalogue.lua',
	'../src/services/device/component_mcu.lua',
	'../src/services/device/component_host.lua',
	'../src/services/device/topics.lua',
	'../src/services/device/availability.lua',
	'../src/services/device/fabric_stage.lua',
	'../src/services/device/backpressure.lua',
}

local function read(path)
	local f = assert(io.open(path, 'r'))
	local s = f:read('*a')
	f:close()
	return s
end

local function each_line(s)
	local lines = {}
	for line in (s .. '\n'):gmatch('([^\n]*)\n') do
		lines[#lines + 1] = line
	end
	return lines
end

local function finaliser_lines(path, s)
	local out = {}
	local in_finaliser = false
	local start_line = nil

	for i, line in ipairs(each_line(s)) do
		if not in_finaliser and line:find(':finally%s*%(%s*function', 1) then
			in_finaliser = true
			start_line = i
		end

		if in_finaliser then
			out[#out + 1] = { path = path, line_no = i, line = line, start_line = start_line }
			if line:match('^%s*end%)') then
				in_finaliser = false
				start_line = nil
			end
		end
	end

	return out
end

local function coordinator_lines(path, s)
	local out = {}
	local in_coord = false
	local start_line = nil
	local interesting = {
		'cancel_active_generation',
		'apply_config_payload',
		'reduce_event',
		'coordinator_loop',
		'flush_publication',
		'handle_observation',
		'handle_observer_done',
		'handle_action_done',
		'handle_generation_done',
	}

	for i, line in ipairs(each_line(s)) do
		if not in_coord then
			for _, name in ipairs(interesting) do
				if line:find('local%s+function%s+' .. name .. '%s*%(', 1) then
					in_coord = true
					start_line = i
					break
				end
			end
		end

		if in_coord then
			out[#out + 1] = { path = path, line_no = i, line = line, start_line = start_line }
			if line:match('^end$') then
				in_coord = false
				start_line = nil
			end
		end
	end

	return out
end

local function assert_no_waiting_cleanup_or_inline_join(records, label)
	for _, rec in ipairs(records) do
		local line = rec.line
		assert_false(line:find(':close_op%s*%(', 1) ~= nil,
			('%s in %s:%d calls close_op'):format(label, rec.path, rec.line_no))
		assert_false(line:find(':join_op%s*%(', 1) ~= nil,
			('%s in %s:%d calls join_op'):format(label, rec.path, rec.line_no))
		assert_false(line:find('perform_raw', 1, true) ~= nil,
			('%s in %s:%d calls perform_raw'):format(label, rec.path, rec.line_no))
	end
end

function tests.test_device_service_code_does_not_use_perform_raw()
	for _, path in ipairs(files) do
		local s = read(path)
		assert_false(s:find('perform_raw', 1, true) ~= nil, path .. ' uses perform_raw')
	end
end

function tests.test_device_finalisers_do_not_wait_or_join()
	for _, path in ipairs(files) do
		assert_no_waiting_cleanup_or_inline_join(finaliser_lines(path, read(path)), 'finaliser')
	end
end

function tests.test_device_coordinator_paths_do_not_close_or_join()
	for _, path in ipairs(files) do
		assert_no_waiting_cleanup_or_inline_join(coordinator_lines(path, read(path)), 'coordinator')
	end
end


function tests.test_device_service_uses_shared_config_watch_helper()
	local s = read('../src/services/device/service.lua')
	assert_false(s:find("devicecode.support.config_watch", 1, true) == nil,
		'device service should require the shared config_watch helper')
	assert_false(s:find("config_watch.open(conn, 'device'", 1, true) == nil,
		'device service should open cfg/device through config_watch.open')
end

function tests.test_device_generation_is_direct_scope_not_parked_scoped_work()
	local s = read('../src/services/device/service.lua')
	assert_false(s:find('park_generation_until_parent_closes', 1, true) ~= nil,
		'device generation still uses parked shell')
	assert_false(s:find("local scoped_work", 1, true) ~= nil,
		'device service should not use scoped_work for generation ownership')
	assert_false(s:find("kind = 'generation_done'", 1, true) ~= nil,
		'device generation should not report synthetic generation_done completions')
end

function tests.test_device_priority_path_is_admission_sensitive_not_global()
	local s = read('../src/services/device/service.lua')
	assert_false(s:find('return priority_event.sources_op', 1, true) == nil,
		'device service should still use priority_event for admission-sensitive cases')
	assert_false(s:find('has_actions and has_config', 1, true) == nil,
		'device priority path should be gated to action admission plus config')
	assert_false(s:find('device.next_event.admission_sensitive', 1, true) == nil,
		'device priority path should be labelled as admission-sensitive')
end


function tests.test_device_components_report_through_service_event_ports()
	local svc = read('../src/services/device/service.lua')
	assert_false(svc:find("devicecode.support.service_events", 1, true) == nil,
		'device service should create a service event port')
	assert_false(svc:find('events_port = service_events.port', 1, true) == nil,
		'device service should expose a stamped event port to child reporters')

	local action_manager = read('../src/services/device/action_manager.lua')
	assert_false(action_manager:find('service_events.reporter_for', 1, true) == nil,
		'action completions should use service_events.reporter_for')
	assert_false(action_manager:find('report = function (ev)', 1, true) ~= nil,
		'action manager should not install a parent callback-shaped report body')

	local observer_manager = read('../src/services/device/observer_manager.lua')
	assert_false(observer_manager:find('service_events.reporter_for', 1, true) == nil,
		'observer completions should use service_events.reporter_for')
	assert_false(observer_manager:find('report = function (ev)', 1, true) ~= nil,
		'observer manager should not install a parent callback-shaped report body')
end

function tests.test_device_uses_terminate_vocabulary_for_owned_resources()
	for _, path in ipairs(files) do
		local s = read(path)
		assert_false(s:find('close_source', 1, true) ~= nil, path .. ' still uses close_source')
		assert_false(s:find('on_cancel =', 1, true) ~= nil, path .. ' still passes ignored scoped_work on_cancel')
		assert_false(s:find('owned:close', 1, true) ~= nil, path .. ' still calls owned:close')
		assert_false(s:find('state.model:close', 1, true) ~= nil, path .. ' still terminates the model through close vocabulary')
	end
end

function tests.test_device_action_worker_uses_current_scope_spawn_for_timer()
	local s = read('../src/services/device/action_worker.lua')
	assert_false(s:find('scope:spawn(function', 1, true) ~= nil,
		'action_worker timeout helper should use fibers.spawn into the current scope')
	assert_false(s:find('fibers.spawn(function', 1, true) == nil,
		'action_worker should use fibers.spawn for its current-scope timer helper')
end

return tests
