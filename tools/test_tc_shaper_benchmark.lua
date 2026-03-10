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
--   * applies tc_u32_shaper for a series of subnets (/20, /21, /22, ...)
--   * times:
--       - cold apply (full build)
--       - no-op re-apply (same config, incremental path)
--       - delta class update (one host rate/ceil change; membership unchanged)
--       - delta fq_codel leaf update (one host fq change; membership unchanged)
--       - delta membership update (include_network=false -> true; membership changes)
--       - clear
--   * prints simple class-count sanity checks for dc0 and IFB
--
-- Notes:
--   * This benchmark does not need traffic; it measures apply-time only.
--   * Default all_hosts=true excludes network/broadcast for /0.. /30, so:
--       /20 => 4094 hosts
--       /21 => 2046 hosts
--       /22 => 1022 hosts
--   * The membership-delta step deliberately flips include_network=true to force
--     a membership change on an otherwise identical large plan.
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

-- Incremental delta timings
local ENABLE_DELTA_CLASS      = true
local ENABLE_DELTA_FQ         = true
local ENABLE_DELTA_MEMBERSHIP = true

-- Host used for single-host delta updates (must be inside all benchmark subnets)
local DELTA_HOST_IP = '10.12.0.2'

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
	safe.pcall(function() shaper.clear(DEV0, { ifb = IFB, delete_ifb = true }) end)
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

local function shallow_copy(t)
	local o = {}
	for k, v in pairs(t or {}) do o[k] = v end
	return o
end

local function clone_host_override(h)
	if type(h) ~= 'table' then return {} end
	local out = shallow_copy(h)
	if type(h.fq_codel) == 'table' then
		out.fq_codel = shallow_copy(h.fq_codel)
	end
	return out
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
			hosts              = {}, -- optional overrides; empty for baseline benchmark
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

local function set_host_override(spec, ip, override_tbl)
	override_tbl = clone_host_override(override_tbl)

	spec.egress.hosts[ip] = clone_host_override(override_tbl)
	if spec.ingress then
		spec.ingress.hosts[ip] = clone_host_override(override_tbl)
	end
end

local function set_include_network(spec, enabled)
	spec.egress.include_network = not not enabled
	if spec.ingress then
		spec.ingress.include_network = not not enabled
	end
end

