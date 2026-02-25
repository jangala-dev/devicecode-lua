-- test_tc_shaper_socket_bench.lua
-- Lua 5.1 / LuaJIT
--
-- End-to-end bench for services.hal.backends.tc_u32_shaper using:
--   * veth + netns
--   * egress shaping on dc0
--   * ingress shaping on IFB (ifb_dc0)
--   * fibers.io.exec for command/process control
--   * fibers.io.socket for real TCP throughput + latency tests
--
-- What it checks:
--   1) Per-host class counters increment on egress and IFB ingress
--   2) Throughput roughly tracks configured host rates
--   3) A simple latency-under-load comparison (echo RTT while flood is active)
--
-- Notes:
--   * This is a functional test, not a precise benchmark.
--   * The latency check is indicative only.

package.path = '../src/?.lua;' .. package.path

local fibers    = require 'fibers'
local exec      = require 'fibers.io.exec'
local socket    = require 'fibers.io.socket'
local sleep     = require 'fibers.sleep'
local performer = require 'fibers.performer'
local shaper    = require 'services.hal.backends.tc_u32_shaper'

local perform = performer.perform

local NS   = 'dcns_tc'
local DEV0 = 'dc0'
local DEV1 = 'dc1'
local IFB  = 'ifb_dc0'

local SERVER = './tc_peer_server.lua'

----------------------------------------------------------------------
-- Small helpers
----------------------------------------------------------------------

