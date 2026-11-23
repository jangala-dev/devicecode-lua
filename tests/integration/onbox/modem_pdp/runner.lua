local support = require 'onbox.support.runner'
local devicecode = require 'onbox.support.devicecode'
local modem_support = require 'onbox.support.modem'
local util = require 'onbox.support.util'
local tablex = require 'shared.table'

local M = {}

---@param config table<string, any>
---@param modem OnboxModemInfo
---@return table<string, any>
function M.effective_config(config, modem)
	local modems = config.gsm.data.modems
	local result = tablex.deep_copy(modems.default or {})
	if result.pdp_type == nil then result.pdp_type = 'IP' end
	for _, entry in ipairs(modems.known or {}) do
		local field = entry.id_field or 'imei'
		if (field == 'device' and entry.device == modem.device)
			or (field ~= 'device' and entry.imei == modem.imei) then
			for key, value in pairs(entry) do result[key] = value end
			break
		end
	end
	return result
end

---@param original table<string, any>
---@param pdp_type string
---@return table<string, any>
function M.phase_config(original, pdp_type)
	local result = tablex.deep_copy(original)
	result.gsm.rev = (result.gsm.rev or 0) + 1
	local modems = result.gsm.data.modems
	modems.default = modems.default or {}
	modems.default.pdp_type = pdp_type
	for _, entry in ipairs(modems.known or {}) do entry.pdp_type = pdp_type end
	return result
end

