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

---@class PdpBoxArgs: OnboxArgs
---@field first string
---@field second string
---@field keep_final_config boolean

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
        defaults = { first = 'IP', second = 'IPV4V6', keep_final_config = false },
        values = { ['--first'] = 'first', ['--second'] = 'second' },
        flags = { ['--keep-final-config'] = 'keep_final_config' },
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
    return M.from_session(support.open(args, { 'gsm', 'pdp', 'devicecode', 'error', 'failed' }))
end

---@return nil
function Runner:prepare()
    self.runtime:prepare()
    self.runtime:ensure_dependencies({ commands = { mmcli = 'modemmanager' } }, 'modem-dependencies')
    for imei, info in pairs(self.modems:inventory()) do
        local cfg = M.effective_config(self.runtime.original, info)
        if cfg.enabled ~= false and cfg.autoconnect then
            assert(info.plugin:lower():find('quectel', 1, true), 'Unsupported modem: ' .. info.model)
            assert(info.state ~= 'locked' and info.state ~= 'failed',
                ('Modem …%s is %s: %s'):format(imei:sub(-4), info.state, info.failed_reason or ''))
            info.name = cfg.name or imei:sub(-4)
            self.targets[imei] = info
        end
    end
    assert(next(self.targets), 'No configured Quectel modems with autoconnect enabled')
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
    local current, results = self.modems:wait(self.targets, 'connected'), {}
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
    self.summary[#self.summary + 1] = { phase = label, modems = results }
    util.write(self.box.artifacts .. '/results.json', util.encode(self.summary))
end

---@param label string
---@param config table
---@param archive string?
---@return nil
function Runner:phase(label, config, archive)
    print('[' .. label .. '] Deploying and resetting modems for a clean-boot test')
    self.box:phase(label, function()
        self.runtime:deploy(archive)
        self.runtime:write_config(config)
        self.modems:clean_boot(self.targets)
        self.runtime:service('restart')
        self:inspect(label, config)
    end)
end

---@return nil
function Runner:rollback()
    print('Rolling back the original runtime and configuration')
    self.modems:resume_manager()
    self.runtime:restore_runtime()
    local ok, err = pcall(function() self.modems:clean_boot(self.targets) end)
    self.runtime:service('restart')
    if not ok then error(err, 0) end
end

---@return integer exit_code
function Runner:run()
    ---@type PdpBoxArgs
    local args = self.box.args
    return self.box:run(function()
        self:prepare()
        for _, phase in ipairs({ { '01-ip', args.first }, { '02-alternate', args.second } }) do
            local config = M.phase_config(self.runtime.original, phase[2])
            self:phase(phase[1], config, self.runtime:build(phase[1], config))
        end
        if not args.keep_final_config then
            self:phase('03-restored-config', self.runtime.original)
            self.runtime:restore_persistent()
        end
    end, {
        diagnostics = function()
            local commands = self.runtime:diagnostic_commands()
            for name, command in pairs(self.modems:diagnostic_commands()) do commands[name] = command end
            self.box.logs:diagnostics('failure', commands)
        end,
        rollback = function()
            if self.runtime.changed then self:rollback() end
        end,
        success_message = 'PASS: all phases verified',
    })
end

return M