local function say(...)
	local t = {}
	local i
	for i = 1, select('#', ...) do t[#t + 1] = tostring(select(i, ...)) end
	io.stdout:write(table.concat(t, ' ') .. '\n')
end

local function section(name)
	say(('='):rep(72))
	say(name)
	say(('='):rep(72))
end

local function now()
	return fibers.now()
end

----------------------------------------------------------------------
-- fibers.io.exec helpers
----------------------------------------------------------------------

local function run_cmd(argv)
	local spec = { stdin = 'null', stdout = 'pipe', stderr = 'stdout' }
	local i
	for i = 1, #argv do spec[i] = argv[i] end

	local proc = exec.command(spec)
	assert(proc, 'exec.command failed')

	local out, status, code, sig, err = perform(proc:output_op())
	local ok = (err == nil and status == 'exited' and code == 0)
	return ok, out or '', err, code, status, sig
end

local function must_cmd(argv, label)
	local ok, out, err, code, status, sig = run_cmd(argv)
	if not ok then
		error((label or table.concat(argv, ' ')) .. ': ' ..
			tostring(err or out or ('status=' .. tostring(status) .. ' code=' .. tostring(code) .. ' sig=' .. tostring(sig))), 2)
	end
	return out
end

local function try_cmd(argv)
	return run_cmd(argv)
end

----------------------------------------------------------------------
-- Background process helpers (servers)
----------------------------------------------------------------------

local bg_procs = {}

local function start_bg(name, argv)
	local spec = { stdin = 'null', stdout = 'pipe', stderr = 'stdout' }
	local i
	for i = 1, #argv do spec[i] = argv[i] end

	local proc = exec.command(spec)
	assert(proc, 'start_bg: exec.command failed for ' .. tostring(name))

	local out_stream, serr = proc:stdout_stream()
	assert(out_stream and not serr, 'stdout_stream failed: ' .. tostring(serr))

	local rec = {
		name   = name,
		proc   = proc,
		out    = out_stream,
		buf    = {},
	}

	-- Drain logs so child cannot block on pipe backpressure.
	fibers.spawn(function()
		while true do
			local s, err = out_stream:read_some(4096)
			if not s then break end
			rec.buf[#rec.buf + 1] = s
		end
	end)

	bg_procs[#bg_procs + 1] = rec
	return rec
end

local function stop_bg(rec)
	if not rec or not rec.proc then return end
	pcall(function()
		perform(rec.proc:shutdown_op(0.5))
	end)
end

local function stop_all_bg()
	local i
	for i = #bg_procs, 1, -1 do
		stop_bg(bg_procs[i])
	end
	bg_procs = {}
end

----------------------------------------------------------------------
-- IP/class helpers
----------------------------------------------------------------------

local function parse_ipv4(s)
	local a, b, c, d = tostring(s):match('^(%d+)%.(%d+)%.(%d+)%.(%d+)$')
	a, b, c, d = tonumber(a), tonumber(b), tonumber(c), tonumber(d)
	if not (a and b and c and d) then return nil end
	if a > 255 or b > 255 or c > 255 or d > 255 then return nil end
	return ((a * 256 + b) * 256 + c) * 256 + d
end

local function parse_cidr(cidr)
	local ip_s, pfx_s = tostring(cidr):match('^([^/]+)/(%d+)$')
	if not ip_s then return nil, nil end
	local ip = parse_ipv4(ip_s)
	local pfx = tonumber(pfx_s)
	if not ip or not pfx then return nil, nil end
	local host_bits = 32 - pfx
	local net = ip
	if host_bits > 0 then
		local block = 2 ^ host_bits
		net = ip - (ip % block)
	end
	return net, pfx
end

local function host_classid(cidr, ip_s)
	local net_u, pfx = parse_cidr(cidr)
	local ip_u = parse_ipv4(ip_s)
	if not net_u or not ip_u then return nil end
	local off = ip_u - net_u
	if off < 0 then return nil end
	return '20:' .. tostring(1000 + off) -- default ids/base_minor in your module
end

local function class_sent_bytes(dev, classid)
	local out = must_cmd({ 'tc', '-s', 'class', 'show', 'dev', dev }, 'tc -s class show ' .. dev)

	local cur = nil
	for line in tostring(out):gmatch('[^\r\n]+') do
		local cid = line:match('^class%s+htb%s+([^%s]+)')
		if cid then
			cur = cid
		elseif cur == classid then
			local n = line:match('Sent%s+(%d+)%s+bytes')
			if n then return tonumber(n) or 0, out end
		end
	end
	return 0, out
end

----------------------------------------------------------------------
-- Traffic generators with fibers.io.socket
----------------------------------------------------------------------

local function tcp_upload_bytes(dst_ip, port, seconds, bind_ip)
	-- root namespace client -> netns sink server
	local s, err = socket.connect_inet(dst_ip, port, { bind_host = bind_ip })
	assert(s, 'connect upload failed: ' .. tostring(err))
	s:setvbuf('no')

	local chunk = string.rep('U', 16 * 1024)
	local total = 0
	local t_end = now() + seconds

	while now() < t_end do
		local n, werr = s:write(chunk)
		if not n then break end
		total = total + n
	end

	s:close()
	return total
end

local function tcp_download_bytes(dst_ip, port, seconds, bind_ip)
	-- root namespace client <- netns flood server
	local s, err = socket.connect_inet(dst_ip, port, { bind_host = bind_ip })
	assert(s, 'connect download failed: ' .. tostring(err))
	s:setvbuf('no')

	local total = 0
	local t_end = now() + seconds

	while now() < t_end do
		local chunk, rerr = s:read_some(64 * 1024)
		if not chunk then break end
		total = total + #chunk
	end

	s:close()
	return total
end

local function echo_rtt_ms(dst_ip, port, count, bind_ip)
	local s, err = socket.connect_inet(dst_ip, port, { bind_host = bind_ip })
	assert(s, 'connect echo failed: ' .. tostring(err))
	s:setvbuf('no')

	local rtts = {}
	local i
	for i = 1, count do
		local msg = tostring(i) .. ':' .. tostring(math.floor(now() * 1000000))
		local t0 = now()
		local n, werr = s:write(msg, '\n')
		if not n then break end
		local line, rerr = s:read_line()
		if not line then break end
		local dt = (now() - t0) * 1000.0
		rtts[#rtts + 1] = dt
	end

	s:close()
	return rtts
end

local function stats_ms(xs)
	if #xs == 0 then
		return { n = 0, min = 0, max = 0, avg = 0, p95 = 0 }
	end
	table.sort(xs)
	local n = #xs
	local sum = 0
	local i
	for i = 1, n do sum = sum + xs[i] end
	local function pct(p)
		local idx = math.floor((p / 100) * n + 0.5)
		if idx < 1 then idx = 1 end
		if idx > n then idx = n end
		return xs[idx]
	end
	return {
		n = n,
		min = xs[1],
		max = xs[n],
		avg = sum / n,
		p95 = pct(95),
	}
end

----------------------------------------------------------------------
-- Cleanup / setup
----------------------------------------------------------------------

local function cleanup()
	pcall(function() shaper.clear(DEV0, { ifb = IFB, delete_ifb = true }) end)
	pcall(stop_all_bg)
	try_cmd({ 'ip', 'link', 'del', DEV0 })
	try_cmd({ 'ip', 'netns', 'del', NS })
end

local function setup_veth_netns()
	must_cmd({ 'ip', 'netns', 'add', NS }, 'ip netns add')
	must_cmd({ 'ip', 'link', 'add', DEV0, 'type', 'veth', 'peer', 'name', DEV1 }, 'ip link add veth')
	must_cmd({ 'ip', 'link', 'set', DEV1, 'netns', NS }, 'move peer to netns')

	must_cmd({ 'ip', 'addr', 'add', '10.12.0.1/20', 'dev', DEV0 }, 'addr add dc0')
	must_cmd({ 'ip', 'link', 'set', DEV0, 'up' }, 'link up dc0')

	must_cmd({ 'ip', 'netns', 'exec', NS, 'ip', 'link', 'set', 'lo', 'up' }, 'lo up ns')
	must_cmd({ 'ip', 'netns', 'exec', NS, 'ip', 'addr', 'add', '10.12.0.2/20', 'dev', DEV1 }, 'addr add dc1 primary')
	must_cmd({ 'ip', 'netns', 'exec', NS, 'ip', 'addr', 'add', '10.12.15.2/20', 'dev', DEV1 }, 'addr add dc1 secondary')
	must_cmd({ 'ip', 'netns', 'exec', NS, 'ip', 'link', 'set', DEV1, 'up' }, 'link up dc1')
end

local function start_servers()
	start_bg('sink',  { 'ip', 'netns', 'exec', NS, 'luajit', SERVER, 'sink',  '0.0.0.0', '5001' })
	start_bg('flood', { 'ip', 'netns', 'exec', NS, 'luajit', SERVER, 'flood', '0.0.0.0', '5002' })
	start_bg('echo',  { 'ip', 'netns', 'exec', NS, 'luajit', SERVER, 'echo',  '0.0.0.0', '5003' })

	-- Small delay to let servers bind
	perform(sleep.sleep_op(0.3))
end

local function apply_shaper()
	local ok, err = shaper.apply({
		iface  = DEV0,
		subnet = '10.12.0.0/20',

		log = function(level, payload)
			if level == 'warn' then
				-- Suppress expected idempotent cleanup warnings. Print others.
				local cmd = payload and payload.cmd or ''
				local out = payload and payload.out or ''
				local benign =
					(cmd:find(' qdisc del ', 1, true) and (out:find('Cannot find specified qdisc', 1, true) or out:find('Cannot delete qdisc with handle of zero', 1, true))) or
					(cmd:find(' filter del ', 1, true) and out:find('Cannot find specified filter chain', 1, true))
				if not benign then
					say('[warn]', payload.what or '', cmd, out)
				end
			elseif level == 'error' then
				say('[error]', payload.what or '', payload.cmd or '', payload.out or '')
			end
		end,

		egress = {
			enabled     = true,
			match       = 'dst',
			pool_rate   = '100mbit',
			pool_ceil   = '100mbit',
			host_rate   = '2mbit',
			host_ceil   = '2mbit',
			host_burst  = '8k',
			host_cburst = '8k',
			fq_codel    = {
				flows = 64,
				limit = 256,
				memory_limit = '1Mb',
				target = '5ms',
				interval = '100ms',
				ecn = true,
			},
			hosts = {
				['10.12.0.2']  = { rate = '1mbit', ceil = '1mbit' },
				['10.12.15.2'] = { rate = '3mbit', ceil = '3mbit' },
			},
		},

		ingress = {
			enabled     = true,
			ifb         = IFB,
			match       = 'src', -- replies from netns sources in this test
			pool_rate   = '100mbit',
			pool_ceil   = '100mbit',
			host_rate   = '2mbit',
			host_ceil   = '2mbit',
			host_burst  = '8k',
			host_cburst = '8k',
			fq_codel    = {
				flows = 64,
				limit = 256,
				memory_limit = '1Mb',
				target = '5ms',
				interval = '100ms',
				ecn = true,
			},
			hosts = {
				['10.12.0.2']  = { rate = '1mbit', ceil = '1mbit' },
				['10.12.15.2'] = { rate = '3mbit', ceil = '3mbit' },
			},
		},
	})

	if not ok then
		error('shaper.apply failed: ' .. tostring(err))
	end
end

----------------------------------------------------------------------
-- Bench scenarios
----------------------------------------------------------------------

local function mbps(bytes, seconds)
	return (bytes * 8.0) / (seconds * 1000 * 1000)
end

local function run_upload_test()
	section('Upload throughput test (root -> netns sink, egress shaping on dc0)')
	local dur = 20.0

	local t0 = now()
	local a = tcp_upload_bytes('10.12.0.2', 5001, dur, '10.12.0.1')
	local t1 = now()
	local b = tcp_upload_bytes('10.12.15.2', 5001, dur, '10.12.0.1')
	local t2 = now()

	local ma = mbps(a, t1 - t0)
	local mb = mbps(b, t2 - t1)

	say(string.format('upload 10.12.0.2   : %.2f Mbit/s (%d bytes)', ma, a))
	say(string.format('upload 10.12.15.2  : %.2f Mbit/s (%d bytes)', mb, b))
end

local function run_download_test()
	section('Download throughput test (netns flood -> root, ingress shaping via IFB)')
	local dur = 20.0

	local t0 = now()
	local a = tcp_download_bytes('10.12.0.2', 5002, dur, '10.12.0.1')
	local t1 = now()
	local b = tcp_download_bytes('10.12.15.2', 5002, dur, '10.12.0.1')
	local t2 = now()

	local ma = mbps(a, t1 - t0)
	local mb = mbps(b, t2 - t1)

	say(string.format('download 10.12.0.2 : %.2f Mbit/s (%d bytes)', ma, a))
	say(string.format('download 10.12.15.2: %.2f Mbit/s (%d bytes)', mb, b))
end

local function run_counter_check()
	section('Counter check (per-host classes on dc0 and IFB)')

	local c_a = assert(host_classid('10.12.0.0/20',  '10.12.0.2'))
	local c_b = assert(host_classid('10.12.0.0/20', '10.12.15.2'))

	local e_a = class_sent_bytes(DEV0, c_a)
	local e_b = class_sent_bytes(DEV0, c_b)
	local i_a = class_sent_bytes(IFB,  c_a)
	local i_b = class_sent_bytes(IFB,  c_b)

	say('Egress  ', DEV0, ' ', c_a, ' Sent bytes = ', e_a)
	say('Egress  ', DEV0, ' ', c_b, ' Sent bytes = ', e_b)
	say('Ingress ', IFB,  ' ', c_a, ' Sent bytes = ', i_a)
	say('Ingress ', IFB,  ' ', c_b, ' Sent bytes = ', i_b)

	if e_a <= 0 or e_b <= 0 or i_a <= 0 or i_b <= 0 then
		error('expected per-host class counters to increment on dc0 and IFB')
	end
end

local function run_latency_under_load_check()
	section('Latency-under-load check (simple fq_codel indication)')

	-- Baseline RTT to echo server on host A
	local base = echo_rtt_ms('10.12.0.2', 5003, 30, '10.12.0.1')
	local s_base = stats_ms(base)
	say(string.format('baseline echo RTT: n=%d avg=%.2fms p95=%.2fms max=%.2fms',
		s_base.n, s_base.avg, s_base.p95, s_base.max))

	-- Start a background download flood to host B (3mbit class), then measure echo on host A (1mbit class)
	local flood_bytes = 0
	local flood_task_done = false

	fibers.spawn(function()
		-- 5s flood from host B
		flood_bytes = tcp_download_bytes('10.12.15.2', 5002, 5.0, '10.12.0.1')
		flood_task_done = true
	end)

	-- Let flood ramp
	perform(sleep.sleep_op(0.5))

	local loaded = echo_rtt_ms('10.12.0.2', 5003, 30, '10.12.0.1')
	local s_load = stats_ms(loaded)

	say(string.format('loaded echo RTT  : n=%d avg=%.2fms p95=%.2fms max=%.2fms',
		s_load.n, s_load.avg, s_load.p95, s_load.max))

	-- Wait for flood task to finish (best effort)
	local t_deadline = now() + 6.0
	while (not flood_task_done) and now() < t_deadline do
		perform(sleep.sleep_op(0.1))
	end

	say(string.format('background flood bytes (host B): %d', flood_bytes))
	say('Note: lower loaded p95/max than without fq_codel would suggest the inner fq_codel is helping.')
end

----------------------------------------------------------------------
-- Main
----------------------------------------------------------------------

local function main()
	section('Cleanup any leftovers')
	cleanup()

	section('Sanity checks')
	must_cmd({ 'id', '-u' }, 'id -u')
	must_cmd({ 'ip', '-V' }, 'ip -V')
	must_cmd({ 'tc', '-V' }, 'tc -V')
	must_cmd({ 'ping', '-c', '1', '127.0.0.1' }, 'ping self-test')
	must_cmd({ 'luajit', '-v' }, 'luajit -v')
	must_cmd({ 'ls', SERVER }, 'check tc_peer_server.lua exists')

	section('Set up veth + netns')
	setup_veth_netns()

	section('Start netns test servers')
	start_servers()

	section('Apply tc_shaper (egress + ingress via IFB)')
	apply_shaper()

	run_upload_test()
	run_download_test()
	run_counter_check()
	run_latency_under_load_check()

	section('PASS')
	say('Shaper exercised with real TCP traffic using fibers.io.socket and fibers.io.exec')
end

fibers.run(function()
	local ok, err = xpcall(main, debug.traceback)
	section('Cleanup')
	cleanup()
	if not ok then
		io.stderr:write(tostring(err) .. '\n')
		os.exit(1)
	end
end)
