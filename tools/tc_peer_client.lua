-- tc_peer_client.lua
-- Lua 5.1 / LuaJIT
--
-- Usage:
--   luajit tc_peer_client.lua push  <dst_host> <port> <seconds> [bind_host] [chunk_bytes]
--   luajit tc_peer_client.lua pull  <dst_host> <port> <seconds> [bind_host]
--   luajit tc_peer_client.lua probe <dst_host> <port> <count>   [interval_ms] [bind_host]

local fibers = require 'fibers'
local sleep  = require 'fibers.sleep'
local socket = require 'fibers.io.socket'

local mode = arg[1]

local function say(...)
	local t = {}
	for i = 1, select('#', ...) do t[#t + 1] = tostring(select(i, ...)) end
	io.stdout:write(table.concat(t, ' ') .. '\n')
	io.stdout:flush()
end

-- Monotonic time (seconds), prefers LuaJIT FFI clock_gettime.
local function now_mono()
	local ok, ffi = pcall(require, 'ffi')
	if ok then
		pcall(function()
			ffi.cdef[[
				typedef long time_t;
				struct timespec { time_t tv_sec; long tv_nsec; };
				int clock_gettime(int clk_id, struct timespec *tp);
			]]
		end)
		local CLOCK_MONOTONIC = 1
		local ts = ffi.new('struct timespec[1]')
		if ffi.C.clock_gettime(CLOCK_MONOTONIC, ts) == 0 then
			return tonumber(ts[0].tv_sec) + (tonumber(ts[0].tv_nsec) / 1e9)
		end
	end
	-- Fallback (CPU time; less ideal)
	return os.clock()
end

local function percentile(sorted, p)
	if #sorted == 0 then return 0 end
	local idx = math.floor((p / 100) * (#sorted - 1) + 1.5)
	if idx < 1 then idx = 1 end
	if idx > #sorted then idx = #sorted end
	return sorted[idx]
end

local function connect_stream(dst_host, port, bind_host)
	local opts = nil
	if bind_host and bind_host ~= '' then
		opts = { bind_host = bind_host }
	end
	return socket.connect_inet(dst_host, port, opts or {})
end

local function do_push()
	local dst_host = assert(arg[2], 'dst_host required')
	local port     = assert(tonumber(arg[3]), 'port required')
	local seconds  = assert(tonumber(arg[4]), 'seconds required')
	local bind_host= arg[5]
	local chunk_n  = tonumber(arg[6] or '16384') or 16384

	local s, err = connect_stream(dst_host, port, bind_host)
	if not s then error('connect failed: ' .. tostring(err)) end

	s:setvbuf('full', 65536)

	local chunk = string.rep('A', chunk_n)
	local bytes = 0
	local start = now_mono()
	local stop  = start + seconds
	local writes = 0

	while now_mono() < stop do
		local n, werr = s:write(chunk)
		if not n then
			break
		end
		bytes = bytes + n
		writes = writes + 1
		if (writes % 16) == 0 then
			local okf, ferr = s:flush()
			if not okf then break end
		end
	end

	pcall(function() s:flush() end)
	pcall(function() s:close() end)

	local elapsed = now_mono() - start
	if elapsed <= 0 then elapsed = 0.000001 end
	local mbps = (bytes * 8) / elapsed / 1000 / 1000

	say(string.format('RESULT mode=push bytes=%d secs=%.6f mbps=%.3f', bytes, elapsed, mbps))
end

local function do_pull()
	local dst_host = assert(arg[2], 'dst_host required')
	local port     = assert(tonumber(arg[3]), 'port required')
	local seconds  = assert(tonumber(arg[4]), 'seconds required')
	local bind_host= arg[5]

	local s, err = connect_stream(dst_host, port, bind_host)
	if not s then error('connect failed: ' .. tostring(err)) end

	s:setvbuf('full', 65536)

	local bytes = 0
	local start = now_mono()
	local stop  = start + seconds

	while now_mono() < stop do
		local chunk, rerr = s:read_some(65536)
		if not chunk then
			break
		end
		bytes = bytes + #chunk
	end

	pcall(function() s:close() end)

	local elapsed = now_mono() - start
	if elapsed <= 0 then elapsed = 0.000001 end
	local mbps = (bytes * 8) / elapsed / 1000 / 1000

	say(string.format('RESULT mode=pull bytes=%d secs=%.6f mbps=%.3f', bytes, elapsed, mbps))
end

local function do_probe()
	local dst_host    = assert(arg[2], 'dst_host required')
	local port        = assert(tonumber(arg[3]), 'port required')
	local count       = assert(tonumber(arg[4]), 'count required')
	local interval_ms = tonumber(arg[5] or '20') or 20
	local bind_host   = arg[6]

	local s, err = connect_stream(dst_host, port, bind_host)
	if not s then error('connect failed: ' .. tostring(err)) end

	s:setvbuf('line', 4096)

	local samples = {}
	local sum = 0

	local i
	for i = 1, count do
		local t0 = now_mono()
		local n, werr = s:write('PING\n')
		if not n then error('probe write failed: ' .. tostring(werr)) end

		local line, rerr = s:read_line()
		if not line then error('probe read failed: ' .. tostring(rerr)) end
		if line ~= 'PONG' then error('unexpected probe reply: ' .. tostring(line)) end

		local t1 = now_mono()
		local ms = (t1 - t0) * 1000.0
		samples[#samples + 1] = ms
		sum = sum + ms

		if i < count and interval_ms > 0 then
			sleep.sleep(interval_ms / 1000.0)
		end
	end

	pcall(function() s:close() end)

	table.sort(samples)

	local n = #samples
	local avg = (n > 0) and (sum / n) or 0
	local p50 = percentile(samples, 50)
	local p95 = percentile(samples, 95)
	local p99 = percentile(samples, 99)
	local min = samples[1] or 0
	local max = samples[n] or 0

	say(string.format(
		'RESULT mode=probe n=%d avg_ms=%.3f p50_ms=%.3f p95_ms=%.3f p99_ms=%.3f min_ms=%.3f max_ms=%.3f',
		n, avg, p50, p95, p99, min, max
	))
end

local function main()
	if mode == 'push' then
		do_push()
	elseif mode == 'pull' then
		do_pull()
	elseif mode == 'probe' then
		do_probe()
	else
		io.stderr:write('usage:\n')
		io.stderr:write('  luajit tc_peer_client.lua push  <dst_host> <port> <seconds> [bind_host] [chunk_bytes]\n')
		io.stderr:write('  luajit tc_peer_client.lua pull  <dst_host> <port> <seconds> [bind_host]\n')
		io.stderr:write('  luajit tc_peer_client.lua probe <dst_host> <port> <count> [interval_ms] [bind_host]\n')
		os.exit(2)
	end
end

fibers.run(main)
