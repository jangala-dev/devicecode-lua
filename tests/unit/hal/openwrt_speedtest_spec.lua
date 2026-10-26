local fibers = require 'fibers'
local op = require 'fibers.op'
local sleep = require 'fibers.sleep'
local exec = require 'fibers.io.exec'
local safe = require 'coxpcall'
local runfibers = require 'tests.support.run_fibers'
local speedtest = require 'services.hal.backends.network.providers.openwrt.speedtest'
local limits = require 'shared.speedtest'
local T = {}

local function fixture(options, fn)
	local original = exec.command
	local state = { shutdowns = 0, downloads = 0 }
	exec.command = function(spec)
		local version = spec[1] == 'curl'
		local output
		if version then output = options.version or 'curl 8.6.0 test\n'
		else
			state.downloads = state.downloads + 1
			state.spec = spec
			output = options.output or "Running 'curl test'\nSETUP,200,1.2\nRESULT,206,1048576,0.02,0.12\n"
			output = output:gsub('(SETUP,%d+,[%d%.]+)\n', '%1,' .. tostring(options.setup_exit_code or 0) .. '\n')
			output = output:gsub('(RESULT,%d+,[%d%.]+,[%d%.]+,[%d%.]+)\n',
				'%1,' .. tostring(options.curl_exit_code or options.exit_code or 0) .. '\n')
		end
		return {
			stdout_stream = function()
				return {core_read_op = function()
					return sleep.sleep_op(version and 0 or (options.delay or 0)):wrap(function()
						return output, #output, options.read_error
					end)
				end}
			end,
			run_op = function() return op.always('exited', version and 0 or (options.wrapper_exit_code or 0)) end,
			shutdown_op = function()
				state.shutdowns = state.shutdowns + 1
				return op.always('exited', 0)
			end,
		}
	end
	local ok, err = safe.pcall(function()
		runfibers.run(function() fn(state) end, { timeout = 10 })
	end)
	exec.command = original
	assert(ok, err)
end

local function run(req)
	return fibers.perform(speedtest.run_op(req or { interface = 'wan', device = 'vl-wan' }))
end

function T.test_payload_average_excludes_setup_and_lua_scheduling_delay()
	fixture({delay=1.5}, function(s)
		local r = run()
		assert(r.ok, r.err)
		assert(r.bytes == 1048576 and r.setup_s == 1.2 and r.total_duration_s >= 1.5)
		assert(math.abs(r.duration_s - 0.1) < 0.00001)
		assert(math.abs(r.mbps - 83.88608) < 0.00001)
		assert(r.peak_mbps == r.mbps and r.estimator == 'payload_average')
		assert(s.shutdowns == 2)
	end)
end

function T.test_byte_budget_setup_and_download_deadlines_are_separate()
	fixture({}, function(s)
		assert(run().ok)
		local argv = table.concat(s.spec, ' ')
		assert(argv:find('curl --disable', 1, true), 'ignore curlrc which could add transfers or retries')
		assert(argv:find('--globoff', 1, true), 'disable curl brace expansion')
		assert(argv:match('%-%-next.-%-%-globoff'), 'next resets per-transfer globoff')
		assert(argv:find('%{exitcode}', 1, true), 'read curl status, not the mwan wrapper status')
		assert(argv:find('--fail-early', 1, true), 'do not GET after failed setup')
		assert(argv:find('--head --max-time 5 --output /dev/null', 1, true))
		assert(argv:find('--range 0-1048575 --max-filesize 1048576 --max-time 1', 1, true))
	end)
end

function T.test_failed_http_download_is_not_a_speed_measurement()
	fixture({output="banner\nSETUP,200,0.1\nRESULT,429,0,0,0.1\n",exit_code=22}, function()
		local r=run()
		assert(not r.ok and r.code=='http_failed' and r.err:find('429',1,true))
	end)
end

function T.test_setup_timeout_survives_successful_mwan_exit()
	fixture({output="banner\nSETUP,000,5.0\n",setup_exit_code=28}, function()
		local r=run()
		assert(not r.ok and r.code=='setup_timeout' and r.err:find('curl exit: 28',1,true))
	end)
end

function T.test_failed_setup_is_not_a_speed_measurement()
	fixture({output="banner\nSETUP,429,0.1\n",exit_code=22}, function()
		local r=run()
		assert(not r.ok and r.code=='http_failed')
	end)
end

function T.test_background_interface_traffic_cannot_create_a_measurement()
	fixture({output="banner\nSETUP,200,0.1\nRESULT,200,0,0.02,1\n"}, function()
		local r=run()
		assert(not r.ok and r.code=='insufficient_data' and r.bytes==0)
	end)
end