---@param response table<string, string[]>
---@param expected string
---@return table[] active_contexts
function M.check_contexts(response, expected)
	-- Independently check the raw responses, without calling the production parser.
	local contexts, activations, active = {}, {}, {}
	for _, line in ipairs(assert(response['AT+CGDCONT?'])) do
		if line:match('^%+CGDCONT:') then
			local cid, pdp_type, apn = line:match(
				'^%+CGDCONT:%s*(%d+)%s*,%s*"([^"]+)"%s*,%s*"([^"]*)"%s*,%s*"[^"]*"')
			cid = tonumber(cid)
			assert(cid and cid > 0 and not contexts[cid], 'Malformed or duplicate CGDCONT response')
			contexts[cid] = { cid = cid, pdp_type = pdp_type, apn = apn }
		end
	end
	for _, line in ipairs(assert(response['AT+CGACT?'])) do
		if line:match('^%+CGACT:') then
			local cid, enabled = line:match('^%+CGACT:%s*(%d+)%s*,%s*([01])%s*$')
			cid = tonumber(cid)
			assert(cid and cid > 0 and activations[cid] == nil, 'Malformed or duplicate CGACT response')
			activations[cid] = enabled == '1'
		end
	end
	for cid, enabled in pairs(activations) do
		if enabled then
			local context = assert(contexts[cid], 'Active CID missing from CGDCONT response: ' .. cid)
			assert(context.pdp_type == expected,
				('CID %d: expected %s, got %s'):format(cid, expected, context.pdp_type))
			active[#active + 1] = context
		end
	end
	assert(#active > 0, 'No active contexts: refusing to treat an empty result as a pass')
	table.sort(active, function(a, b) return a.cid < b.cid end)
	return active
end

function M.restart_order()
	-- After replacing a modem object, GSM must inspect the current PDP contexts
	-- before spending another restart reservation or failing open.
	local awaiting_inspection, recognised, first_error = {}, 0, nil
	local function inspect(line)
		-- logread preserves the monitor timestamp and may add a syslog prefix.
		-- Locate the LOG columns independently of those prefixes.
		local service, _, event = line:match('%f[%w]LOG%s+(%S+)%s+(%S+)%s+(%S+)%s+')
		if service == 'gsm' and (event == 'pdp_contexts_checked' or event == 'pdp_restart'
			or event == 'pdp_enforcement_exhausted' or event == 'autoconnect_failed'
			or event == 'pdp_restart_unobserved') then
			recognised = recognised + 1
			local modem = assert(line:match('%smodem=([^%s]+)'), event .. ' is missing modem')
			if event == 'pdp_contexts_checked' then
				awaiting_inspection[modem] = nil
			elseif event == 'pdp_restart' and not line:match('%serr=[^%s]+') then
				assert(not awaiting_inspection[modem],
					('PDP modem %s restarted twice without an intervening context inspection'):format(modem))
				awaiting_inspection[modem] = true
			elseif event == 'pdp_enforcement_exhausted'
				and line:find('budget_kind=restart', 1, true) then
				assert(not awaiting_inspection[modem],
					('PDP modem %s exhausted its restart budget before post-reset inspection'):format(modem))
			elseif (event == 'autoconnect_failed' or event == 'pdp_restart_unobserved')
				and (line:find('err=pdp_restart_state_timeout', 1, true)
					or line:find('err=state subscription interrupted', 1, true)) then
				-- A successful RPC without a transition is not proof that the modem
				-- reset. Retrying it is existing behaviour and does not require inspection.
				awaiting_inspection[modem] = nil
			end
		end
	end
	local function observe(line)
		if first_error then return end
		local ok, err = pcall(inspect, line)
		if not ok then first_error = err end
	end
	local function verify()
		if first_error then error(first_error, 0) end
		assert(recognised > 0, 'No PDP lifecycle events recognised in monitor-format logs')
		for modem in pairs(awaiting_inspection) do
			error(('PDP modem %s reached the end of the phase without post-reset inspection'):format(modem), 0)
		end
	end
	return observe, verify
end

function M.check_restart_order(content)
	local observe, verify = M.restart_order()
	for line in content:gmatch('[^\n]+') do observe(line) end
	verify()
end

---@class PdpBoxArgs: OnboxArgs
---@field first string
---@field second string

---@class PdpBoxRunner
---@field box OnboxSession
---@field runtime OnboxDevicecode
---@field modems OnboxModems
---@field targets table<string, OnboxModemInfo>
---@field summary table[]
local Runner = {}
Runner.__index = Runner

---@param argv string[]
---@param repo string
---@param here string
---@return PdpBoxArgs
function M.parse_args(argv, repo, here)
	local args = support.parse_args(argv, repo, here, {
		prefix = 'pdp-box',
		defaults = { first = 'IP', second = 'IPV4V6' },
		values = { ['--first'] = 'first', ['--second'] = 'second' },
	})
	---@cast args PdpBoxArgs
	local valid = { IP = true, IPV4V6 = true, IPV6 = true }
	assert(valid[args.first] and valid[args.second] and args.first ~= args.second,
		'Choose different first/second PDP types: IP, IPV4V6, IPV6')
	return args
end

---@param box OnboxSession
---@return PdpBoxRunner
function M.from_session(box)
	return setmetatable({ box = box, runtime = devicecode.new(box), modems = modem_support.new(box),
		targets = {}, summary = {} }, Runner)
end

---@param args PdpBoxArgs
---@return PdpBoxRunner
function M.new(args)
	local instance = M.from_session(support.open(args, { 'gsm', 'pdp', 'devicecode', 'error', 'failed' }))
	instance.modems.watch_inventory = true
	return instance
end

---@return nil
function Runner:prepare()
	self.runtime:prepare()
	self.original_pids = self.runtime:service_pids()
	self.runtime:ensure_dependencies({ commands = { mmcli = 'modemmanager' } }, 'modem-dependencies')
	-- The service runs on the saved config when there is one, so phases start from it rather
	-- than the bootstrap config, which would replace the box's own settings.
	self.active = self.runtime.persistent_existed
		and util.decode(util.read(self.box.artifacts .. '/original-persistent.json')) or self.runtime.original
	for imei, info in pairs(self.modems:inventory()) do
		local cfg = M.effective_config(self.active, info)
		if cfg.enabled ~= false and cfg.autoconnect then
			assert(info.plugin:lower():find('quectel', 1, true), 'Unsupported modem: ' .. info.model)
			assert(info.state ~= 'locked' and info.state ~= 'failed',
				('Modem …%s is %s: %s'):format(imei:sub(-4), info.state, info.failed_reason or ''))
			info.name = cfg.name or imei:sub(-4)
			self.targets[imei] = info
		end
	end
	assert(next(self.targets), 'No configured Quectel modems with autoconnect enabled')
	self.modems:ensure_at_ports(self.targets)
	self.runtime:backup()
	for _, imei in ipairs(util.keys(self.targets)) do
		local info = self.targets[imei]
		print(('Target: %s (%s, …%s)'):format(info.name, info.model, imei:sub(-4)))
	end
end

---@param label string
---@param config table
---@return nil
function Runner:inspect(label, config)
	local current, results = self.modems:wait(self.targets, 'connected', nil, true), {}
	for _, imei in ipairs(util.keys(current)) do
		local info = current[imei]
		local expected = M.effective_config(config, info).pdp_type
		local reply = self.modems:probe(info, { 'AT+CGDCONT?', 'AT+CGACT?' })
		util.write(self.box.artifacts .. '/' .. label .. '-' .. imei .. '-at.log', reply.stdout .. reply.stderr)
		assert(reply.code == 0,
			'AT probe failed for …' .. imei:sub(-4) .. '; see ' .. label .. '-' .. imei .. '-at.log')
		local active, cids = M.check_contexts(util.decode(reply.stdout), expected), {}
		for _, context in ipairs(active) do cids[#cids + 1] = tostring(context.cid) end
		results[#results + 1] = { imei = imei, expected = expected, active_contexts = active }
		print(('[%s] PASS %s …%s: active CIDs [%s] use %s'):format(
			label, self.targets[imei].name, imei:sub(-4), table.concat(cids, ','), expected))
	end
	self.modems:wait(self.targets, 'connected')
	self.box.logs:checkpoint('END ' .. label .. ' tested runtime')
	self.verify_restart_order()
	self.summary[#self.summary + 1] = { phase = label, modems = results }
	util.write(self.box.artifacts .. '/results.json', util.encode(self.summary))
end

-- Arm the PDP observer after the old service stops and before the tested service starts.
function Runner:mark_tested_runtime(label)
	local observe, verify = M.restart_order()
	self.box.logs:checkpoint('BEGIN ' .. label .. ' tested runtime', observe)
	self.verify_restart_order = verify
end

---@param label string
---@param config table
---@param archive string?
---@param write_config fun()? Puts the phase's configuration in place; defaults to writing config.
---@return nil
function Runner:phase(label, config, archive, write_config)
	print('[' .. label .. '] Deploying and resetting modems for a clean-boot test')
	self.box:phase(label, function()
		self.runtime:deploy(archive)
		self:mark_tested_runtime(label)
		if write_config then write_config() else self.runtime:write_config(config) end
		self.modems:clean_boot(self.targets, true)
		self.runtime:service('restart')
		self:inspect(label, config)
	end)
end

---@return nil
function Runner:rollback()
	print('Rolling back the original runtime and configuration')
	local resumed, resume_err = pcall(function() self.modems:resume_manager() end)
	self.runtime:restore_runtime()
	local reset, reset_err = pcall(function() self.modems:clean_boot(self.targets) end)
	if next(self.original_pids) then self.runtime:service('start') end
	if not resumed then error(resume_err, 0) end
	if not reset then error(reset_err, 0) end
end

---@return integer exit_code
function Runner:run()
	---@type PdpBoxArgs
	local args = self.box.args
	return self.box:run(function()
		self:prepare()
		for _, phase in ipairs({ { '01-ip', args.first }, { '02-alternate', args.second } }) do
			local config = M.phase_config(self.active, phase[2])
			self:phase(phase[1], config, self.runtime:build(phase[1], config))
		end
		-- Prove the original settings on the candidate code before restoring the original runtime.
		self:phase('03-restored-config', self.active, nil, function()
			self.runtime:write_config(self.runtime.original)
			self.runtime:restore_persistent()
		end)
	end, {
		diagnostics = function()
			local commands = self.runtime:diagnostic_commands()
			for name, command in pairs(self.modems:diagnostic_commands()) do commands[name] = command end
			self.box.logs:diagnostics('failure', commands)
		end,
		restore = function(failed)
			if not self.runtime.changed then return end
			if failed then self:rollback()
			else
				self.runtime:restore_runtime()
				if next(self.original_pids) then self.runtime:service('start') end
			end
		end,
		success_message = 'PASS: all phases verified',
	})
end

return M
