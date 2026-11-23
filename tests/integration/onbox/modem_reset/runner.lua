local support = require 'onbox.support.runner'
local devicecode = require 'onbox.support.devicecode'
local log_support = require 'onbox.support.logs'
local modem_support = require 'onbox.support.modem'
local recovery_timing = require 'onbox.modem_recovery.timing'
local process = require 'onbox.support.process'
local util = require 'onbox.support.util'

local M = {}
local Runner = {}
Runner.__index = Runner
local PHASE = 'modem-reset'

function M.parse_args(argv, repo, here, timing)
	local values = { ['--imei'] = 'imei' }
	if timing then
		values['--max-connected-seconds'], values['--max-online-seconds'] = 'max_connected_s', 'max_online_s'
	end
	local phase = timing and 'modem-recovery' or PHASE
	local args = support.parse_args(argv, repo, here, { prefix = phase, values = values })
	assert(not args.imei or args.imei:match('^%d+$'), 'IMEI must contain digits only')
	for _, field in ipairs({ 'max_connected_s', 'max_online_s' }) do
		if args[field] then
			local value = assert(tonumber(args[field]), 'Invalid recovery timing limit')
			assert(value > 0 and value < math.huge, 'Recovery timing limits must be positive and finite')
			args[field] = value
		end
	end
	args.measure_recovery, args.phase = timing, phase
	return args
end

local function physical_port(modem)
	return modem.device:match('[^/]+$')
end

