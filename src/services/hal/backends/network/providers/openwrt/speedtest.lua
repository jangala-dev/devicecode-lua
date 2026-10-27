-- Bounded WAN payload throughput, timed by curl rather than the Lua scheduler.
local fibers = require 'fibers'
local sleep = require 'fibers.sleep'
local op = require 'fibers.op'
local exec = require 'fibers.io.exec'
local time = require 'fibers.utils.time'
local limits = require 'shared.speedtest'

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

local function before_deadline(work, deadline)
	return perform(op.named_choice({
		work = work,
		timeout = sleep.sleep_op(math.max(0, deadline - time.monotonic())),
	}))
end

local function collect(argv, deadline)
	local spec = {
		stdin = 'null', stdout = 'pipe', stderr = 'null', shutdown_grace = 0.2,
		flags = owned_process_flags(),
		env = { http_proxy = '', https_proxy = '', all_proxy = '', HTTP_PROXY = '', HTTPS_PROXY = '', ALL_PROXY = '' },
	}
	for i = 1, #argv do spec[i] = argv[i] end
	local cmd = exec.command(spec)
	local stream, err = cmd:stdout_stream()
	if not stream then return nil, nil, err end
	-- Only the mwan3 banner and curl's statistics are on stdout, never payload.
	local which, out, count, read_err = before_deadline(stream:core_read_op({
		min = 8192, max = 8192, eof_ok = true,
	}), deadline)
	local status, code
	if which == 'work' and not read_err and (count or 0) < 8192 then
		which, status, code = before_deadline(cmd:run_op(), deadline)
	end
	perform(cmd:shutdown_op(0.2))
	if which ~= 'work' then return nil, nil, 'speedtest_timeout' end
	if read_err or (count or 0) >= 8192 then return nil, nil, read_err or 'invalid_output' end
	if status ~= 'exited' then return nil, nil, 'download_process_failed' end
	return out or '', code
end

