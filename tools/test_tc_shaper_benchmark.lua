-- test_tc_shaper_benchmark.lua
-- Lua 5.1 / LuaJIT
--
-- Requires:
--   * tc_u32_shaper.lua (via services.hal.backends.tc_u32_shaper on package.path)
--   * fibers + fibers.io.exec + fibers.runtime
--   * ip (with netns), tc
--
-- What it does:
--   * creates a veth pair dc0 <-> dc1 (dc1 moved into a netns)
--   * applies tc_u32_shaper with all_hosts=true for a series of subnets (/20, /21, /22, ...)
--   * times:
--       - cold apply (full build)
--       - no-op re-apply (same config, incremental path)
--       - clear
--   * prints simple class-count sanity checks for dc0 and IFB
--
-- Notes:
--   * This benchmark does not need traffic; it measures apply-time only.
--   * By default, all_hosts=true excludes network/broadcast for /0.. /30, so:
--       /20 => 4094 hosts
--       /21 => 2046 hosts
--       /22 => 1022 hosts
--   * You can tune the constants below (prefix list, repeats, fq_codel on/off).

package.path = '../src/?.lua;' .. package.path

local safe      = require 'coxpcall'

local fibers    = require 'fibers'
local exec_mod  = require 'fibers.io.exec'
local performer = require 'fibers.performer'
local runtime   = require 'fibers.runtime'
local shaper    = require 'services.hal.backends.tc_u32_shaper'

local perform   = performer.perform
local unpack    = unpack or table.unpack

-- Bench configuration ---------------------------------------------------------

local NS        = 'dcns_tc_bench'
local DEV0      = 'dc0'
local DEV1      = 'dc1'
local IFB       = 'ifb_dc0'

-- Prefixes to benchmark (edit as needed)
local PREFIXES  = { 20, 21, 22, 23, 24 }

-- Repeat each prefix this many times (averages are printed)
local REPEATS   = 1

-- Toggle per-host fq_codel creation (significant extra cost when true)
local ENABLE_PER_HOST_FQ_CODEL = true

-- Toggle default (unmatched) class fq_codel
local ENABLE_DEFAULT_FQ_CODEL = false

-- Also benchmark ingress(IFB). Set false to benchmark egress only.
local ENABLE_INGRESS = true

-------------------------------------------------------------------------------

local function run_cmd(argv)
	local cmd = exec_mod.command(unpack(argv))
	local out, st, code, sig, err = perform(cmd:combined_output_op())
	local ok = (st == 'exited' and code == 0)
	return ok, out or '', err, code, st, sig
end

local function try_cmd(argv)
	return run_cmd(argv)
end

local function must_cmd(argv, label)
	local ok, out, err, code = run_cmd(argv)
	if not ok then
		error((label or table.concat(argv, ' ')) .. ': ' .. tostring(err or out or ('exit ' .. tostring(code))), 1)
	end
	return out
end

