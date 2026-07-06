local busmod     = require 'bus'
local fibers     = require 'fibers'
local sleep      = require 'fibers.sleep'

local run_fibers = require 'tests.support.run_fibers'
local probe      = require 'tests.support.bus_probe'
local monitor    = require 'services.monitor'

local T = {}

local function assert_eq(a, b, msg)
	if a ~= b then error((msg or 'assertion failed') .. ': expected ' .. tostring(b) .. ', got ' .. tostring(a), 2) end
end

local function assert_true(v, msg)
	if not v then error(msg or 'assertion failed', 2) end
	return v
end

local function monitor_rpc(method)
	return { 'cap', 'monitor', 'main', 'rpc', method }
end

local function log_topic(service)
	return { 'obs', 'v1', service, 'event', 'log' }
end

local function start_monitor(scope, bus, opts)
	local root = bus:connect({ origin_base = { service = 'monitor-test-root' } })
	local ok, err = scope:spawn(function () monitor.start(root, opts or { env = 'test' }) end)
	assert_true(ok, tostring(err))
	local reader = bus:connect({ origin_base = { service = 'monitor-test-reader' } })
	probe.wait_retained_payload(reader, { 'cap', 'monitor', 'main' }, { timeout = 0.5 })
	return root, reader
end

local function publish_log(conn, service, level, what, summary)
	conn:publish(log_topic(service), {
		service = service,
		level = level or 'info',
		what = what,
		summary = summary or what,
	})
end

local function wait_summary_field(conn, pred, label)
	return probe.wait_until(function ()
		local p = conn:call(monitor_rpc('query-logs'), { limit = 0 }, { timeout = 0.05 })
		return p and p.summary and pred(p.summary)
	end, { timeout = 0.8, interval = 0.01 }) or error(label or 'summary condition not reached', 2)
end

function T.query_logs_respects_configured_boot_and_ring_buffers()
	run_fibers.run(function (scope)
		local b = busmod.new()
		local admin = b:connect({ origin_base = { service = 'monitor-test-admin' } })
		admin:retain({ 'cfg', 'monitor' }, { data = { storage = { boot_records = 5, ring_records = 3, boot_seconds = 0 } }, rev = 1 })
		local _, reader = start_monitor(scope, b, { env = 'test' })

		wait_summary_field(reader, function (s) return s.boot_max_records == 5 and s.ring_max_records == 3 and s.storage_source == 'config' end,
			'monitor storage config was not applied')

		for i = 1, 6 do publish_log(admin, 'alpha', 'info', 'record_' .. i, 'record ' .. i) end
		probe.wait_until(function ()
			local rep = reader:call(monitor_rpc('query-logs'), { service = 'alpha', limit = 10 }, { timeout = 0.05 })
			return rep and rep.count == 3
		end, { timeout = 0.8, interval = 0.01 })

		local ring = assert_true(reader:call(monitor_rpc('query-logs'), { service = 'alpha', limit = 10 }, { timeout = 0.2 }))
		assert_eq(ring.count, 3)
		assert_eq(ring.records[1].what, 'record_4')
		assert_eq(ring.records[3].what, 'record_6')

		-- The boot buffer stores the first N log records globally.  Because this
		-- test configures monitor through cfg/monitor before publishing alpha
		-- records, the monitor's own storage-configuration log legitimately
		-- consumes one boot-buffer slot.  Verify both the global cap and the
		-- filtered alpha view.
		local boot_all = assert_true(reader:call(monitor_rpc('query-logs'), { boot = true, limit = 10 }, { timeout = 0.2 }))
		assert_eq(boot_all.count, 5)
		local boot = assert_true(reader:call(monitor_rpc('query-logs'), { boot = true, service = 'alpha', limit = 10 }, { timeout = 0.2 }))
		assert_eq(boot.count, 4)
		assert_eq(boot.records[1].what, 'record_1')
		assert_eq(boot.records[4].what, 'record_4')
	end)
end