function M.select_targets(inventory, wanted)
	local imeis = wanted and { wanted } or util.keys(inventory)
	assert(wanted or #imeis >= 2, 'The full reset test requires at least two detected modems')
	local targets = {}
	for _, imei in ipairs(imeis) do
		local suffix = imei:sub(-4)
		local modem = assert(inventory[imei], 'Selected modem …' .. suffix .. ' is absent')
		assert(modem.state == 'connected', 'Modem …' .. suffix .. ' must be connected before testing')
		local port = assert(physical_port(modem), 'Modem …' .. suffix .. ' has no physical device path')
		for other_imei, other in pairs(inventory) do
			assert(other_imei == imei or other_imei:sub(-4) ~= suffix or physical_port(other) ~= port,
				'Ambiguous modem identity at ' .. port)
		end
		targets[imei] = { imei_suffix = suffix, device = port, events = {} }
	end
	return targets
end

function M.parse_lifecycle(line, target)
	local source, what, summary = line:match('%f[%w]LOG%s+(%S+)%s+info%s+(%S+)%s+(.+)$')
	if source ~= 'hal' and source ~= 'gsm' then return end
	if what ~= 'modem_removed' and what ~= 'modem_added' then return end
	local suffix, device, rest = summary:match('^imei_suffix=(%d+) device=(%S+)(.*)$')
	if suffix ~= target.imei_suffix or device ~= target.device then return end
	local id
	if source == 'hal' then
		id = rest:match('^ address=/org/freedesktop/ModemManager1/Modem/(%d+)%s*$')
		if not id then return end
	elseif not rest:match('^%s*$') then
		return
	end
	return { source = source, state = what:sub(7), object_id = id,
		monotonic_s = tonumber(line:match('%(mono=([%d.]+)%)')), event_monotonic_s = log_support.event_time(line) }
end

function M.from_session(box)
	local modems = modem_support.new(box)
	modems.watch_inventory = true
	return setmetatable({ box = box, runtime = devicecode.new(box), modems = modems, now = process.now }, Runner)
end

function M.new(args)
	return M.from_session(support.open(args, { 'hal', 'gsm', 'ModemManager', 'devicecode', 'error', 'failed' }))
end

function Runner:prepare()
	self.runtime:prepare()
	self.original_pids = self.runtime:service_pids()
	self.runtime:ensure_dependencies({ commands = { mmcli = 'modemmanager' } }, 'modem-dependencies')
	self.config = self.runtime.persistent_existed
		and util.decode(util.read(self.box.artifacts .. '/original-persistent.json')) or self.runtime.original
	local args = self.box.args
	local inventory = self.modems:inventory(true)
	self.targets = M.select_targets(inventory, args.imei)
	if args.measure_recovery then self.timing = recovery_timing.new(self.config, self.targets, inventory, args) end
	self.runtime:backup()
end

function Runner:write_results()
	util.write(self.box.artifacts .. '/results.json', util.encode({ modems = self.targets }))
end

local function present(latest)
	return latest.hal and latest.hal.state == 'added' and latest.gsm and latest.gsm.state == 'added'
end

local function connected(modem, latest, target)
	return modem and modem.state == 'connected' and present(latest) and latest.hal.object_id == modem.id
		and physical_port(modem) == target.device
end

function Runner:reset(imei, previous_imei, latest, pids, receive)
	local target, logs = self.targets[imei], self.box.logs
	local removed, reset_latest = {}, {}
	local label = '…' .. target.imei_suffix .. ' on ' .. target.device
	local replacement, repeated_reset, gsm_reappeared
	local function track_timing(line, event, network_owner, status)
		if self.timing and target.before_object_id then
			return self.timing:observe_reset(imei, line, event, replacement, gsm_reappeared,
				network_owner == imei and status)
		end
	end
	local function observe(line)
		local owner, event, network_owner, status = receive(line)
		local owned = owner == imei and target.before_object_id ~= nil
		if not owned then
			return track_timing(line, nil, network_owner, status) == true or owner ~= nil or network_owner ~= nil
		end
		reset_latest[event.source] = event
		if event.source == 'hal' then
			if replacement then
				if event.state == 'removed' or event.object_id ~= replacement then repeated_reset = true end
			elseif event.state == 'removed' and event.object_id == target.before_object_id then
				removed.hal = true
			elseif event.state == 'added' and removed.hal and event.object_id ~= target.before_object_id then
				replacement = event.object_id
			end
		elseif event.state == 'removed' then
			removed.gsm, gsm_reappeared = true, false
		else
			gsm_reappeared = removed.gsm and replacement ~= nil
		end
		target.events[#target.events + 1] = event
		print(('[%s] %s %s modem %s%s'):format(self.box.args.phase or PHASE, label, event.source, event.state,
			event.object_id and ' (ModemManager object ' .. event.object_id .. ')' or ''))
		track_timing(line, event, network_owner, status)
		return true
	end
	local function reappeared()
		assert(not repeated_reset, 'HAL reported another modem replacement during reset of ' .. label)
		return gsm_reappeared and present(reset_latest) and (not self.timing or self.timing:complete(imei))
	end

	logs:checkpoint('BEGIN tested modem reset ' .. label, observe)
	assert(devicecode.same_pids(pids, self.runtime:service_pids()),
		'Devicecode restarted or stopped before reset of ' .. label)
	local inventory = self.modems:inventory(true)
	local before = assert(inventory[imei], 'Modem ' .. label .. ' disappeared before reset')
	assert(connected(before, latest[imei], target), label .. ' no longer matches the connected HAL and GSM baseline')
	assert(not self.timing or self.timing:online(imei), label .. ' NET interface is no longer online before reset')
	if previous_imei then
		local previous, modem = self.targets[previous_imei], inventory[previous_imei]
		assert(connected(modem, latest[previous_imei], previous) and modem.id == previous.after_object_id,
			('Modem …%s on %s lost its verified connection before reset of %s'):format(
				previous.imei_suffix, previous.device, label))
		assert(not self.timing or self.timing:online(previous_imei), 'Previous modem NET interface went offline again')
	end
	assert(before.id:match('^%d+$'), 'Invalid ModemManager ID')
	print(('[%s] Resetting modem %s (ModemManager object %s)'):format(self.box.args.phase or PHASE, label, before.id))
	target.before_object_id = before.id
	self.box.ssh:run('mmcli -m ' .. before.id .. ' --reset', { timeout = 45 })

	local expectation = self.timing and 'modem reappearance, GSM connected and NET online for '
		or 'modem removal and reappearance in HAL and GSM for '
	local deadline = self.now() + self.box.args.timeout
	logs:wait_for(expectation .. label, deadline, reappeared)
	local after = assert(self.modems:inventory(true)[imei],
		'Modem ' .. label .. ' is absent from ModemManager after reset')
	assert(after.id == replacement and physical_port(after) == target.device,
		'ModemManager did not confirm the same modem on the new HAL object for ' .. label)
	if self.timing then
		local seen = self.timing:status_version(imei)
		local online, reason = self.timing:verify_live(self.box, imei)
		while not online do
			assert(self.now() < deadline, label .. ' did not stay online: ' .. tostring(reason))
			logs:wait_for('fresh NET online report for ' .. label .. ' after ' .. tostring(reason), deadline, function()
				return reappeared() and self.timing:status_version(imei) ~= seen
			end)
			seen = self.timing:status_version(imei)
			online, reason = self.timing:verify_live(self.box, imei)
		end
	end
	logs:checkpoint('END tested modem reset ' .. label, function(line)
		local owner, _, network_owner = receive(line)
		return owner ~= nil or network_owner ~= nil
	end)
	assert(reappeared(), 'Modem ' .. label .. ' was removed again before the final checkpoint')
	assert(devicecode.same_pids(pids, self.runtime:service_pids()),
		'Devicecode restarted or stopped during reset of ' .. label)
	target.after_object_id = after.id
	if self.timing then self.timing:verify(imei, after) end
end

function Runner:exercise(archive)
	self.box:phase(self.box.args.phase or PHASE, function()
		local latest = {}
		local imeis = util.keys(self.targets)
		for _, imei in ipairs(imeis) do latest[imei] = {} end
		local function receive(line)
			local network_owner, status
			if self.timing then network_owner, status = self.timing:observe_net(line) end
			for imei, target in pairs(self.targets) do
				local event = M.parse_lifecycle(line, target)
				if event then
					latest[imei][event.source] = event
					return imei, event, network_owner, status
				end
			end
			return nil, nil, network_owner, status
		end
		local function observe_baseline(line)
			local owner, _, network_owner = receive(line)
			return owner ~= nil or network_owner ~= nil
		end

		self.runtime:deploy(archive)
		self.runtime:write_config(self.config)
		assert(not next(self.runtime:service_pids()), 'Original Devicecode process is still running')
		self.box.logs:checkpoint('BEGIN modem reset baseline', observe_baseline)
		self.runtime:service('start')
		self.modems:wait(self.targets, 'connected')
		self.box.logs:wait_for('HAL and GSM baseline for all selected modems', self.now() + self.box.args.timeout, function()
			for _, imei in ipairs(imeis) do if not present(latest[imei]) then return false end end
			return true
		end)
		if self.timing then
			self.box.logs:wait_for('NET online baseline for all selected modems', self.now() + self.box.args.timeout, function()
				for _, imei in ipairs(imeis) do if not self.timing:online(imei) then return false end end
				return true
			end)
		end
		local pids = self.runtime:service_pids()
		assert(next(pids), 'Devicecode is not running before modem reset')
		for index, imei in ipairs(imeis) do
			self:reset(imei, imeis[index - 1], latest, pids, receive)
			if index < #imeis then self.modems:wait({ [imei] = self.targets[imei] }, 'connected') end
		end
		self:write_results()
		if self.timing then self.timing:check_limits() end
	end)
end

function Runner:run()
	return self.box:run(function()
		self:prepare()
		self:exercise(self.runtime:build(self.box.args.phase or PHASE, self.config))
	end, {
		diagnostics = function()
			local commands = self.runtime:diagnostic_commands()
			for name, command in pairs(self.modems:diagnostic_commands()) do commands[name] = command end
			if self.targets then self:write_results() end
			self.box.logs:diagnostics('failure', commands)
		end,
		restore = function() devicecode.restore(self.runtime, self.original_pids, self.box.args.timeout, self.now) end,
		success_message = self.box.args.measure_recovery
			and 'PASS: measured recovery through NET online for every selected modem'
			or 'PASS: every selected modem disappeared and reappeared in HAL and GSM after its reset',
	})
end

return M
