local support = require 'onbox.support.runner'
local devicecode = require 'onbox.support.devicecode'
local cli = require 'onbox.speedtest_compare.cli'
local gsm = require 'onbox.support.gsm'
local net = require 'onbox.support.net'
local process = require 'onbox.support.process'
local util = require 'onbox.support.util'
local tablex = require 'shared.table'

local M = {}
local Runner = {}
Runner.__index = Runner
local PHASE = 'speedtest-compare'
local quote = process.quote

function M.parse_args(argv, repo, here)
	local args = support.parse_args(argv, repo, here, { prefix = PHASE, defaults = { settle_s = 60 },
		values = { ['--settle-seconds'] = 'settle_s', ['--server-id'] = 'server_id' } })
	args.settle_s = assert(tonumber(args.settle_s), 'Invalid WAN settle duration')
	assert(args.settle_s >= 0 and args.settle_s < math.huge, 'WAN settle duration must be finite and nonnegative')
	assert(not args.server_id or args.server_id:match('^%d+$'), 'Speedtest server ID must contain digits only')
	return args
end

function M.phase_config(original)
	local config = tablex.deep_copy(original)
	local _, data = net.members(config)
	local wan = data.wan
	wan.load_balancing = wan.load_balancing or {}
	local lb, runtime = wan.load_balancing, wan.runtime or {}
	local opts = lb.speedtests or lb.speedtest or runtime.speedtests or runtime.speedtest
	if type(opts) ~= 'table' then opts = {} end
	lb.speedtest, runtime.speedtests, runtime.speedtest = nil, nil, nil
	opts.enabled, opts.scope, opts.live_weights, opts.interval_s = true, 'all', false, 21600
	lb.speedtests = opts
	config.net.rev = (config.net.rev or 0) + 1
	return config
end

function M.paths(config)
	local members, data = net.members(config)
	local paths = {}
	for _, id in ipairs(util.keys(members)) do
		local member = members[id]
		local interface = member.interface or id
		local metric = math.max(1, math.floor(tonumber(member.metric or member.mwan_metric) or 1))
		local previous = paths[interface]
		local enabled = member.enabled ~= false and member.disabled ~= true
		if not previous or (enabled and (not previous.enabled or metric < previous.metric)) then
			paths[interface] = { member = id, interface = interface, metric = metric, enabled = enabled,
				family = member.family or (data.wan.health or {}).family or 'ipv4' }
		end
	end
	assert(next(paths), 'No configured WAN interfaces')
	return paths
end

local function ipv4_source(address)
	return type(address) == 'string' and address ~= '0.0.0.0' and address:match('^%d+%.%d+%.%d+%.%d+$')
end

function M.binding(path, mwan, interfaces)
	if not path.enabled then return nil, 'disabled in Devicecode config' end
	if path.family ~= 'ipv4' then return nil, 'Devicecode speedtest requires an IPv4 path' end
	if not path.alias then return nil, 'NET did not report an OpenWrt interface' end
	local binding, err = net.online_binding(path.alias, mwan, interfaces)
	if not binding then return nil, err end
	if not ipv4_source(binding.address) then return nil, 'no IPv4 source address' end
	if binding.ipv4_count ~= 1 then return nil, 'multiple IPv4 source addresses' end
	return binding
end

local function sample_matches(sample, binding)
	return sample and sample.device == binding.device and sample.alias == binding.alias
		and sample.address == binding.address and sample.mbps and sample.mbps > 0
end

function M.external_command(workspace, binding, server_id)
	assert(binding.alias:match('^[%w_]+$'))
	assert(binding.device:match('^[%w_.:%-]+$'))
	assert(binding.address:match('^%d+%.%d+%.%d+%.%d+$'))
	assert(not server_id or server_id:match('^%d+$'))
	return 'cd ' .. quote(workspace) .. ' && env http_proxy= https_proxy= all_proxy= HTTP_PROXY= HTTPS_PROXY= ALL_PROXY='
		.. ' mwan3 use ' .. binding.alias .. ' luajit ./speedtest-deadline.lua 90 ' .. binding.device .. ' '
		.. binding.address .. ' --json --ipv4 --secure --concurrent 1 --no-upload --duration 4 --timeout 10'
		.. (server_id and ' --server ' .. server_id or '')
