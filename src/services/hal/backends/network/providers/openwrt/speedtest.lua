-- services/hal/backends/network/providers/openwrt/speedtest.lua
-- HAL-side WAN speed test using `mwan3 use <iface> <cmd>`.

local fibers = require 'fibers'
local sleep = require 'fibers.sleep'
local exec = require 'fibers.io.exec'
local file = require 'fibers.io.file'

local perform = fibers.perform
local M = {}

local DEFAULT_URL = 'https://proof.ovh.net/files/100Mb.dat'

local function owned_process_flags()
	local flags = { process_group = true }
	if type(exec.supports) == 'function' and exec.supports('parent_death_signal') then
		flags.parent_death_signal = 'TERM'
	end
	return flags
end

local function read_counter(path)
	local f, err = file.open(path, 'r')
	if not f then return nil, err end
	local data, rerr = f:read_all()
	f:close()
	if rerr ~= nil then return nil, rerr end
	local n = tonumber((tostring(data or ''):gsub('%s+', '')))
	if not n then return nil, 'counter parse failed' end
	return n, nil
end

local function monotonic()
	return fibers.now and fibers.now() or os.clock()
end

function M.run_op(req, opts)
	return fibers.run_scope_op(function(scope)
		req = req or {}
		opts = opts or {}
		local iface = req.interface
		local dev = req.device or req.linux_interface or req.ifname
		if type(iface) ~= 'string' or iface == '' then return { ok = false, err = 'speedtest interface required', backend = 'openwrt' } end
		if type(dev) ~= 'string' or dev == '' then dev = iface end
		local url = req.url or opts.url or DEFAULT_URL
		local duration = tonumber(req.max_duration_s or opts.max_duration_s) or 8
		local sample_s = tonumber(req.sample_interval_s or opts.sample_interval_s) or 0.1
		local argv = { 'mwan3', 'use', iface, 'wget', '-O', '/dev/null', tostring(url) }
		local run_cmd = opts.run_cmd or req.run_cmd
		if type(run_cmd) == 'function' then
			local ok, out, err = run_cmd(argv)
			return { ok = ok == true, backend = 'openwrt', interface = iface, device = dev, peak_mbps = tonumber(out) or 0, err = ok == true and nil or tostring(err or out) }
		end
		local spec = {
			stdin = 'null',
			stdout = 'pipe',
			stderr = 'null',
			shutdown_grace = 0.2,
			flags = owned_process_flags(),
		}
		for i = 1, #argv do spec[i] = argv[i] end
		local cmd = exec.command(spec)
		local started, serr = cmd:stdout_stream()
		if not started then return { ok = false, err = serr or 'speedtest start failed', backend = 'openwrt' } end
		local counter = '/sys/class/net/' .. tostring(dev) .. '/statistics/rx_bytes'
		local start_b, berr = read_counter(counter)
		if not start_b then
			perform(cmd:shutdown_op(0.2))
			return {
				ok = false,
				err = 'counter read failed: ' .. tostring(berr or 'unknown'),
				backend = 'openwrt',
				interface = iface,
				device = dev,
				counter = counter,
			}
		end
		local t0 = monotonic()
		local prev_t, prev_b = t0, start_b
		local peak = 0
		while (monotonic() - t0) < duration do
			perform(sleep.sleep_op(sample_s))
			local t = monotonic()
			local b = read_counter(counter)
			if not b then break end
			local dt = t - prev_t
			local db = b - prev_b
			if dt > 0 and db >= 0 then
				local mbps = (db * 8) / (dt * 1000 * 1000)
				if mbps > peak then peak = mbps end
			end
			prev_t, prev_b = t, b
		end
		perform(cmd:shutdown_op(0.2))
		return { ok = true, backend = 'openwrt', interface = iface, device = dev, peak_mbps = peak, data_mib = (prev_b - start_b) / (1024 * 1024), duration_s = prev_t - t0 }
	end):wrap(function(status, _report, result)
		if status ~= 'ok' then return { ok = false, err = tostring(result or status), backend = 'openwrt' } end
		return result
	end)
end

return M