function M.run_op(req, opts)
	return fibers.run_scope_op(function()
		req, opts = req or {}, opts or {}
		local iface = req.interface
		local dev = req.device or req.linux_interface or req.ifname or iface
		local function failure(code, err)
			return { ok = false, code = code, err = err or code, backend = 'openwrt', interface = iface, device = dev }
		end
		if type(iface) ~= 'string' or iface == '' then return failure('invalid_request', 'speedtest interface required') end
		local duration = limits.duration(req.max_duration_s or opts.max_duration_s)
		local url = tostring(req.url or opts.url or DEFAULT_URL)
		-- mwan3 expands $* unquoted. Curl globbing is also disabled below.
		if #url > 2048 or not url:match('^https?://') or url:find('[%s%z%[%]%*%?]') then
			return failure('invalid_request', 'speedtest URL must be HTTP(S) without whitespace or glob characters')
		end
		local argv = {
			'mwan3', 'use', iface, 'curl', '--disable', '--fail-early', '--globoff',
			'--silent', '--show-error', '--fail', '--ipv4', '--http1.1',
			'--head', '--max-time', tostring(limits.SETUP_S), '--output', '/dev/null',
			'--write-out', 'SETUP,%{http_code},%{time_total},%{exitcode}\\n', '--url', url,
			'--next', '--globoff', '--silent', '--show-error', '--fail', '--ipv4', '--http1.1',
			'--range', '0-' .. tostring(limits.MAX_BYTES - 1), '--max-filesize', tostring(limits.MAX_BYTES),
			'--max-time', tostring(duration), '--output', '/dev/null',
			'--write-out', 'RESULT,%{http_code},%{size_download},%{time_starttransfer},%{time_total},%{exitcode}\\n',
			'--url', url,
		}
		local run_cmd = opts.run_cmd or req.run_cmd
		if type(run_cmd) == 'function' then
			local ok, out, err = run_cmd(argv)
			local mbps = tonumber(out)
			if ok == true and mbps and mbps > 0 and mbps < math.huge then
				return { ok = true, backend = 'openwrt', interface = iface, device = dev, mbps = mbps, peak_mbps = mbps }
			end
			return failure('speedtest_failed', tostring(err or out or 'speedtest failed'))
		end
		local started_at = time.monotonic()
		local deadline = started_at + limits.timeout(duration) - 0.2
		-- Before 8.4, --max-filesize only checks advertised Content-Length and
		-- cannot cap an unknown-length response whose server ignores Range.
		local version, version_code = collect({'curl', '--disable', '--version'}, deadline)
		local major, minor = tostring(version):match('^curl (%d+)%.(%d+)')
		if version_code ~= 0 or not major or tonumber(major) < 8
			or (tonumber(major) == 8 and tonumber(minor) < 4) then
			return failure('curl_unsupported', 'speedtest requires curl >= 8.4 for a bounded download')
		end
		-- A HEAD request establishes DNS/TCP/TLS without downloading a file.
		-- The following GET reuses that connection but has its own short timeout.
		local out, wrapper_code, err = collect(argv, deadline)
		if not out then return failure('speedtest_failed', err) end
		local setup_code, setup_s, setup_exit = out:match('\nSETUP,(%d+),([%d%.]+),(%d+)\n')
		local http_code, bytes, first_s, total_s, exit_code =
			out:match('\nRESULT,(%d+),([%d%.]+),([%d%.]+),([%d%.]+),(%d+)\n')
		setup_code, setup_s, setup_exit = tonumber(setup_code), tonumber(setup_s), tonumber(setup_exit)
		exit_code = tonumber(exit_code)
		http_code, bytes, first_s, total_s = tonumber(http_code), tonumber(bytes), tonumber(first_s), tonumber(total_s)
		-- mwan3 < 2.11.16 always exits 0; 2.11.16 (OpenWrt 24.10) execs curl and
		-- returns its status. Any other wrapper status is mwan3's own failure.
		if wrapper_code ~= 0 and wrapper_code ~= (exit_code or setup_exit) then
			return failure('speedtest_failed', 'mwan3 exit: ' .. tostring(wrapper_code))
		end
		if setup_exit ~= 0 or (setup_code ~= 200 and setup_code ~= 206) then
			return failure(setup_exit == 28 and 'setup_timeout' or 'http_failed',
				'setup HTTP: ' .. tostring(setup_code) .. '; curl exit: ' .. tostring(setup_exit))
		end
		if http_code ~= 200 and http_code ~= 206 then
			return failure('http_failed', 'download HTTP: ' .. tostring(http_code))
		end
		if not exit_code or not bytes or not first_s or not total_s
			or bytes > limits.MAX_BYTES or total_s < first_s then
			return failure('invalid_output')
		end
		local elapsed = total_s - first_s
		local result = {
			backend = 'openwrt', interface = iface, device = dev, bytes = bytes,
			data_mib = bytes / (1024 * 1024), duration_s = elapsed, setup_s = setup_s,
			total_duration_s = time.monotonic() - started_at,
			stop_reason = exit_code == 28 and 'duration' or bytes == limits.MAX_BYTES and 'byte_budget' or 'eof',
			estimator = 'payload_average',
		}
		-- Judge the download by curl's write-out exitcode, not the wrapper's.
		-- curl 28 is the intentional GET deadline. Other partial-download errors
		-- must not become successful measurements, even if some bytes arrived.
		if exit_code ~= 0 and exit_code ~= 28 then
			result.ok, result.code, result.err = false, 'speedtest_failed', 'curl exit: ' .. tostring(exit_code)
		elseif bytes == limits.MAX_BYTES and elapsed < limits.MIN_MEASUREMENT_S then
			-- A fast capped transfer is evidence of capacity, not a failed link.
			-- Clamp the interval and label the estimate instead of starving its weight.
			result.ok, result.lower_bound = true, true
			result.estimator = 'payload_lower_bound'
			result.mbps = bytes * 8 / (limits.MIN_MEASUREMENT_S * 1000000)
			result.peak_mbps = result.mbps
		elseif elapsed < limits.MIN_MEASUREMENT_S or bytes < limits.MIN_BYTES then
			result.ok = false
			result.code = bytes == limits.MAX_BYTES and 'insufficient_data_budget' or 'insufficient_data'
			result.err = result.code
		else
			result.ok = true
			result.mbps = bytes * 8 / (elapsed * 1000000)
			result.peak_mbps = result.mbps -- compatibility; this is no longer a peak
		end
		return result
	end):wrap(function(status, _report, result)
		if status ~= 'ok' then
			return { ok = false, code = 'worker_failed', err = tostring(result or status), backend = 'openwrt' }
		end
		return result
	end)
end

return M
