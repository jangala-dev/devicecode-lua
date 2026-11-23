local support = require 'onbox.support.runner'
local devicecode = require 'onbox.support.devicecode'
local gsm = require 'onbox.support.gsm'
local modem_support = require 'onbox.support.modem'
local process = require 'onbox.support.process'
local util = require 'onbox.support.util'
local tablex = require 'shared.table'

local M = {}
local Runner = {}
Runner.__index = Runner
local PHASE = 'modem-autoconnect-off'

function M.parse_args(argv, repo, here)
	local args = support.parse_args(argv, repo, here, {
		prefix = PHASE, defaults = { observe_seconds = 60 }, values = { ['--observe-seconds'] = 'observe_seconds' },
	})
	args.observe_seconds = assert(tonumber(args.observe_seconds), 'Invalid observation duration')
	assert(args.observe_seconds > 0 and args.observe_seconds < math.huge,
		'Observation duration must be positive and finite')
	return args
end

function M.phase_config(original)
	local config = tablex.deep_copy(original)
	local modems = assert(config.gsm and config.gsm.data and config.gsm.data.modems, 'Missing GSM modem config')
	modems.default.autoconnect = false
	for _, entry in ipairs(modems.known or {}) do
		if type(entry) == 'table' then entry.autoconnect = false end
	end
	config.gsm.rev = (config.gsm.rev or 0) + 1
	return config
end