function T.query_logs_filters_by_level_service_since_and_text()
	run_fibers.run(function (scope)
		local b = busmod.new()
		local admin = b:connect({ origin_base = { service = 'monitor-test-admin' } })
		local _, reader = start_monitor(scope, b, { env = 'test' })

		publish_log(admin, 'alpha', 'debug', 'debug_one', 'debug detail')
		publish_log(admin, 'alpha', 'info', 'info_one', 'contains needle')
		publish_log(admin, 'beta', 'warn', 'warn_one', 'other warning')
		probe.wait_until(function ()
			local rep = reader:call(monitor_rpc('query-logs'), { service = 'alpha', min_level = 'debug', limit = 10 }, { timeout = 0.05 })
			return rep and rep.count == 2
		end, { timeout = 0.8, interval = 0.01 })

		local alpha_info = assert_true(reader:call(monitor_rpc('query-logs'), { service = 'alpha', min_level = 'info', limit = 10 }, { timeout = 0.2 }))
		assert_eq(alpha_info.count, 1)
		assert_eq(alpha_info.records[1].what, 'info_one')

		local text = assert_true(reader:call(monitor_rpc('query-logs'), { min_level = 'debug', contains = 'needle', limit = 10 }, { timeout = 0.2 }))
		assert_eq(text.count, 1)
		assert_eq(text.records[1].service, 'alpha')

		local since = assert_true(reader:call(monitor_rpc('query-logs'), { min_level = 'debug', since_id = alpha_info.records[1].id, limit = 10 }, { timeout = 0.2 }))
		assert_eq(since.count, 1)
		assert_eq(since.records[1].what, 'warn_one')
	end)
end

function T.follow_logs_replays_then_streams_matching_records()
	run_fibers.run(function (scope)
		local b = busmod.new()
		local admin = b:connect({ origin_base = { service = 'monitor-test-admin' } })
		local _, reader = start_monitor(scope, b, { env = 'test' })

		publish_log(admin, 'alpha', 'info', 'before_follow', 'before follow')
		probe.wait_until(function ()
			local rep = reader:call(monitor_rpc('query-logs'), { service = 'alpha', limit = 1 }, { timeout = 0.05 })
			return rep and rep.count == 1
		end, { timeout = 0.8, interval = 0.01 })

		local rep = assert_true(reader:call(monitor_rpc('follow-logs'), { service = 'alpha', min_level = 'info', limit = 5, replay = true }, { timeout = 0.2 }))
		assert_eq(rep.ok, true)
		assert_true(rep.feed, 'expected follow feed')

		local first = fibers.perform(rep.feed:recv_op())
		assert_eq(first.kind, 'log')
		assert_eq(first.replay, true)
		assert_eq(first.record.what, 'before_follow')
		local ready = fibers.perform(rep.feed:recv_op())
		assert_eq(ready.kind, 'ready')

		publish_log(admin, 'alpha', 'info', 'after_follow', 'after follow')
		local live = fibers.perform(rep.feed:recv_op())
		assert_eq(live.kind, 'log')
		assert_eq(live.replay, false)
		assert_eq(live.record.what, 'after_follow')
		rep.feed:close('test_done')
	end)
end

function T.set_profile_updates_retained_summary_and_raw_requires_restart()
	run_fibers.run(function (scope)
		local b = busmod.new()
		local _, reader = start_monitor(scope, b, { env = 'test' })

		local ok_rep = assert_true(reader:call(monitor_rpc('set-profile'), { profile = 'debug' }, { timeout = 0.2 }))
		assert_eq(ok_rep.ok, true)
		assert_eq(ok_rep.profile, 'debug')
		assert_eq(ok_rep.min_level, 'debug')

		probe.wait_until(function ()
			local rep = reader:call(monitor_rpc('query-logs'), { limit = 0 }, { timeout = 0.05 })
			return rep and rep.summary and rep.summary.profile == 'debug' and rep.summary.min_level == 'debug'
		end, { timeout = 0.8, interval = 0.01 })

		local raw_rep = assert_true(reader:call(monitor_rpc('set-profile'), { profile = 'raw' }, { timeout = 0.2 }))
		assert_eq(raw_rep.ok, false)
		assert_eq(raw_rep.err, 'raw_profile_requires_restart')
	end)
end

return T