function T.test_mwan_success_cannot_mask_curl_partial_failure()
	fixture({exit_code=0, curl_exit_code=18}, function()
		local r=run()
		assert(not r.ok and r.code=='speedtest_failed' and r.mbps==nil)
	end)
end

function T.test_partial_failed_download_is_rejected()
	fixture({exit_code=18}, function()
		local r=run()
		assert(not r.ok and r.code=='speedtest_failed' and r.mbps==nil)
	end)
end

function T.test_fast_budget_exhaustion_preserves_a_conservative_success()
	fixture({output="banner\nSETUP,200,0.1\nRESULT,206,1048576,0.02,0.03\n"}, function()
		local r=run()
		assert(r.ok and r.lower_bound == true and r.estimator == 'payload_lower_bound')
		assert(math.abs(r.mbps - 167.77216) < 0.00001)
		local policy = require 'services.net.wan_policy'
		local snapshot = {
			generation = 1,
			wan = { configured_members = {
				wan = { interface = 'wan', metric = 1 },
				sim = { interface = 'sim', metric = 1 },
			}, load_balancing = { speedtests = { enabled = true } } },
			backhaul = { uplinks = {
				wan = { interface = 'wan', device = 'eth1', state = 'online', usable = true },
				sim = { interface = 'sim', device = 'wwan0', state = 'online', usable = true },
			} },
			wan_runtime = { speedtests = {} },
		}
		for _, uplink in ipairs(policy.collect_uplinks(snapshot)) do
			local key = assert(policy.measurement_key(snapshot, uplink))
			snapshot.wan_runtime.speedtests[uplink.uplink_id] = {
				measurement_key = key, completed_at = 10,
				last_success = { mbps = uplink.uplink_id == 'wan' and r.mbps or 20,
					completed_at = 10, measurement_key = key },
			}
		end
		local weights = assert(policy.compute_weights(snapshot, 1, { now = 20 }))
		for _, member in ipairs(weights) do
			if member.id == 'wan' then assert(member.weight > 80 and not member.probe) end
		end

	end)
end

function T.test_get_deadline_uses_partial_payload_and_includes_idle_time()
	fixture({output="banner\nSETUP,200,0.1\nRESULT,206,65536,0.1,1\n",exit_code=28}, function()
		local r=run()
		assert(r.ok and r.stop_reason=='duration' and r.bytes==65536)
		assert(math.abs(r.mbps-65536*8/0.9/1000000)<0.00001)
	end)
end

function T.test_old_curl_cannot_start_unbounded_unknown_length_download()
	fixture({version='curl 8.3.0 test\n'}, function(s)
		local r=run()
		assert(not r.ok and r.code=='curl_unsupported' and s.downloads==0)
	end)
end

function T.test_oversized_or_malformed_output_is_rejected()
	for _,output in ipairs({
		"banner\nSETUP,200,0.1\nRESULT,206,2097152,0.02,0.12\n",
		"banner\nSETUP,200,0.1\nRESULT,206,1048576,0.2,0.12\n",
	}) do
		fixture({output=output}, function()
			local r=run()
			assert(not r.ok and r.code=='invalid_output')
		end)
	end
end

function T.test_worker_deadline_shuts_down_stalled_process()
	fixture({delay=8}, function(s)
		local r=run()
		assert(not r.ok and r.err=='speedtest_timeout' and s.shutdowns==2)
	end)
end

function T.test_cancellation_reaps_real_downloader()
	local original = exec.command
	local command
	local ready = require('fibers.pulse').new()
	local version = ready:version()
	exec.command = function(spec)
		if spec[1]=='curl' then return original({'printf','curl 8.6.0 test\n',stdout='pipe',stderr='null'}) end
		local fake = { 'sh', '-c', 'exec sleep 30' }
		for k,v in pairs(spec) do if type(k) ~= 'number' then fake[k]=v end end
		command = original(fake)
		local stdout_stream = command.stdout_stream
		command.stdout_stream = function(self)
			local stream, err = stdout_stream(self)
			ready:signal()
			return stream, err
		end
		return command
	end
	local ok, err = safe.pcall(function()
		runfibers.run(function()
			local which = fibers.perform(op.named_choice({
				work = speedtest.run_op({interface='wan'}),
				cancel = ready:changed_op(version),
			}))
			assert(which == 'cancel')
			local status = command:status()
			assert(status == 'exited' or status == 'signalled', status)
		end)
	end)
	exec.command = original
	assert(ok, err)
end

function T.test_duration_and_outer_budget_validation()
	assert(limits.duration(0/0) == 1)
	assert(limits.duration(math.huge) == 1)
	assert(limits.duration(-1) == 1)
	assert(limits.duration(0.5) == 0.5)
	assert(limits.timeout(1) == 7)
end

return T