local function say(...)
	local parts = {}
	for i = 1, select('#', ...) do
		parts[#parts + 1] = tostring(select(i, ...))
	end
	io.stdout:write(table.concat(parts, ' ') .. '\n')
end

local function section(name)
	say(('='):rep(78))
	say(name)
	say(('='):rep(78))
end

local function now_s()
	-- fibers.runtime.now() is monotonic and suitable for timings.
	return runtime.now()
end

local function mean(xs)
	if #xs == 0 then return 0 end
	local s = 0
	for i = 1, #xs do s = s + xs[i] end
	return s / #xs
end

local function minv(xs)
	if #xs == 0 then return 0 end
	local m = xs[1]
	for i = 2, #xs do
		if xs[i] < m then m = xs[i] end
	end
	return m
end

local function maxv(xs)
	if #xs == 0 then return 0 end
	local m = xs[1]
	for i = 2, #xs do
		if xs[i] > m then m = xs[i] end
	end
	return m
end

local function host_count_for_prefix(pfx)
	local total = 2 ^ (32 - pfx)
	if pfx >= 31 then
		return total
	end
	return total - 2 -- default all_hosts skips network+broadcast
end

local function count_htb_classes(dev)
	local out = must_cmd({ 'tc', 'class', 'show', 'dev', dev }, 'tc class show ' .. dev)
	local n = 0
	for line in tostring(out):gmatch('[^\r\n]+') do
		if line:match('^class%s+htb%s+') then
			n = n + 1
		end
	end
	return n, out
end

local function cleanup()
	-- Best-effort cleanup; ignore failures.
	pcall(function() shaper.clear(DEV0, { ifb = IFB, delete_ifb = true }) end)
	try_cmd({ 'ip', 'link', 'del', DEV0 })
	try_cmd({ 'ip', 'netns', 'del', NS })
end

local function setup_once()
	section('Cleanup any leftovers')
	cleanup()

	section('Sanity checks')
	must_cmd({ 'id', '-u' }, 'id -u')
	must_cmd({ 'ip', '-V' }, 'ip -V')
	must_cmd({ 'tc', '-V' }, 'tc -V')

	section('Set up veth + netns')
	must_cmd({ 'ip', 'netns', 'add', NS }, 'ip netns add')
	must_cmd({ 'ip', 'link', 'add', DEV0, 'type', 'veth', 'peer', 'name', DEV1 }, 'ip link add veth')
	must_cmd({ 'ip', 'link', 'set', DEV1, 'netns', NS }, 'move peer to netns')

	-- A single address pair is enough; benchmark is measuring apply-time, not traffic.
	must_cmd({ 'ip', 'addr', 'add', '10.12.0.1/20', 'dev', DEV0 }, 'addr add dc0')
	must_cmd({ 'ip', 'link', 'set', DEV0, 'up' }, 'link up dc0')

	must_cmd({ 'ip', 'netns', 'exec', NS, 'ip', 'link', 'set', 'lo', 'up' }, 'netns lo up')
	must_cmd({ 'ip', 'netns', 'exec', NS, 'ip', 'addr', 'add', '10.12.0.2/20', 'dev', DEV1 }, 'addr add dc1')
	must_cmd({ 'ip', 'netns', 'exec', NS, 'ip', 'link', 'set', DEV1, 'up' }, 'link up dc1')
end

local function build_spec(cidr)
	local fq_cfg = nil
	local default_fq = nil

	if ENABLE_PER_HOST_FQ_CODEL then
		fq_cfg = {
			flows = 64,
			limit = 256,
			memory_limit = '1Mb',
			target = '5ms',
			interval = '100ms',
			ecn = true,
		}
	end

	if ENABLE_DEFAULT_FQ_CODEL then
		default_fq = {
			flows = 64,
			limit = 256,
			memory_limit = '1Mb',
			target = '5ms',
			interval = '100ms',
			ecn = true,
		}
	end

	local spec = {
		iface   = DEV0,
		subnet  = cidr,

		log     = function(level, payload)
			-- Keep output quiet by default. Uncomment if debugging.
			-- if level == 'warn' or level == 'error' then
			-- 	say('[', level, ']', tostring(payload and payload.what or ''), tostring(payload and payload.err or ''))
			-- end
			local _ = level
			local __ = payload
		end,

		egress  = {
			enabled            = true,
			match              = 'dst',
			pool_rate          = '100mbit',
			pool_ceil          = '100mbit',
			host_rate          = '2mbit',
			host_ceil          = '2mbit',
			host_burst         = '16k',
			host_cburst        = '16k',
			default_rate       = '100mbit',
			default_ceil       = '100mbit',
			all_hosts          = true,
			include_network    = false,
			include_broadcast  = false,
			fq_codel           = fq_cfg,
			default_fq_codel   = default_fq,
			hosts              = {}, -- optional overrides; empty for benchmark
		},
	}

	if ENABLE_INGRESS then
		spec.ingress = {
			enabled            = true,
			ifb                = IFB,
			match              = 'src',
			pool_rate          = '100mbit',
			pool_ceil          = '100mbit',
			host_rate          = '2mbit',
			host_ceil          = '2mbit',
			host_burst         = '16k',
			host_cburst        = '16k',
			default_rate       = '100mbit',
			default_ceil       = '100mbit',
			all_hosts          = true,
			include_network    = false,
			include_broadcast  = false,
			fq_codel           = fq_cfg,
			default_fq_codel   = default_fq,
			hosts              = {},
		}
	end

	return spec
end

local function benchmark_one_prefix(pfx)
	local cidr = ('10.12.0.0/%d'):format(pfx)
	local expected_hosts = host_count_for_prefix(pfx)
	local expected_classes_per_dev = expected_hosts + 4 -- root, pool, inner root, default

	local cold_times = {}
	local warm_times = {}
	local clear_times = {}

	local dc0_classes_last = nil
	local ifb_classes_last = nil

	for rep = 1, REPEATS do
		-- Ensure clean state for a cold build measurement.
		pcall(function() shaper.clear(DEV0, { ifb = IFB, delete_ifb = true }) end)

		local spec = build_spec(cidr)

		-- Cold apply (full build)
		local t0 = now_s()
		local ok, err = shaper.apply(spec)
		local t1 = now_s()
		if not ok then
			error(('shaper.apply cold failed for %s (rep %d): %s'):format(cidr, rep, tostring(err)))
		end
		cold_times[#cold_times + 1] = (t1 - t0)

		-- No-op re-apply (same spec; exercises incremental path)
		local t2 = now_s()
		ok, err = shaper.apply(spec)
		local t3 = now_s()
		if not ok then
			error(('shaper.apply warm failed for %s (rep %d): %s'):format(cidr, rep, tostring(err)))
		end
		warm_times[#warm_times + 1] = (t3 - t2)

		-- Class-count sanity check (performed after warm apply)
		local n0 = count_htb_classes(DEV0)
		dc0_classes_last = n0
		if ENABLE_INGRESS then
			local n1 = count_htb_classes(IFB)
			ifb_classes_last = n1
		else
			ifb_classes_last = nil
		end

		-- Clear
		local t4 = now_s()
		ok, err = shaper.clear(DEV0, { ifb = IFB, delete_ifb = true })
		local t5 = now_s()
		if not ok then
			error(('shaper.clear failed for %s (rep %d): %s'):format(cidr, rep, tostring(err)))
		end
		clear_times[#clear_times + 1] = (t5 - t4)
	end

	return {
		cidr = cidr,
		pfx = pfx,
		expected_hosts = expected_hosts,
		expected_classes_per_dev = expected_classes_per_dev,
		cold_mean = mean(cold_times),
		cold_min = minv(cold_times),
		cold_max = maxv(cold_times),
		warm_mean = mean(warm_times),
		warm_min = minv(warm_times),
		warm_max = maxv(warm_times),
		clear_mean = mean(clear_times),
		clear_min = minv(clear_times),
		clear_max = maxv(clear_times),
		dc0_classes = dc0_classes_last,
		ifb_classes = ifb_classes_last,
	}
end

local function print_result_row(r)
	local ifb_part = ENABLE_INGRESS and tostring(r.ifb_classes or 0) or '-'
	say(
		string.format(
			'%-15s hosts=%-5d exp_cls/dev=%-5d dc0_cls=%-5s ifb_cls=%-5s cold=%.3fs warm=%.3fs clear=%.3fs',
			r.cidr,
			r.expected_hosts,
			r.expected_classes_per_dev,
			tostring(r.dc0_classes or 0),
			ifb_part,
			r.cold_mean,
			r.warm_mean,
			r.clear_mean
		)
	)
end

local function print_summary_table(results)
	section('Benchmark summary')
	say('repeats:', REPEATS,
		' ingress:', tostring(ENABLE_INGRESS),
		' per_host_fq_codel:', tostring(ENABLE_PER_HOST_FQ_CODEL),
		' default_fq_codel:', tostring(ENABLE_DEFAULT_FQ_CODEL))
	say('')

	for i = 1, #results do
		print_result_row(results[i])
	end

	say('')
	say('Columns:')
	say('  hosts         = all_hosts count (default excludes network/broadcast for /0../30)')
	say('  exp_cls/dev   = expected HTB classes per shaped device (hosts + 4 scaffold classes)')
	say('  dc0_cls/ifb_cls = observed HTB class counts from tc class show')
	say('  cold          = first apply on clean interface')
	say('  warm          = immediate re-apply of identical spec')
	say('  clear         = shaper.clear time')
end

local function main()
	setup_once()

	section('Run benchmark')
	local results = {}

	for i = 1, #PREFIXES do
		local pfx = PREFIXES[i]
		local r = benchmark_one_prefix(pfx)
		results[#results + 1] = r
		print_result_row(r)
	end

	print_summary_table(results)
end

fibers.run(function()
	local ok, err = safe.xpcall(main, debug.traceback)
	section('Cleanup')
	cleanup()
	if not ok then
		io.stderr:write(tostring(err) .. '\n')
		os.exit(1)
	end
end)