end

function M.external_result(stdout, stderr, code)
	-- Older mwan3 releases write a binding banner to stdout before the JSON.
	local output = '\n' .. stdout
	local json = output:match('\n(%[[^\r\n]*%])%s+ONBOX_LIBRESPEED_OK%s*$')
	if (code and code ~= 0) or not json then
		local detail
		for line in (stderr or ''):gmatch('[^\r\n]+') do
			-- Newer mwan3 writes its binding and family notices to stderr.
			if line:find('%S') and not line:match("^Running '.+' with DEVICE=")
				and not line:match('^could not find family for %S+%. Using ipv4%.$') then
				detail = line:gsub('%c', ' '):sub(1, 512)
				break
			end
		end
		local message = 'LibreSpeed CLI did not report a verified JSON result'
		if code and code ~= 0 then
			message = 'LibreSpeed CLI failed with exit ' .. code
		elseif output:match('\nnull%s+ONBOX_LIBRESPEED_OK%s*$') then
			message = 'LibreSpeed CLI did not produce a measurement'
		end
		error(message .. (detail and ': ' .. detail or ''), 0)
	end
	local records = util.decode(json)
	assert(#records == 1, 'LibreSpeed CLI did not report exactly one result')
	local record = records[1]
	-- LibreSpeed reports decimal Mbps in its JSON download field.
	local mbps = tonumber(record.download)
	assert(mbps and mbps > 0 and mbps < math.huge, 'Invalid LibreSpeed CLI download rate')
	return { mbps = mbps, server = record.server, bytes_received = record.bytes_received }
end

function M.compare(internal, external)
	assert(internal > 0 and internal < math.huge, 'Invalid Devicecode download rate')
	local delta = external - internal
	return { signed_mbps = delta, absolute_mbps = math.abs(delta), percent = delta / internal * 100 }
end

function M.from_session(box)
	return setmetatable({ box = box, runtime = devicecode.new(box), now = process.now }, Runner)
end

function M.new(args)
	return M.from_session(support.open(args, { 'net', 'mwan3', 'speedtest', 'error', 'failed' }))
end

function Runner:prepare()
	self:check_box()
	self.runtime:prepare(true)
	self.original_pids = self.runtime:service_pids()
	local original = self.runtime.persistent_existed
		and util.decode(util.read(self.box.artifacts .. '/original-persistent.json')) or self.runtime.original
	self.config = M.phase_config(original)
	self.paths = M.paths(self.config)
	self.runtime:backup()
end

function Runner:check_box(deployment_kib)
	local runtime = quote(self.box.args.runtime)
	self.box.ssh:run('uci show network >/dev/null && uci show firewall >/dev/null', { timeout = 15 })
	local sizes = self.box.ssh:run("df -Pk " .. runtime .. " | awk 'NR == 2 { print $4 }'\n"
		.. "du -sk " .. runtime .. " | awk 'NR == 1 { print $1 }'", { timeout = 20 }).stdout
	local available, needed = sizes:match('^%s*(%d+)%s+(%d+)%s*$')
	assert(available, 'Could not check available runtime storage (see df -h /overlay)')
	self.rollback_kib = self.rollback_kib or tonumber(needed)
	local required = self.rollback_kib + (deployment_kib or 0)
	assert(tonumber(available) >= required and tonumber(available) > 0,
		('Insufficient free runtime storage for deployment and rollback (%d KiB available, %d KiB required)'):
			format(tonumber(available), required))
end

function Runner:deployment_size()
	local path = self.box.args.repo .. '/build'
	local result = self.box.process:run('du -sk ' .. quote(path), { timeout = 20 })
	local build_kib = result.stdout:match('^(%d+)%s')
	assert(result.code == 0 and build_kib, 'Could not calculate candidate runtime size')
	local config_kib = math.ceil(#util.encode(self.config) / 4096) * 4
	return tonumber(build_kib) + 2 * config_kib
end

function Runner:install_cli()
	cli.install(self.box)
end

function Runner:snapshot()
	return net.snapshot(self.box)
end

function Runner:write_results()
	util.write(self.box.artifacts .. '/results.json', util.encode({ interfaces = self.paths,
		percent_baseline = 'devicecode_download_mbps', cli = cli.label,
		net_apply_failure = self.net_apply_failure }))
end

function Runner:compare_path(path, index, selected)
	local mwan, interfaces = self:snapshot()
	assert(path.alias == selected.alias, 'OpenWrt interface changed after selection')
	local binding, reason = M.binding(path, mwan, interfaces)
	if not binding then path.excluded = reason; return end
	local observed = path.devicecode
	assert(binding.device == selected.device and binding.address == selected.address,
		'WAN binding changed after selection')
	assert(sample_matches(observed, binding),
		'No successful fresh Devicecode speedtest on the selected interface and source address'
			.. (path.last_error and ': ' .. path.last_error or ''))
	local command = M.external_command(self.box.remote, binding, self.box.args.server_id)
	local result = self.box.ssh:run(command, { timeout = 100, check = false })
	local path_prefix = self.box.artifacts .. '/speedtest-cli-' .. index
	util.write(path_prefix .. '.stdout', result.stdout)
	util.write(path_prefix .. '.stderr', result.stderr)
	path.cli_artifact = 'speedtest-cli-' .. index .. '.stdout'
	path.cli_stderr_artifact = 'speedtest-cli-' .. index .. '.stderr'
	local post_mwan, post_interfaces = self:snapshot()
	local after, after_reason = M.binding(path, post_mwan, post_interfaces)
	if not after then path.excluded = 'during CLI test: ' .. after_reason; return end
	assert(after.device == binding.device and after.address == binding.address, 'WAN binding changed during CLI test')
	path.external = M.external_result(result.stdout, result.stderr, result.code)
	path.binding = binding
	path.difference = M.compare(observed.mbps, path.external.mbps)
	print(('[%s] %s/%s Devicecode %.3f%s Mbps, CLI %.3f Mbps, difference %+.3f Mbps (%+.1f%%), absolute %.3f Mbps'):
		format(PHASE, path.interface, binding.device, observed.mbps, observed.lower_bound and ' lower bound' or '',
			path.external.mbps, path.difference.signed_mbps, path.difference.percent, path.difference.absolute_mbps))
end

function Runner:exercise(archive)
	self.box:phase(PHASE, function()
		local logs, args = self.box.logs, self.box.args
		local started, applied, measured, producer, failure
		local states, selected, paths_by_member = {}, {}, {}
		for _, path in pairs(self.paths) do paths_by_member[path.member] = path end
		local function observe(line)
			if not started then return false end
			local rollback = line:match('%f[%w]LOG%s+hal%s+%S+%s+uci_rollback_done%s+(.+)$')
			if rollback and rollback:match('%f[%w]ok=false%f[%W]') then
				failure = 'OpenWrt UCI rollback failed (see speedtest-compare-service.log)'
				return true
			end
			local apply, detail = line:match('%f[%w]LOG%s+net%s+%S+%s+(apply_%a+)%s+(.+)$')
			if apply ~= 'apply_completed' and apply ~= 'apply_failed' then apply = nil end
			local status, sample = net.status_event(line), net.speedtest_event(line)
			if not apply and not status and not sample then return false end
			local pid = gsm.monitor_pid(line)
			if not pid or (producer and producer ~= pid) then
				failure = 'Devicecode network log producer changed or is missing'
			end
			producer = pid
			if apply == 'apply_completed' then applied = true end
			if apply == 'apply_failed' then self.net_apply_failure = detail end
			if status and self.paths[status.interface] and self.paths[status.interface].member == status.member then
				states[status.interface] = status.state
				if status.alias then self.paths[status.interface].alias = status.alias end
			end
			local path = sample and paths_by_member[sample.member]
			if path then
				if sample.error then
					path.last_error = sample.error
				elseif sample.interface == path.interface then
					path.devicecode = sample
					if not path.alias and sample.alias ~= '?' then path.alias = sample.alias end
					if path.enabled and path.family == 'ipv4' and sample.mbps and sample.mbps > 0
						and sample.device ~= '?' and sample.alias and sample.alias ~= '?' and ipv4_source(sample.address) then
						measured = true
					end
				end
			end
			return true
		end
		self.runtime:deploy(archive)
		self.runtime:write_config(self.config)
		assert(not next(self.runtime:service_pids()), 'Original Devicecode is still running')
		logs:checkpoint('BEGIN tested speedtests', observe)
		started = true
		self.runtime:service('start')
		logs:wait_for('NET apply completion or a fresh Devicecode speedtest', self.now() + args.timeout, function()
			assert(not failure, failure)
			return applied or measured
		end)
		local pids = self.runtime:service_pids()
		assert(pids[producer], 'NET test evidence is from a different Devicecode process')
		if not applied then
			if self.net_apply_failure then print(('[%s] NET reported %s'):format(PHASE, self.net_apply_failure)) end
			print(('[%s] Fresh Devicecode speedtest received. Checking the live WAN bindings.'):format(PHASE))
		end
		local settle_until = self.now() + args.settle_s
		logs:wait_for('WAN discovery window', settle_until, function()
			assert(not failure, failure)
			if self.now() >= settle_until then return true end
			for id, path in pairs(self.paths) do
				if path.enabled and path.family == 'ipv4' and states[id] ~= 'online' then return false end
			end
			return true
		end)
		local mwan, interfaces = self:snapshot()
		local used_aliases = {}
		for id, path in pairs(self.paths) do
			local binding, reason = M.binding(path, mwan, interfaces)
			selected[id], path.excluded = binding, reason
			if path.enabled and path.family == 'ipv4' and states[id] == 'online' and not path.alias then
				path.error, path.excluded = 'NET reported online without an OpenWrt interface', nil
			end
			if binding then
				assert(not used_aliases[binding.alias], 'Multiple WAN paths claim OpenWrt interface ' .. binding.alias)
				used_aliases[binding.alias] = true
			end
		end
		local deadline = self.now() + args.timeout
		logs:wait_for('Devicecode results for selected online interfaces', deadline, function()
			assert(not failure, failure)
			if self.now() >= deadline then return true end
			for id, binding in pairs(selected) do
				local sample = self.paths[id].devicecode
				if not sample_matches(sample, binding) then return false end
			end
			return true
		end)
		assert(not failure, failure)
		assert(devicecode.same_pids(pids, self.runtime:service_pids()), 'Devicecode restarted during internal speedtests')
		self.runtime:service('stop')
		assert(not next(self.runtime:service_pids()), 'Devicecode is still running before external speedtests')
		logs:checkpoint('END tested speedtests')
		assert(not failure, failure)
		local has_measurement = false
		for id, binding in pairs(selected) do
			local sample = self.paths[id].devicecode
			if sample_matches(sample, binding) then has_measurement = true end
		end
		if has_measurement then
			self:check_box()
			self:install_cli()
		end
		local compared, errors = 0, {}
		for index, id in ipairs(util.keys(self.paths)) do
			local path = self.paths[id]
			if selected[id] then
				local ok, err = pcall(self.compare_path, self, path, index, selected[id])
				if not ok then
					if self.box.interrupted then error(err, 0) end
					path.error = tostring(err)
				end
			end
			if path.error then errors[#errors + 1] = id .. ': ' .. path.error end
			if path.difference then compared = compared + 1 end
			if path.excluded then print(('[%s] excluded %s (%s)'):format(PHASE, id, path.excluded)) end
		end
		self:write_results()
		assert(#errors == 0, table.concat(errors, '\n'))
		assert(compared > 0, 'No online WAN interface produced a comparison')
	end)
end

function Runner:run()
	return self.box:run(function()
		self:prepare()
		local archive = self.runtime:build(PHASE, self.config)
		self:check_box(self:deployment_size())
		self:exercise(archive)
	end, {
		diagnostics = function()
			if self.paths then self:write_results() end
			local commands = self.runtime:diagnostic_commands()
			commands.network = 'ubus call mwan3 status; ubus call network.interface dump; uci show mwan3'
			self.box.logs:diagnostics('failure', commands)
		end,
		restore = function() devicecode.restore(self.runtime, self.original_pids, self.box.args.timeout, self.now) end,
		success_message = 'PASS: compared Devicecode and CLI download rates on online WAN interfaces',
	})
end

return M
