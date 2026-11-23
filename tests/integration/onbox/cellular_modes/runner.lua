local support = require 'onbox.support.runner'
local devicecode = require 'onbox.support.devicecode'
local modem_support = require 'onbox.support.modem'
local process = require 'onbox.support.process'
local util = require 'onbox.support.util'
local ui_logs = require 'onbox.support.ui_logs'
local tablex = require 'shared.table'
local modes = require 'services.hal.types.modem_modes'
local quote = process.quote

local M = {}
local Runner = {}
Runner.__index = Runner

local function normalize(preferred, allowed)
	local result, err = modes.normalize(preferred, allowed)
	assert(result, err)
	return result
end

local function generations(text)
	assert(type(text) == 'string' and text ~= '' and not text:match('^%s*,')
		and not text:match(',%s*$') and not text:match(',%s*,'), 'Malformed allowed generation list')
	local result = {}
	for token in text:gmatch('[^,]+') do result[#result + 1] = util.trim(token) end
	return result
end

-- Read the actual mmcli format independently of the production backend parser.
function M.parse_pair(text)
	assert(type(text) == 'string', 'Missing mmcli mode combination')
	local allowed, preferred = text:match('^%s*allowed:%s*(.-);%s*preferred:%s*(.-)%s*$')
	assert(allowed, 'Malformed mmcli mode combination: ' .. text)
	local result = normalize(preferred, generations(allowed))
	assert(preferred == 'none' or modes.includes(result, preferred), 'mmcli preferred mode is not allowed')
	return result
end

local function contains(supported, pair)
	for _, candidate in ipairs(supported) do if modes.equal(candidate, pair) then return true end end
	return false
end

local function safe_pair(pair)
	return pair.preferred ~= '2g' and not modes.includes(pair, '2g')
end

local function mode_rank(pair)
	if not modes.includes(pair, '4g') then return 4 end
	if #pair.allowed == 1 then return 1 end
	return pair.preferred == '4g' and 2 or 3
end

function M.choose_pair(current, supported, configured, requested)
	if requested then
		assert(safe_pair(requested), 'The test cannot request 2G: it can brownout the modem')
		assert(contains(supported, requested), 'Requested pair is not supported by the selected modem')
		assert(not modes.equal(requested, current), 'Requested pair already matches current modem modes')
		assert(not modes.equal(requested, configured), 'Requested pair already matches the box configuration')
		return requested
	end
	local best
	for _, candidate in ipairs(supported) do
		if safe_pair(candidate) and not modes.equal(candidate, current) and not modes.equal(candidate, configured) then
			if not best or mode_rank(candidate) < mode_rank(best)
				or (mode_rank(candidate) == mode_rank(best) and modes.key(candidate) < modes.key(best)) then
				best = candidate
			end
		end
	end
	return assert(best, 'No different supported pair without 2G; select a different modem with --imei')
end

function M.choose_unsupported(supported)
	local allowed_generations = { '3g', '4g', '5g' }
	for mask = 1, 7 do
		local allowed = {}
		for index, generation in ipairs(allowed_generations) do
			if math.floor(mask / 2 ^ (index - 1)) % 2 == 1 then allowed[#allowed + 1] = generation end
		end
		local pair = normalize('none', allowed)
		if not contains(supported, pair) then return pair end
		for _, preferred in ipairs(allowed) do
			pair = normalize(preferred, allowed)
			if not contains(supported, pair) then return pair end
		end
	end
	-- An advertised preferred generation must be in its allowed set.
	return normalize('3g', { '4g' })
end

-- GSM inherits each missing mode field from the default. An explicit
-- allowed list replaces the default list as a whole.
local function merge_mode_request(default, override)
	if override == nil then return tablex.deep_copy(default) end
	local result = tablex.deep_copy(override)
	if type(result) == 'table' and type(default) == 'table' then
		if result.preferred == nil then result.preferred = default.preferred end
		if result.allowed == nil then result.allowed = tablex.deep_copy(default.allowed) end
	end
	return result
end

local function configured_pair(request)
	if type(request) == 'table' then
		return modes.normalize(request.preferred, request.allowed)
	end
end

local function check_config(config, label)
	local modems = assert(config.gsm and config.gsm.data and config.gsm.data.modems, 'Missing GSM modem config')
	local function check(request, name)
		local pair = configured_pair(request)
		assert(not pair or safe_pair(pair),
			label .. ' explicitly configures 2G for ' .. name .. '; remove it before restarting Devicecode')
	end
	local default = (modems.default or {}).cellular_modes
	check(default, 'modems.default')
	for index, entry in ipairs(modems.known or {}) do
		check(merge_mode_request(default, entry.cellular_modes), 'modems.known[' .. index .. ']')
	end
end

function M.effective_config(config, info)
	local modems = assert(config.gsm and config.gsm.data and config.gsm.data.modems, 'Missing GSM modem config')
	local result = tablex.deep_copy(modems.default or {})
	for _, entry in ipairs(modems.known or {}) do
		if (entry.id_field == 'device' and info.device and info.device ~= '' and entry.device == info.device)
			or (entry.id_field ~= 'device' and entry.imei == info.imei) then
			for key, value in pairs(entry) do
				if key == 'cellular_modes' then result[key] = merge_mode_request(result[key], value)
				else result[key] = tablex.deep_copy(value) end
			end
			break
		end
	end
	return result
end

function M.phase_config(original, targets, requested, revision)
	local config = tablex.deep_copy(original)
	config.gsm.rev = (config.gsm.rev or 0) + revision
	local entries = {}
	for _, imei in ipairs(util.keys(targets)) do
		local target = targets[imei]
		local entry = M.effective_config(original, target.info)
		entry.id_field, entry.imei, entry.device = 'imei', imei, nil
		entry.name = target.name
		entry.cellular_modes = tablex.deep_copy(assert(requested[imei]))
		entries[#entries + 1] = entry
	end
	-- IMEI entries precede physical-path entries so the test setting wins deterministically.
	for _, entry in ipairs(config.gsm.data.modems.known or {}) do entries[#entries + 1] = entry end
	config.gsm.data.modems.known = entries
	return config
end

function M.matches_record(record, target, requested, event)
	if record.service ~= 'gsm' or record.what ~= event
		or (event == 'cellular_modes_unsupported' and record.level ~= 'warn') then
		return false
	end
	local payload = record.payload
	if type(payload) ~= 'table' or payload.modem ~= target.name or type(payload.requested) ~= 'table' then
		return false
	end
	local pair = payload.requested
	local canonical = modes.normalize(pair.preferred, pair.allowed)
	return canonical ~= nil and modes.equal(canonical, requested)
end

function M.parse_args(argv, repo, here)
	local args = support.parse_args(argv, repo, here, { prefix = 'cellular-modes', values = {
		['--imei'] = 'imei', ['--preferred'] = 'preferred', ['--allowed'] = 'allowed', ['--ui-url'] = 'ui_url',
	} })
	assert((args.preferred == nil) == (args.allowed == nil), 'Use --preferred and --allowed together')
	if args.preferred then
		args.requested = normalize(args.preferred, generations(args.allowed))
		assert(safe_pair(args.requested),
			'2G is disabled in this on-box test: it can brownout the modem')
		assert(args.preferred == 'none' or modes.includes(args.requested, args.preferred),
			'The valid test pair must include the preferred generation in allowed')
	end
	if args.imei then assert(args.imei:match('^%d+$'), 'IMEI must contain digits only') end
	if args.ui_url then
		assert(args.ui_url:match('^https?://'), '--ui-url must be an HTTP(S) base URL on the box')
		args.ui_url = args.ui_url:gsub('/+$', '')
	end
	return args
end

function M.from_session(box)
	return setmetatable({ box = box, runtime = devicecode.new(box), modems = modem_support.new(box),
		targets = {}, summary = {}, now = process.now, pause = process.pause, follow_logs = ui_logs.follow }, Runner)
end

function M.new(args)
	return M.from_session(support.open(args, { 'gsm', 'cellular_modes', 'devicecode', 'error', 'failed' }))
end

function Runner:read_modes(imei)
	local info = assert(self.modems:inventory()[imei], 'Modem missing: ' .. imei)
	local result = self.box.ssh:run('mmcli -m ' .. quote(info.id) .. ' -J', { timeout = 20 })
	local data = util.decode(result.stdout)
	local generic = assert(data.modem.generic)
	assert(tostring(generic['equipment-identifier']) == imei, 'Modem ID changed while querying ' .. imei)
	local supported, raw = {}, generic['supported-modes']
	if type(raw) == 'string' then raw = { raw } end
	for _, text in ipairs(raw or {}) do supported[#supported + 1] = M.parse_pair(text) end
	return M.parse_pair(generic['current-modes']), supported, data, info
end

function Runner:prepare()
	self.runtime:prepare()
	self.runtime:ensure_dependencies({ commands = { mmcli = 'modemmanager', curl = 'curl', ubus = 'ubus' } },
		'cellular-mode-dependencies')
	self.original = self.runtime.persistent_existed
		and util.decode(util.read(self.box.artifacts .. '/original-persistent.json')) or self.runtime.original
	check_config(self.runtime.original, 'Bootstrap config')
	if self.runtime.persistent_existed then check_config(self.original, 'Persistent config') end
	local ui = assert(self.original.ui and self.original.ui.data, 'Local UI config is required')
	assert(ui.enabled ~= false and (ui.http or {}).enabled ~= false, 'Local UI HTTP must be enabled')
	self.ui_url = self.box.args.ui_url or 'http://127.0.0.1:' .. tostring((ui.http or {}).port or 80)
	self.original_pids = self.runtime:service_pids()
	local names = {}
	local inventory = self.modems:inventory()
	for _, imei in ipairs(util.keys(inventory)) do
		local info = inventory[imei]
		local cfg = M.effective_config(self.original, info)
		if (not self.box.args.imei or self.box.args.imei == imei) and cfg.enabled ~= false then
			assert(info.state ~= 'failed' and info.state ~= 'locked', 'Modem is not usable: ' .. imei)
			local current, supported, raw = self:read_modes(imei)
			local configured = configured_pair(cfg.cellular_modes)
			local requested = M.choose_pair(current, supported, configured, self.box.args.requested)
			local name = cfg.name or imei
			assert(not names[name], 'Selected modems share a GSM name; select one with --imei')
			names[name] = true
			local restore_skip
			if not safe_pair(current) then restore_skip = 'original modes allow 2G'
			elseif not contains(supported, current) then restore_skip = 'original modes were not advertised' end
			self.targets[imei] = { info = info, name = name, original = current, configured = configured,
				requested = requested, unsupported = M.choose_unsupported(supported), restore_skip = restore_skip }
			util.write(self.box.artifacts .. '/original-' .. imei .. '-mmcli.json', util.encode(raw))
			print(('Target %s …%s: %s -> %s (configured: %s)'):format(name, imei:sub(-4),
				modes.key(current), modes.key(requested), configured and modes.key(configured) or 'unset'))
		end
	end
	assert(next(self.targets), 'No enabled modem matched the test selection')
	self.runtime:backup()
	util.write(self.box.artifacts .. '/mode-cases.json', util.encode(self.targets))
end

function Runner:wait_for(label, body)
	local deadline = self.now() + self.box.args.timeout
	local last_error
	repeat
		assert(not self.box.interrupted or self.box.recovering, 'Interrupted')
		local ok, result = pcall(body)
		if ok and result then return result end
		last_error = ok and 'not ready' or tostring(result)
		self.pause(2)
	until self.now() >= deadline
	error(label .. ': ' .. last_error, 0)
end

function Runner:wait_modes(label, expected)
	return self:wait_for(label .. ' mmcli modes', function()
		local results = {}
		for _, imei in ipairs(util.keys(self.targets)) do
			local actual, _, raw = self:read_modes(imei)
			local pair = assert(expected[imei])
			util.write(self.box.artifacts .. '/' .. label .. '-' .. imei .. '-mmcli.json', util.encode(raw))
			assert(modes.equal(actual, pair), imei .. ': expected ' .. modes.key(pair)
				.. ', got ' .. modes.key(actual))
			results[imei] = actual
		end
		return results
	end)
end

function Runner:wait_logs(label, requested, event)
	local records, remaining = {}, 0
	for _ in pairs(requested) do remaining = remaining + 1 end
	if remaining == 0 then return records end
	return self.follow_logs(self.box, self.ui_url, label, self.now() + self.box.args.timeout,
		function(record)
			local changed = false
			for imei, pair in pairs(requested) do
				if not records[imei] and M.matches_record(record, self.targets[imei], pair, event) then
					records[imei] = record
					remaining = remaining - 1
					changed = true
				end
			end
			return changed
		end,
		function() if remaining == 0 then return records end end,
		label .. ' local UI log ' .. event)
end

function Runner:phase(phase)
	local label, requested = phase.label, phase.requested
	local config = M.phase_config(self.original, self.targets, requested, phase.revision)
	local archive = self.runtime:build(label, config)
	self.box:phase(label, function()
		local previous = self.runtime:service_pids()
		self.runtime:deploy(archive)
		self.runtime:write_config(config)
		self.runtime:service('restart')
		self:wait_for(label .. ' fresh service process', function()
			local pids = self.runtime:service_pids()
			for pid in pairs(pids) do if previous[pid] then return false end end
			return next(pids) ~= nil
		end)
		local records = self:wait_logs(label, phase.log_requests or requested, phase.event or 'cellular_modes_applied')
		local actual = self:wait_modes(label, phase.expected or requested)
		local previous_phase = self.summary[#self.summary]
		local before = previous_phase and previous_phase.actual or {}
		if not previous_phase then
			for imei, target in pairs(self.targets) do before[imei] = target.original end
		end
		self.summary[#self.summary + 1] = { phase = label, before = before, requested = requested,
			actual = actual, records = records, restore_skipped = phase.restore_skipped }
		util.write(self.box.artifacts .. '/results.json', util.encode(self.summary))
		print('[' .. label .. '] PASS: ' .. phase.message)
	end)
end

function Runner:rollback()
	local errors = {}
	local function recover(body)
		local ok, err = pcall(body)
		if not ok then errors[#errors + 1] = tostring(err) end
	end
	self.runtime:restore_runtime()
	if next(self.original_pids) then recover(function() self.runtime:service('restart') end) end
	for _, imei in ipairs(util.keys(self.targets)) do
		local target = self.targets[imei]
		if not target.restore_skip then
			local original = target.original
			recover(function()
				self:wait_for('Restore modem ' .. imei, function()
					local actual, _, _, info = self:read_modes(imei)
					if modes.equal(actual, original) then return true end
					self.box.ssh:run('mmcli -m ' .. quote(info.id) .. ' --set-allowed-modes='
						.. quote(table.concat(original.allowed, '|'))
						.. ' --set-preferred-mode=' .. quote(original.preferred), { timeout = 45 })
					return modes.equal(self:read_modes(imei), original)
				end)
			end)
		else
			print(('Rollback: leaving %s …%s modem modes as-is; %s'):format(
				target.name, imei:sub(-4), target.restore_skip))
		end
	end
	assert(#errors == 0, table.concat(errors, '\n'))
end

function Runner:run()
	return self.box:run(function()
		self:prepare()
		local valid, unsupported, restored, restore_logs, skipped = {}, {}, {}, {}, {}
		for imei, target in pairs(self.targets) do
			valid[imei], unsupported[imei] = target.requested, target.unsupported
			if target.restore_skip then
				skipped[imei], restored[imei] = target.restore_skip, target.requested
			else
				restored[imei], restore_logs[imei] = target.original, target.original
			end
		end
		self:phase { label = '01-valid', revision = 1, requested = valid,
			message = 'different supported modes applied and verified' }
		self:phase { label = '02-unsupported', revision = 2, requested = unsupported,
			expected = valid, event = 'cellular_modes_unsupported',
			message = 'unsupported warnings recorded and modem modes unchanged' }
		self:phase { label = '03-restore', revision = 3, requested = restored, log_requests = restore_logs,
			restore_skipped = skipped, message = 'final safe modes verified' }
		for _, imei in ipairs(util.keys(skipped)) do
			print(('[03-restore] SKIP original modes for %s …%s: %s; kept phase-one modes'):format(
				self.targets[imei].name, imei:sub(-4), skipped[imei]))
		end
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
		success_message = 'PASS: mode application, rejection and eligible restoration checks passed',
	})
end

return M