local function benchmark_one_prefix(pfx)
	local cidr = ('10.12.0.0/%d'):format(pfx)
	local expected_hosts = host_count_for_prefix(pfx)
	local expected_classes_per_dev = expected_hosts + 4 -- root, pool, inner root, default
	local expected_membership_hosts = (pfx >= 31) and expected_hosts or (expected_hosts + 1)
	local expected_membership_classes_per_dev = expected_membership_hosts + 4

	local cold_times = {}
	local warm_times = {}
	local delta_class_times = {}
	local delta_fq_times = {}
	local delta_membership_times = {}
	local clear_times = {}

	local dc0_classes_last = nil
	local ifb_classes_last = nil

	for rep = 1, REPEATS do
		-- Ensure clean state for a cold build measurement.
		safe.pcall(function() shaper.clear(DEV0, { ifb = IFB, delete_ifb = true }) end)

		local base_spec = build_spec(cidr)

		-- Cold apply (full build)
		local t0 = now_s()
		local ok, err = shaper.apply(base_spec)
		local t1 = now_s()
		if not ok then
			error(('shaper.apply cold failed for %s (rep %d): %s'):format(cidr, rep, tostring(err)))
		end
		cold_times[#cold_times + 1] = (t1 - t0)

		-- No-op re-apply (same spec; exercises incremental path)
		local t2 = now_s()
		ok, err = shaper.apply(base_spec)
		local t3 = now_s()
		if not ok then
			error(('shaper.apply warm failed for %s (rep %d): %s'):format(cidr, rep, tostring(err)))
		end
		warm_times[#warm_times + 1] = (t3 - t2)

		-- Class-count sanity check after no-op warm apply (baseline shape)
		do
			local n0 = count_htb_classes(DEV0)
			dc0_classes_last = n0
			if n0 ~= expected_classes_per_dev then
				error(('dc0 class count mismatch after warm apply for %s (rep %d): got %d expected %d')
					:format(cidr, rep, n0, expected_classes_per_dev))
			end

			if ENABLE_INGRESS then
				local n1 = count_htb_classes(IFB)
				ifb_classes_last = n1
				if n1 ~= expected_classes_per_dev then
					error(('ifb class count mismatch after warm apply for %s (rep %d): got %d expected %d')
						:format(cidr, rep, n1, expected_classes_per_dev))
				end
			else
				ifb_classes_last = nil
			end
		end

		-- Delta: one host class change (rate/ceil only; membership unchanged)
		local spec_after_class = base_spec
		if ENABLE_DELTA_CLASS then
			spec_after_class = build_spec(cidr)
			set_host_override(spec_after_class, DELTA_HOST_IP, {
				rate = '3mbit',
				ceil = '3mbit',
			})

			local t4 = now_s()
			ok, err = shaper.apply(spec_after_class)
			local t5 = now_s()
			if not ok then
				error(('shaper.apply delta-class failed for %s (rep %d): %s'):format(cidr, rep, tostring(err)))
			end
			delta_class_times[#delta_class_times + 1] = (t5 - t4)
		end

		-- Delta: one host fq_codel leaf change (membership unchanged)
		-- Keep class override identical to the previous step so this is fq-focused.
		local spec_after_fq = spec_after_class
		if ENABLE_DELTA_FQ then
			spec_after_fq = build_spec(cidr)

			local host_override = {
				rate = '3mbit',
				ceil = '3mbit',
			}

			if ENABLE_PER_HOST_FQ_CODEL then
				-- Global fq_codel is already present; override one host to force a single leaf change.
				host_override.fq_codel = {
					flows = 128, -- differs from global 64
				}
			else
				-- Global fq_codel disabled; create a single per-host leaf.
				host_override.fq_codel = {
					flows = 64,
					limit = 256,
					memory_limit = '1Mb',
					target = '5ms',
					interval = '100ms',
					ecn = true,
				}
			end

			set_host_override(spec_after_fq, DELTA_HOST_IP, host_override)

			local t6 = now_s()
			ok, err = shaper.apply(spec_after_fq)
			local t7 = now_s()
			if not ok then
				error(('shaper.apply delta-fq failed for %s (rep %d): %s'):format(cidr, rep, tostring(err)))
			end
			delta_fq_times[#delta_fq_times + 1] = (t7 - t6)
		end

		-- Delta: membership change (forces host-filter rebuild path)
		-- Flip include_network=false -> true on an otherwise identical plan.
		-- This adds exactly one host for /0.. /30 and should exercise:
		--   * host filter rebuild (membership changed)
		--   * minimal class delta (one host added)
		local spec_after_membership = spec_after_fq
		if ENABLE_DELTA_MEMBERSHIP then
			spec_after_membership = build_spec(cidr)

			-- Preserve prior single-host override(s) so the only structural change is membership.
			local host_override = {
				rate = '3mbit',
				ceil = '3mbit',
			}
			if ENABLE_DELTA_FQ then
				if ENABLE_PER_HOST_FQ_CODEL then
					host_override.fq_codel = { flows = 128 }
				else
					host_override.fq_codel = {
						flows = 64,
						limit = 256,
						memory_limit = '1Mb',
						target = '5ms',
						interval = '100ms',
						ecn = true,
					}
				end
			end
			set_host_override(spec_after_membership, DELTA_HOST_IP, host_override)

			set_include_network(spec_after_membership, true)

			local t8 = now_s()
			ok, err = shaper.apply(spec_after_membership)
			local t9 = now_s()
			if not ok then
				error(('shaper.apply delta-membership failed for %s (rep %d): %s'):format(cidr, rep, tostring(err)))
			end
			delta_membership_times[#delta_membership_times + 1] = (t9 - t8)

			-- Sanity check membership-changed class count
			local n0m = count_htb_classes(DEV0)
			if n0m ~= expected_membership_classes_per_dev then
				error(('dc0 class count mismatch after membership delta for %s (rep %d): got %d expected %d')
					:format(cidr, rep, n0m, expected_membership_classes_per_dev))
			end
			if ENABLE_INGRESS then
				local n1m = count_htb_classes(IFB)
				if n1m ~= expected_membership_classes_per_dev then
					error(('ifb class count mismatch after membership delta for %s (rep %d): got %d expected %d')
						:format(cidr, rep, n1m, expected_membership_classes_per_dev))
				end
			end
		end

		-- Clear
		local t10 = now_s()
		ok, err = shaper.clear(DEV0, { ifb = IFB, delete_ifb = true })
		local t11 = now_s()
		if not ok then
			error(('shaper.clear failed for %s (rep %d): %s'):format(cidr, rep, tostring(err)))
		end
		clear_times[#clear_times + 1] = (t11 - t10)
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

		delta_class_mean = mean(delta_class_times),
		delta_class_min = minv(delta_class_times),
		delta_class_max = maxv(delta_class_times),

		delta_fq_mean = mean(delta_fq_times),
		delta_fq_min = minv(delta_fq_times),
		delta_fq_max = maxv(delta_fq_times),

		delta_membership_mean = mean(delta_membership_times),
		delta_membership_min = minv(delta_membership_times),
		delta_membership_max = maxv(delta_membership_times),

		clear_mean = mean(clear_times),
		clear_min = minv(clear_times),
		clear_max = maxv(clear_times),

		dc0_classes = dc0_classes_last,
		ifb_classes = ifb_classes_last,
	}
end

local function fmt_time(enabled, v)
	if not enabled then return '-' end
	return string.format('%.3fs', v or 0)
end

local function print_result_row(r)
	local ifb_part = ENABLE_INGRESS and tostring(r.ifb_classes or 0) or '-'
	say(string.format(
		'%-15s hosts=%-5d exp=%-5d dc0=%-5s ifb=%-5s cold=%s warm=%s dcls=%s dfq=%s dmem=%s clr=%s',
		r.cidr,
		r.expected_hosts,
		r.expected_classes_per_dev,
		tostring(r.dc0_classes or 0),
		ifb_part,
		fmt_time(true, r.cold_mean),
		fmt_time(true, r.warm_mean),
		fmt_time(ENABLE_DELTA_CLASS, r.delta_class_mean),
		fmt_time(ENABLE_DELTA_FQ, r.delta_fq_mean),
		fmt_time(ENABLE_DELTA_MEMBERSHIP, r.delta_membership_mean),
		fmt_time(true, r.clear_mean)
	))
end

local function print_summary_table(results)
	section('Benchmark summary')
	say('repeats:', REPEATS,
		' ingress:', tostring(ENABLE_INGRESS),
		' per_host_fq_codel:', tostring(ENABLE_PER_HOST_FQ_CODEL),
		' default_fq_codel:', tostring(ENABLE_DEFAULT_FQ_CODEL))
	say('delta_class:', tostring(ENABLE_DELTA_CLASS),
		' delta_fq:', tostring(ENABLE_DELTA_FQ),
		' delta_membership:', tostring(ENABLE_DELTA_MEMBERSHIP))
	say('delta_host_ip:', DELTA_HOST_IP)
	say('')

	for i = 1, #results do
		print_result_row(results[i])
	end

	say('')
	say('Columns:')
	say('  hosts       = all_hosts count (default excludes network/broadcast for /0../30)')
	say('  exp         = expected HTB classes per shaped device at baseline (hosts + 4 scaffold classes)')
	say('  dc0/ifb     = observed HTB class counts after warm no-op apply (baseline shape)')
	say('  cold        = first apply on clean interface')
	say('  warm        = immediate re-apply of identical spec')
	say('  dcls        = one-host class delta (rate/ceil only, membership unchanged)')
	say('  dfq         = one-host fq_codel leaf delta (membership unchanged)')
	say('  dmem        = membership delta (include_network=false -> true), triggers host-filter rebuild path')
	say('  clr         = shaper.clear time')
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
