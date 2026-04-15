-- test_tc_shaper_benchmark_veth.lua
-- Lua 5.1 / LuaJIT
--
-- Benchmarks two shaper implementations on a veth+netns setup:
--   * services.hal.backends.tc_u32_shaper              (incremental)
--   * services.hal.backends.tc_u32_shaper_declarative  (declarative)
--
-- Key property:
--   Command counting is done by wrapping exec_mod.command() only.
--   The returned Command object is left untouched, so stdout/stderr pipes
--   still follow the normal fibers.io.exec lifecycle and are closed correctly.
--
-- Optional env:
--   BENCH_COLD=5
--   BENCH_NOOP=20
--   BENCH_TOGGLE=20
--   BENCH_FD_DEBUG=1         (prints /proc/self/fd count after each sample)
--
-- Requires:
--   * fibers
--   * fibers.io.exec
--   * ip (with netns), tc
--
-- Run as root.

package.path             = '../src/?.lua;' .. package.path

local safe               = require 'coxpcall'

local fibers             = require 'fibers'
local runtime            = require 'fibers.runtime'
local exec_mod           = require 'fibers.io.exec'
local performer          = require 'fibers.performer'

local perform            = performer.perform
local unpack_            = unpack or table.unpack

local shaper_inc         = require 'services.hal.backends.tc_u32_shaper'
local ok_dec, shaper_dec = pcall(require, 'services.hal.backends.tc_u32_shaper_declarative')

local NS                 = 'dcns_tc'
local DEV0               = 'dc0'
local DEV1               = 'dc1'
local IFB                = 'ifb_dc0'
local SUBNET             = '10.12.0.0/20'

local ROUNDS_COLD        = tonumber(os.getenv('BENCH_COLD')) or 5
local ROUNDS_NOOP        = tonumber(os.getenv('BENCH_NOOP')) or 20
local ROUNDS_TOGGLE      = tonumber(os.getenv('BENCH_TOGGLE')) or 20
local FD_DEBUG           = (os.getenv('BENCH_FD_DEBUG') == '1')

------------------------------------------------------------------------
-- Exec helpers
------------------------------------------------------------------------

local function run_cmd(argv)
	local spec = {
		stdin  = 'null',
		stdout = 'pipe',
		stderr = 'stdout',
	}
	for i = 1, #argv do
		spec[i] = argv[i]
	end

	local cmd = exec_mod.command(spec)
	local out, st, code, sig, err = perform(cmd:output_op())
	local ok = (st == 'exited' and code == 0)
	return ok, out or '', err, code, st, sig
end

local function try_cmd(argv)
	return run_cmd(argv)
end

local function must_cmd(argv, label)
	local ok, out, err, code = run_cmd(argv)
	if not ok then
		print("out", out)
		print("code", code)
		for _, v in ipairs(argv) do print(v) end
		error((label or table.concat(argv, ' ')) .. ': ' .. tostring(err or out or ('exit ' .. tostring(code))), 2)
	end
	return out
end

------------------------------------------------------------------------
-- Output helpers
------------------------------------------------------------------------