function M.select_targets(original, inventory)
	local imeis = util.keys(inventory)
	assert(#imeis >= 2, 'The autoconnect-off test requires at least two detected modems')
	local targets, labels = {}, {}
	for _, imei in ipairs(imeis) do
		local modem = inventory[imei]
		local settings, name = gsm.modem_config(original, modem)
		local label = gsm.log_label(imei, name)
		assert(not labels[label], 'Ambiguous GSM modem label: ' .. label)
		assert(modem.device and modem.device:match('[^/]+$'), label .. ' has no physical device path')
		assert(type(modem.state) == 'string' and modem.state ~= 'failed' and modem.state ~= 'locked',
			label .. ' is ' .. tostring(modem.state))
		labels[label] = true
		targets[imei] = { label = label, name = label, device = modem.device, original_state = modem.state,
			original_autoconnect = not not settings.autoconnect, gsm_events = {}, modemmanager_events = {} }
	end
	return targets
end

function M.from_session(box)
	local modems = modem_support.new(box)
	modems.watch_inventory = true
	return setmetatable({ box = box, runtime = devicecode.new(box), modems = modems, now = process.now }, Runner)
end

function M.new(args)
	return M.from_session(support.open(args, { 'gsm', 'ModemManager', 'devicecode', 'error', 'failed' }))
end

function Runner:prepare()
	self.runtime:prepare()
	self.original_pids = self.runtime:service_pids()
	self.runtime:ensure_dependencies({ commands = { mmcli = 'modemmanager' } }, 'modem-dependencies')
	local original = self.runtime.persistent_existed
		and util.decode(util.read(self.box.artifacts .. '/original-persistent.json')) or self.runtime.original
	self.config = M.phase_config(original)
	self.targets = M.select_targets(original, self.modems:inventory(true))
	self.runtime:backup()
end

function Runner:write_results()
	util.write(self.box.artifacts .. '/results.json', util.encode({ modems = self.targets,
		requested_observation_s = self.box.args.observe_seconds, observation_s = self.observation_s }))
end

function Runner:check_inventory(expected)
	local inventory = self.modems:inventory(true)
	for imei in pairs(inventory) do
		assert(self.targets[imei], 'A different modem appeared after preflight (…' .. imei:sub(-4) .. ')')
	end
	for imei, target in pairs(self.targets) do
		local modem = assert(inventory[imei], target.label .. ' is absent from ModemManager')
		assert(modem.state == 'disabled' and modem.device == target.device and modem.id == expected[imei],
			('%s is no longer the expected disabled ModemManager object (object %s, state %s)'):format(
				target.label, modem.id, modem.state))
	end
end

function Runner:exercise(archive)
	self.box:phase(PHASE, function()
		local args, logs = self.box.args, self.box.logs
		local imeis, expected, watches = util.keys(self.targets), {}, {}
		local targets_by_object = {}
		local failure
		local function record(target, source, events, event)
			events[#events + 1] = event
			local unexpected = event.state ~= 'disabled' and event.state or event.from
			if unexpected and unexpected ~= 'disabled' and not failure then
				failure = ('%s reported %s for %s, expected disabled'):format(source, unexpected, target.label)
			end
		end
		local function check_watches()
			assert(not failure, failure)
			for _, watch in pairs(watches) do watch:assert_open() end
		end

		self.runtime:deploy(archive)
		self.runtime:write_config(self.config)
		assert(not next(self.runtime:service_pids()), 'Devicecode is still running before modem reset')
		local fresh, old_ids = self.modems:clean_boot(self.targets)
		for _, imei in ipairs(imeis) do
			local target = self.targets[imei]
			local modem = assert(fresh[imei], target.label .. ' did not return after reset')
			local old_id = assert(old_ids[imei], target.label .. ' was absent before reset')
			assert(old_id ~= modem.id, target.label .. ' still has its pre-reset ModemManager object')
			target.old_object_id, target.object_id = old_id, modem.id
			expected[imei] = modem.id
			targets_by_object[modem.id] = target
		end
		self:check_inventory(expected)

		local monitor_deadline = self.now() + args.timeout
		for _, imei in ipairs(imeis) do
			local target = self.targets[imei]
			watches[imei] = self.modems:watch_state(target.object_id, 2 * args.timeout + args.observe_seconds + 120,
				function(event) record(target, 'ModemManager', target.modemmanager_events, event) end)
		end
		for _, imei in ipairs(imeis) do
			local target, watch = self.targets[imei], watches[imei]
			watch:wait_for('initial disabled state for ' .. target.label, monitor_deadline, function()
				check_watches()
				local initial = target.modemmanager_events[1]
				return initial and initial.kind == 'initial'
			end)
		end

		local started, producer_pid
		local function check_producer(line)
			local pid = gsm.monitor_pid(line)
			if not failure then
				if not pid then failure = 'Could not identify the Devicecode process producing GSM evidence'
				elseif producer_pid and producer_pid ~= pid then failure = 'Devicecode log producer changed after startup' end
			end
			producer_pid = pid
		end
		logs:checkpoint('BEGIN tested autoconnect-off startup', function(line)
			if not started then return false end
			local state = modem_support.parse_state_syslog(line)
			local owner = state and targets_by_object[state.object_id]
			if owner then
				record(owner, 'ModemManager syslog', owner.modemmanager_events, state)
				return true
			end
			if line:match('%f[%w]STA%s+monitor%s+start%s+profile=') then
				check_producer(line)
				return true
			end
			for _, imei in ipairs(imeis) do
				local target = self.targets[imei]
				local event = gsm.parse_transition(line, target.label) or gsm.parse_removal(line, imei, target.device)
				if event then
					check_producer(line)
					record(target, 'GSM', target.gsm_events, event)
					print(('[%s] %s -> %s'):format(PHASE, target.label, event.state))
					return true
				end
			end
			return false
		end)
		assert(not next(self.runtime:service_pids()), 'Devicecode restarted before the test explicitly started it')
		check_watches()
		started = true
		self.runtime:service('start')
		local pids = self.runtime:service_pids()
		assert(next(pids), 'Devicecode did not start')
		logs:wait_for('GSM disabled state for every selected modem', self.now() + args.timeout, function()
			check_watches()
			for _, imei in ipairs(imeis) do if not self.targets[imei].gsm_events[1] then return false end end
			assert(pids[producer_pid], 'GSM baseline was produced by a different Devicecode process')
			return true
		end)

		local observe_started = self.now()
		local observe_until = observe_started + args.observe_seconds
		print(('[%s] Observing all selected modems for %gs'):format(PHASE, args.observe_seconds))
		logs:wait_for('disabled observation window', observe_until, function()
			check_watches()
			return self.now() >= observe_until
		end)
		self.observation_s = self.now() - observe_started
		self:check_inventory(expected)
		for _, imei in ipairs(imeis) do watches[imei]:finish() end
		logs:checkpoint('END tested autoconnect-off observation')
		assert(devicecode.same_pids(pids, self.runtime:service_pids()), 'Devicecode stopped or restarted during observation')
		assert(not failure, failure)
		for _, imei in ipairs(imeis) do self.targets[imei].confirmed_state = 'disabled' end
		self:write_results()
	end)
end

function Runner:run()
	return self.box:run(function()
		self:prepare()
		self:exercise(self.runtime:build(PHASE, self.config))
	end, {
		diagnostics = function()
			local commands = self.runtime:diagnostic_commands()
			for name, command in pairs(self.modems:diagnostic_commands()) do commands[name] = command end
			if self.targets then self:write_results() end
			self.box.logs:diagnostics('failure', commands)
		end,
		restore = function() devicecode.restore(self.runtime, self.original_pids, self.box.args.timeout, self.now) end,
		success_message = 'PASS: all tested modems stayed disabled with autoconnect off',
	})
end

return M
