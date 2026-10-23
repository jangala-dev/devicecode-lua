local support = require 'onbox.support.runner'
local devicecode = require 'onbox.support.devicecode'
local modem_support = require 'onbox.support.modem'
local process = require 'onbox.support.process'
local util = require 'onbox.support.util'
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

function M.choose_pairs(current, supported, requested)
    assert(not modes.includes(current, '2g'), 'Original modes allow 2G; disable 2G before running this on-box test')
    assert(contains(supported, current), 'Original mmcli modes are not advertised; cannot verify restoration')
    local valid = requested
    if valid then
        assert(not modes.includes(valid, '2g'), '2G is disabled in this on-box test: it can brownout the modem')
        assert(contains(supported, valid), 'Requested pair is not supported by the selected modem')
        assert(not modes.equal(valid, current), 'Requested pair already matches current modes; choose a different pair')
    else
        local candidates = {}
        for _, candidate in ipairs(supported) do
            if not modes.includes(candidate, '2g') and not modes.equal(candidate, current) then
                candidates[#candidates + 1] = candidate
            end
        end
        local function rank(candidate)
            if modes.includes(candidate, '4g') then
                if #candidate.allowed == 1 then return 1 end
                if candidate.preferred == '4g' then return 2 end
                return 3
            end
            return 4
        end
        table.sort(candidates, function(a, b)
            if rank(a) ~= rank(b) then return rank(a) < rank(b) end
            return modes.key(a) < modes.key(b)
        end)
        valid = candidates[1]
        assert(valid, 'No alternative supported pair without 2G; select a different modem with --imei')
    end
    local all = { '3g', '4g', '5g' }
    for mask = 1, 7 do
        local allowed = {}
        for index, generation in ipairs(all) do
            if math.floor(mask / 2 ^ (index - 1)) % 2 == 1 then allowed[#allowed + 1] = generation end
        end
        local preferences = { 'none' }
        for _, generation in ipairs(allowed) do preferences[#preferences + 1] = generation end
        for _, preferred in ipairs(preferences) do
            local candidate = normalize(preferred, allowed)
            if not contains(supported, candidate) then return valid, candidate end
        end
    end
    -- Even a modem advertising every compliant pair cannot prefer an excluded generation.
    return valid, normalize('3g', { '4g' })
end

function M.effective_config(config, info)
    local modems = assert(config.gsm and config.gsm.data and config.gsm.data.modems, 'Missing GSM modem config')
    local result = tablex.deep_copy(modems.default or {})
    for _, entry in ipairs(modems.known or {}) do
        if (entry.id_field == 'device' and entry.device == info.device)
            or (entry.id_field ~= 'device' and entry.imei == info.imei) then
            for key, value in pairs(entry) do result[key] = tablex.deep_copy(value) end
            break
        end
    end
    return result
end

function M.phase_config(original, targets, field, revision)
    local config = tablex.deep_copy(original)
    config.gsm.rev = (config.gsm.rev or 0) + revision
    local entries = {}
    for _, imei in ipairs(util.keys(targets)) do
        local target = targets[imei]
        local entry = M.effective_config(original, target.info)
        entry.id_field, entry.imei, entry.device = 'imei', imei, nil
        entry.name = target.name
        entry.cellular_modes = tablex.deep_copy(target[field])
        entries[#entries + 1] = entry
    end
    -- IMEI entries precede physical-path entries so the test setting wins deterministically.
    for _, entry in ipairs(config.gsm.data.modems.known or {}) do entries[#entries + 1] = entry end
    config.gsm.data.modems.known = entries
    return config
end

function M.find_record(reply, target, expected, what)
    for _, record in ipairs(reply.records or {}) do
        local payload = record.payload or {}
        local pair = payload.requested
        if record.service == 'gsm' and record.what == what and payload.modem == target.name
            and (what ~= 'cellular_modes_unsupported' or record.level == 'warn')
            and type(pair) == 'table' then
            local canonical = modes.normalize(pair.preferred, pair.allowed)
            if canonical and modes.equal(canonical, expected) then return record end
        end
    end
end

function M.parse_args(argv, repo, here)
    local args = support.parse_args(argv, repo, here, { prefix = 'cellular-modes', values = {
        ['--imei'] = 'imei', ['--preferred'] = 'preferred', ['--allowed'] = 'allowed', ['--ui-url'] = 'ui_url',
    } })
    assert((args.preferred == nil) == (args.allowed == nil), 'Use --preferred and --allowed together')
    if args.preferred then
        args.requested = normalize(args.preferred, generations(args.allowed))
        assert(not modes.includes(args.requested, '2g'),
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
        targets = {}, summary = {}, now = process.now, pause = process.pause }, Runner)
end

function M.new(args)
    return M.from_session(support.open(args, { 'gsm', 'cellular_modes', 'devicecode', 'error', 'failed' }))
end

function Runner:read_modes(imei)
    local info = assert(self.modems:inventory()[imei], 'Modem missing: ' .. imei)
    local result = self.box.ssh:run('mmcli -m ' .. quote(info.id) .. ' -J', { timeout = 20 })
    local generic = assert(util.decode(result.stdout).modem.generic)
    assert(tostring(generic['equipment-identifier']) == imei, 'Modem ID changed while querying ' .. imei)
    local supported, raw = {}, generic['supported-modes']
    if type(raw) == 'string' then raw = { raw } end
    for _, text in ipairs(raw or {}) do supported[#supported + 1] = M.parse_pair(text) end
    return M.parse_pair(generic['current-modes']), supported, util.decode(result.stdout)
end

function Runner:service_pids()
    local name = assert(self.box.args.service:match('([^/]+)$'))
    local result = self.box.ssh:run('ubus call service list ' .. quote(util.encode({ name = name })),
        { timeout = 15, check = false })
    if result.code ~= 0 then return {} end
    local service = util.decode(result.stdout)[name] or {}
    local pids = {}
    for _, instance in pairs(service.instances or {}) do
        if instance.running and instance.pid then pids[tostring(instance.pid)] = true end
    end
    return pids
end

function Runner:prepare()
    self.runtime:prepare()
    self.runtime:ensure_dependencies({ commands = { mmcli = 'modemmanager', curl = 'curl', ubus = 'ubus' } },
        'cellular-mode-dependencies')
    self.original = self.runtime.persistent_existed
        and util.decode(util.read(self.box.artifacts .. '/original-persistent.json')) or self.runtime.original
    local ui = assert(self.original.ui and self.original.ui.data, 'Local UI config is required')
    assert(ui.enabled ~= false and (ui.http or {}).enabled ~= false, 'Local UI HTTP must be enabled')
    self.ui_url = self.box.args.ui_url or 'http://127.0.0.1:' .. tostring((ui.http or {}).port or 80)
    self.original_pids = self:service_pids()
    local names = {}
    local inventory = self.modems:inventory()
    for _, imei in ipairs(util.keys(inventory)) do
        local info = inventory[imei]
        local cfg = M.effective_config(self.original, info)
        if (not self.box.args.imei or self.box.args.imei == imei) and cfg.enabled ~= false then
            assert(info.state ~= 'failed' and info.state ~= 'locked', 'Modem is not usable: ' .. imei)
            local current, supported, raw = self:read_modes(imei)
            local valid, invalid = M.choose_pairs(current, supported, self.box.args.requested)
            local name = cfg.name or imei
            assert(not names[name], 'Selected modems share a GSM name; select one with --imei')
            names[name] = true
            self.targets[imei] = { info = info, name = name, original = current, valid = valid, invalid = invalid }
            util.write(self.box.artifacts .. '/original-' .. imei .. '-mmcli.json', util.encode(raw))
            print(('Target %s …%s: %s -> %s; unsupported %s'):format(
                name, imei:sub(-4), modes.key(current), modes.key(valid), modes.key(invalid)))
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

function Runner:wait_modes(field, label)
    return self:wait_for(label .. ' mmcli modes', function()
        local results = {}
        for _, imei in ipairs(util.keys(self.targets)) do
            local actual, _, raw = self:read_modes(imei)
            local target = self.targets[imei]
            util.write(self.box.artifacts .. '/' .. label .. '-' .. imei .. '-mmcli.json', util.encode(raw))
            assert(modes.equal(actual, target[field]), imei .. ': expected ' .. modes.key(target[field])
                .. ', got ' .. modes.key(actual))
            results[imei] = actual
        end
        return results
    end)
end

function Runner:wait_logs(field, what, label)
    -- Boot capture freezes when full; later application/warning records can only
    -- be in the recent ring. Keep matches as either bounded buffer advances.
    local records = {}
    return self:wait_for(label .. ' local UI logs', function()
        local errors = {}
        for _, source in ipairs({
            { path = '/api/logs', suffix = '-ui-logs.json' },
            { path = '/api/logs?boot=true', suffix = '-ui-boot-logs.json' },
        }) do
            local ok, err = pcall(function()
                local result = self.box.ssh:run('curl -fsS --max-time 10 --url '
                    .. quote(self.ui_url .. source.path), { timeout = 15, check = false })
                util.write(self.box.artifacts .. '/' .. label .. source.suffix, result.stdout)
                assert(result.code == 0, result.stderr)
                local reply = util.decode(result.stdout)
                assert(reply.ok == true, 'Local UI monitor query failed')
                for imei, target in pairs(self.targets) do
                    records[imei] = records[imei] or M.find_record(reply, target, target[field], what)
                end
            end)
            if not ok then errors[#errors + 1] = source.path .. ': ' .. tostring(err) end
        end
        for _, imei in ipairs(util.keys(self.targets)) do
            assert(records[imei], 'Missing ' .. what .. ' warning/application record for ' .. imei
                .. (#errors > 0 and '; ' .. table.concat(errors, '; ') or ''))
        end
        return records
    end)
end

function Runner:phase(label, field, revision, unchanged)
    local config = M.phase_config(self.original, self.targets, field, revision)
    local archive = self.runtime:build(label, config)
    self.box:phase(label, function()
        local previous = self:service_pids()
        self.runtime:deploy(archive)
        self.runtime:write_config(config)
        self.runtime:service('restart')
        self:wait_for(label .. ' fresh service process', function()
            local pids = self:service_pids()
            for pid in pairs(pids) do if previous[pid] then return false end end
            return next(pids) ~= nil
        end)
        local expected = unchanged and 'valid' or field
        local records = self:wait_logs(field,
            unchanged and 'cellular_modes_unsupported' or 'cellular_modes_applied', label)
        local actual = self:wait_modes(expected, label)
        self.summary[#self.summary + 1] = { phase = label, requested = field, actual = actual, records = records }
        util.write(self.box.artifacts .. '/results.json', util.encode(self.summary))
        print('[' .. label .. '] PASS: mmcli modes and local UI records verified')
    end)
end

function Runner:rollback()
    local errors = {}
    local function recover(body)
        local ok, err = pcall(body)
        if not ok then errors[#errors + 1] = tostring(err) end
    end
    recover(function() self.runtime:restore_runtime() end)
    if next(self.original_pids) then recover(function() self.runtime:service('restart') end) end
    for _, imei in ipairs(util.keys(self.targets)) do
        local original = self.targets[imei].original
        recover(function()
            self:wait_for('Restore modem ' .. imei, function()
                local info = self.modems:inventory()[imei]
                if not info then return false end
                self.box.ssh:run('mmcli -m ' .. quote(info.id) .. ' --set-allowed-modes='
                    .. quote(table.concat(original.allowed, '|'))
                    .. ' --set-preferred-mode=' .. quote(original.preferred), { timeout = 45 })
                local actual = self:read_modes(imei)
                return modes.equal(actual, original)
            end)
        end)
    end
    recover(function() self:wait_modes('original', 'rollback') end)
    assert(#errors == 0, table.concat(errors, '\n'))
end

function Runner:run()
    return self.box:run(function()
        self:prepare()
        self:phase('01-valid', 'valid', 1)
        self:phase('02-unsupported', 'invalid', 2, true)
        self:phase('03-original', 'original', 3)
    end, {
        diagnostics = function()
            local commands = self.runtime:diagnostic_commands()
            for name, command in pairs(self.modems:diagnostic_commands()) do commands[name] = command end
            self.box.logs:diagnostics('failure', commands)
        end,
        rollback = function() if self.runtime.changed then self:rollback() end end,
        success_message = 'PASS: valid modes, unsupported warning, and original modes verified',
    })
end

return M