local function say(...)
	local parts = {}
	for i = 1, select('#', ...) do
		parts[#parts + 1] = tostring(select(i, ...))
	end
	io.stdout:write(table.concat(parts, ' ') .. '\n')
end

local function section(name)
	say(('='):rep(72))
	say(name)
	say(('='):rep(72))
end

local function subheading(name)
	say(('-'):rep(72))
	say(name)
	say(('-'):rep(72))
end

------------------------------------------------------------------------
-- Optional FD debug helper (best-effort; not part of command counts)
------------------------------------------------------------------------

local function fd_count()
	if not FD_DEBUG then return nil end
	local p = io.popen('ls /proc/self/fd 2>/dev/null | wc -l', 'r')
	if not p then return nil end
	local s = p:read('*a')
	p:close()
	return tonumber((s or ''):match('(%d+)'))
end

------------------------------------------------------------------------
-- Safe command counting wrapper (constructor-only)
------------------------------------------------------------------------

local ORIG_EXEC_COMMAND = exec_mod.command
local counter_patch_installed = false

local function new_counter()
	return {
		total = 0,
		by_bin = {},
		tc_subcmd = {},
		ip_subcmd = {},
	}
end

local function inc_map(t, k)
	t[k] = (t[k] or 0) + 1
end

local function install_counter(counter)
	if counter_patch_installed then
		error('counter patch already installed', 2)
	end
	counter_patch_installed = true

	exec_mod.command = function(...)
		local cmd = ORIG_EXEC_COMMAND(...)
		local argv = cmd:argv()

		counter.total = counter.total + 1

		local bin = argv[1] or '?'
		inc_map(counter.by_bin, bin)

		if bin == 'tc' and argv[2] then
			inc_map(counter.tc_subcmd, argv[2])
		elseif bin == 'ip' and argv[2] then
			inc_map(counter.ip_subcmd, argv[2])
		end

		return cmd
	end

	local restored = false
	return function()
		if restored then return end
		restored = true
		exec_mod.command = ORIG_EXEC_COMMAND
		counter_patch_installed = false
	end
end

------------------------------------------------------------------------
-- Bench stat helpers
------------------------------------------------------------------------

local function sorted_keys(t)
	local ks = {}
	for k in pairs(t or {}) do ks[#ks + 1] = k end
	table.sort(ks, function(a, b) return tostring(a) < tostring(b) end)
	return ks
end

local function stats_new()
	return {
		n = 0,
		dt_sum = 0.0,
		dt_min = math.huge,
		dt_max = 0.0,

		cmds_sum = 0,
		by_bin_sum = {},
		tc_subcmd_sum = {},
		ip_subcmd_sum = {},
	}
end

local function stats_add(s, dt_s, counter)
	s.n = s.n + 1
	s.dt_sum = s.dt_sum + dt_s
	if dt_s < s.dt_min then s.dt_min = dt_s end
	if dt_s > s.dt_max then s.dt_max = dt_s end

	s.cmds_sum = s.cmds_sum + (counter.total or 0)

	for k, v in pairs(counter.by_bin or {}) do
		s.by_bin_sum[k] = (s.by_bin_sum[k] or 0) + v
	end
	for k, v in pairs(counter.tc_subcmd or {}) do
		s.tc_subcmd_sum[k] = (s.tc_subcmd_sum[k] or 0) + v
	end
	for k, v in pairs(counter.ip_subcmd or {}) do
		s.ip_subcmd_sum[k] = (s.ip_subcmd_sum[k] or 0) + v
	end
end

local function fmt_avg_map(m, n)
	local ks = sorted_keys(m)
	local parts = {}
	for i = 1, #ks do
		local k = ks[i]
		parts[#parts + 1] = tostring(k) .. '=' .. string.format('%.2f', (m[k] or 0) / n)
	end
	return (#parts > 0) and table.concat(parts, ', ') or '-'
end

local function stats_print(label, s)
	if s.n <= 0 then
		say(label)
		say('  samples:    0')
		return
	end

	say(label)
	say('  samples:    ', s.n)
	say('  time avg:   ', string.format('%.3f ms', (s.dt_sum / s.n) * 1000.0))
	say('  time min:   ', string.format('%.3f ms', s.dt_min * 1000.0))
	say('  time max:   ', string.format('%.3f ms', s.dt_max * 1000.0))
	say('  cmds avg:   ', string.format('%.2f', s.cmds_sum / s.n))
	say('  by bin:     ', fmt_avg_map(s.by_bin_sum, s.n))
	say('  tc subcmd:  ', fmt_avg_map(s.tc_subcmd_sum, s.n))
	say('  ip subcmd:  ', fmt_avg_map(s.ip_subcmd_sum, s.n))
end

------------------------------------------------------------------------
-- Shaper spec builders
------------------------------------------------------------------------

local function mk_logger()
	return function(level, payload)
		if level == 'warn' or level == 'error' then
			say(
				'[', level, ']',
				tostring(payload and payload.what or ''),
				tostring(payload and payload.label or ''),
				tostring(payload and payload.cmd or ''),
				tostring(payload and payload.err or ''),
				tostring(payload and payload.out or '')
			)
		end
	end
end

local function base_spec()
	return {
		iface   = DEV0,
		subnet  = SUBNET,
		log     = mk_logger(),

		egress  = {
			enabled     = true,
			match       = 'dst',
			pool_rate   = '100mbit',
			pool_ceil   = '100mbit',
			host_rate   = '2mbit',
			host_ceil   = '2mbit',
			host_burst  = '16k',
			host_cburst = '16k',
			fq_codel    = {
				flows = 64,
				limit = 256,
				-- memory_limit omitted for broader OpenWrt compatibility
				target = '5ms',
				interval = '100ms',
				ecn = true,
			},
			hosts       = {
				['10.12.0.2']  = { rate = '1mbit', ceil = '1mbit' },
				['10.12.15.2'] = { rate = '3mbit', ceil = '3mbit' },
			},
		},

		ingress = {
			enabled     = true,
			ifb         = IFB,
			match       = 'src', -- veth test replies source-match on IFB
			pool_rate   = '100mbit',
			pool_ceil   = '100mbit',
			host_rate   = '2mbit',
			host_ceil   = '2mbit',
			host_burst  = '16k',
			host_cburst = '16k',
			fq_codel    = {
				flows = 64,
				limit = 256,
				-- memory_limit omitted for broader OpenWrt compatibility
				target = '5ms',
				interval = '100ms',
				ecn = true,
			},
			hosts       = {
				['10.12.0.2']  = { rate = '1mbit', ceil = '1mbit' },
				['10.12.15.2'] = { rate = '3mbit', ceil = '3mbit' },
			},
		},
	}
end

-- Toggle only host limits (same membership) to exercise incremental updates.
local function toggled_spec()
	return {
		iface   = DEV0,
		subnet  = SUBNET,
		log     = mk_logger(),

		egress  = {
			enabled     = true,
			match       = 'dst',
			pool_rate   = '100mbit',
			pool_ceil   = '100mbit',
			host_rate   = '2mbit',
			host_ceil   = '2mbit',
			host_burst  = '16k',
			host_cburst = '16k',
			fq_codel    = {
				flows = 64,
				limit = 256,
				target = '5ms',
				interval = '100ms',
				ecn = true,
			},
			hosts       = {
				['10.12.0.2']  = { rate = '1500kbit', ceil = '1500kbit' },
				['10.12.15.2'] = { rate = '2500kbit', ceil = '2500kbit' },
			},
		},

		ingress = {
			enabled     = true,
			ifb         = IFB,
			match       = 'src',
			pool_rate   = '100mbit',
			pool_ceil   = '100mbit',
			host_rate   = '2mbit',
			host_ceil   = '2mbit',
			host_burst  = '16k',
			host_cburst = '16k',
			fq_codel    = {
				flows = 64,
				limit = 256,
				target = '5ms',
				interval = '100ms',
				ecn = true,
			},
			hosts       = {
				['10.12.0.2']  = { rate = '1500kbit', ceil = '1500kbit' },
				['10.12.15.2'] = { rate = '2500kbit', ceil = '2500kbit' },
			},
		},
	}
end

------------------------------------------------------------------------
-- Network setup / teardown
------------------------------------------------------------------------

local function cleanup_all()
	-- Best-effort shaper cleanup for both implementations (state tables differ).
	safe.pcall(function() shaper_inc.clear(DEV0, { ifb = IFB, delete_ifb = true }) end)
	if ok_dec and shaper_dec and shaper_dec.clear then
		safe.pcall(function() shaper_dec.clear(DEV0, { ifb = IFB, delete_ifb = true }) end)
	end

	-- Best-effort link/ns cleanup.
	try_cmd({ 'ip', 'link', 'del', DEV0 })
	try_cmd({ 'ip', 'netns', 'del', NS })
end

local function setup_veth_netns()
	section('Set up veth + netns')

	must_cmd({ 'ip', 'netns', 'add', NS }, 'ip netns add')
	must_cmd({ 'ip', 'link', 'add', DEV0, 'type', 'veth', 'peer', 'name', DEV1 }, 'ip link add veth')
	must_cmd({ 'ip', 'link', 'set', DEV1, 'netns', NS }, 'move peer to netns')

	must_cmd({ 'ip', 'addr', 'add', '10.12.0.1/20', 'dev', DEV0 }, 'addr add dc0')
	must_cmd({ 'ip', 'link', 'set', DEV0, 'up' }, 'link up dc0')

	must_cmd({ 'ip', 'netns', 'exec', NS, 'ip', 'link', 'set', 'lo', 'up' }, 'netns lo up')
	must_cmd({ 'ip', 'netns', 'exec', NS, 'ip', 'addr', 'add', '10.12.0.2/20', 'dev', DEV1 }, 'addr add dc1 primary')
	must_cmd({ 'ip', 'netns', 'exec', NS, 'ip', 'addr', 'add', '10.12.15.2/20', 'dev', DEV1 }, 'addr add dc1 secondary')
	must_cmd({ 'ip', 'netns', 'exec', NS, 'ip', 'link', 'set', DEV1, 'up' }, 'link up dc1')
end

local function sanity_checks()
	section('Sanity checks')
	must_cmd({ 'id', '-u' }, 'id -u')
	must_cmd({ 'ip', '-V' }, 'ip -V')
	must_cmd({ 'tc', '-V' }, 'tc -V')
end

------------------------------------------------------------------------
-- Benchmark sampling
------------------------------------------------------------------------

local function sample_action(action_fn)
	local counter = new_counter()
	local restore = install_counter(counter)

	local t0 = runtime.now()
	local ok, err = safe.xpcall(action_fn, debug.traceback)
	local dt = runtime.now() - t0

	restore()

	if not ok then
		error(err, 2)
	end

	return dt, counter
end

local function do_apply(shaper, spec)
	local ok, err = shaper.apply(spec)
	if not ok then
		error('apply failed: ' .. tostring(err), 2)
	end
end

local function do_clear(shaper)
	local ok, err = shaper.clear(DEV0, { ifb = IFB, delete_ifb = false })
	if not ok then
		error('clear failed: ' .. tostring(err), 2)
	end
end

local function run_scenario_cold(shaper, rounds)
	local s = stats_new()
	for i = 1, rounds do
		local dt, c = sample_action(function()
			do_clear(shaper)
			do_apply(shaper, base_spec())
		end)
		stats_add(s, dt, c)

		local fds = fd_count()
		if fds then
			say('  [fd] after cold sample ', i, ': ', fds)
		end
	end
	return s
end

local function run_scenario_noop(shaper, rounds)
	local s = stats_new()

	-- Prime state
	do_apply(shaper, base_spec())

	for i = 1, rounds do
		local dt, c = sample_action(function()
			do_apply(shaper, base_spec())
		end)
		stats_add(s, dt, c)

		local fds = fd_count()
		if fds then
			say('  [fd] after noop sample ', i, ': ', fds)
		end
	end
	return s
end

local function run_scenario_toggle(shaper, rounds)
	local s = stats_new()

	-- Prime state
	do_apply(shaper, base_spec())

	local flip = false
	for i = 1, rounds do
		flip = not flip
		local spec = flip and toggled_spec() or base_spec()

		local dt, c = sample_action(function()
			do_apply(shaper, spec)
		end)
		stats_add(s, dt, c)

		local fds = fd_count()
		if fds then
			say('  [fd] after toggle sample ', i, ': ', fds)
		end
	end
	return s
end

local function run_suite(title, shaper)
	subheading(title)

	-- Start from clean shape state on the test interface
	safe.pcall(function() shaper.clear(DEV0, { ifb = IFB, delete_ifb = false }) end)

	local s_cold = run_scenario_cold(shaper, ROUNDS_COLD)
	stats_print('cold apply (clear + apply)', s_cold)

	local s_noop = run_scenario_noop(shaper, ROUNDS_NOOP)
	stats_print('noop apply (same spec)', s_noop)

	local s_toggle = run_scenario_toggle(shaper, ROUNDS_TOGGLE)
	stats_print('toggle apply (host limits change)', s_toggle)

	-- Leave interface clean before next suite
	safe.pcall(function() shaper.clear(DEV0, { ifb = IFB, delete_ifb = false }) end)
end

------------------------------------------------------------------------
-- Main
------------------------------------------------------------------------

local function main()
	section('Cleanup any leftovers')
	cleanup_all()
	sanity_checks()
	setup_veth_netns()

	section('Benchmark')
	say('Rounds: cold=', ROUNDS_COLD, ' noop=', ROUNDS_NOOP, ' toggle=', ROUNDS_TOGGLE)
	say('Interface=', DEV0, ' IFB=', IFB, ' subnet=' .. SUBNET)
	if FD_DEBUG then
		say('FD debug: enabled')
	end

	run_suite('Incremental shaper (tc_u32_shaper)', shaper_inc)

	if ok_dec and shaper_dec then
		run_suite('Declarative shaper (tc_u32_shaper_declarative)', shaper_dec)
	else
		subheading('Declarative shaper (tc_u32_shaper_declarative)')
		say('SKIP: could not require module: ', tostring(shaper_dec))
	end
end

fibers.run(function()
	local ok, err = safe.xpcall(main, debug.traceback)

	section('Cleanup')
	cleanup_all()

	if not ok then
		io.stderr:write(tostring(err) .. '\n')
		os.exit(1)
	end
end)
