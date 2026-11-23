local support = require 'onbox.support.runner'
local devicecode = require 'onbox.support.devicecode'
local gsm = require 'onbox.support.gsm'
local modem_support = require 'onbox.support.modem'
local process = require 'onbox.support.process'
local util = require 'onbox.support.util'

local M = {}
local Runner = {}
Runner.__index = Runner
local PHASE = 'modem-startup'

function M.parse_args(argv, repo, here)
	local args = support.parse_args(argv, repo, here, {
		prefix = PHASE, values = { ['--imei'] = 'imei' },
	})
	assert(not args.imei or args.imei:match('^%d+$'), 'IMEI must contain digits only')
	return args
end

M.parse_transition = gsm.parse_transition

function M.select_targets(config, inventory, wanted)
	local targets, label_counts = {}, {}
	for _, imei in ipairs(util.keys(inventory)) do
		local modem = inventory[imei]
		local settings, name = gsm.modem_config(config, modem)
		local label = gsm.log_label(imei, name)
		label_counts[label] = (label_counts[label] or 0) + 1
		if (not wanted or imei == wanted) and settings.autoconnect then
			assert(imei:match('^%d+$'), 'An autoconnect modem is missing a usable IMEI')
			assert(modem.state == 'disabled' or modem.state == 'registered' or modem.state == 'connected',
				label .. ' is unavailable for startup testing: ' .. tostring(modem.state))
			targets[imei] = { label = label, initial_state = modem.state, transitions = {} }
		end
	end
	assert(next(targets), wanted and 'Selected modem is absent or has autoconnect off'
		or 'No detected modem with autoconnect enabled')
	for _, target in pairs(targets) do
		assert(label_counts[target.label] == 1, 'Ambiguous GSM modem label: ' .. target.label)
	end
	return targets
end

function M.from_session(box)
	return setmetatable({ box = box, runtime = devicecode.new(box), modems = modem_support.new(box),
		now = process.now }, Runner)
end

function M.new(args)
	return M.from_session(support.open(args, { 'gsm', 'ModemManager', 'devicecode', 'error', 'failed' }))
end

function Runner:prepare()
	self.runtime:prepare()
	self.original_pids = self.runtime:service_pids()
	self.runtime:ensure_dependencies({ commands = { mmcli = 'modemmanager' } }, 'modem-dependencies')
	self.config = self.runtime.persistent_existed
		and util.decode(util.read(self.box.artifacts .. '/original-persistent.json')) or self.runtime.original
	self.targets = M.select_targets(self.config, self.modems:inventory(not self.box.args.imei), self.box.args.imei)
	self.runtime:backup()
	for _, imei in ipairs(util.keys(self.targets)) do
		print('Testing autoconnect for ' .. self.targets[imei].label)
	end
end

function Runner:disable(targets)
	for _, imei in ipairs(util.keys(targets)) do
		local target = targets[imei]
		local modem = assert(self.modems:inventory()[imei], target.label .. ' is missing')
		if modem.state ~= 'disabled' then
			assert(modem.id:match('^%d+$'), 'Invalid ModemManager ID')
			self.box.ssh:run('mmcli -m ' .. modem.id .. ' --disable', { timeout = 45 })
		end
	end
	if next(targets) then self.modems:wait(targets, 'disabled') end
end

function Runner:write_results()
	util.write(self.box.artifacts .. '/results.json', util.encode({ modems = self.targets }))
end

local function last_state(target)
	local latest = target.transitions[#target.transitions]
	return latest and latest.state
end

function Runner:exercise(archive)
	self.box:phase(PHASE, function()
		self.runtime:deploy(archive)
		self.runtime:write_config(self.config)
		assert(not next(self.runtime:service_pids()), 'Devicecode is still running before the disabled baseline')
		self:disable(self.targets)
		local started = false
		self.box.logs:checkpoint('BEGIN tested modem startup', function(line)
			if not started then return false end
			for _, target in pairs(self.targets) do
				local event = M.parse_transition(line, target.label)
				if event then
					target.transitions[#target.transitions + 1] = event
					print(('[%s] %s -> %s'):format(PHASE, target.label, event.state))
					return true
				end
			end
			return false
		end)
		assert(not next(self.runtime:service_pids()), 'Devicecode restarted before the test explicitly started it')
		local before = self.modems:inventory(not self.box.args.imei)
		local selected_now = M.select_targets(self.config, before, self.box.args.imei)
		for imei, target in pairs(selected_now) do
			assert(self.targets[imei], target.label .. ' appeared after preflight; rerun with a stable modem inventory')
		end
		for _, imei in ipairs(util.keys(self.targets)) do
			local target = self.targets[imei]
			local modem = assert(before[imei], target.label .. ' disappeared before startup')
			assert(modem.state == 'disabled', target.label .. ' is no longer disabled before startup: ' .. tostring(modem.state))
			target.transitions[1] = { source = 'mmcli', state = modem.state }
		end
		started = true
		self.runtime:service('start')
		self.box.logs:wait_for('all selected modems to report GSM connected', self.now() + self.box.args.timeout, function()
			for _, target in pairs(self.targets) do
				if last_state(target) ~= 'connected' then return false end
			end
			return true
		end)
		self.box.logs:checkpoint('END tested modem startup')
		local after = self.modems:inventory(not self.box.args.imei)
		for _, imei in ipairs(util.keys(self.targets)) do
			local target = self.targets[imei]
			local latest = last_state(target)
			assert(latest == 'connected', target.label .. ' left connected before the final checkpoint: ' .. tostring(latest))
			local modem = assert(after[imei], target.label .. ' disappeared before the final check')
			assert(modem.state == 'connected', 'ModemManager did not confirm connected for '
				.. target.label .. ': ' .. tostring(modem.state))
			target.confirmed_state = modem.state
		end
		assert(next(self.runtime:service_pids()), 'Devicecode stopped before modem connection was verified')
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
		restore = function()
			if not self.runtime.changed then return end
			self.runtime:restore_runtime()
			if next(self.original_pids) then
				self.runtime:service('start')
			else
				local originally_disabled = {}
				for imei, target in pairs(self.targets) do
					if target.initial_state == 'disabled' then originally_disabled[imei] = target end
				end
				self:disable(originally_disabled)
			end
		end,
		success_message = 'PASS: all selected modems connected after starting Devicecode from disabled',
	})
end

return M
