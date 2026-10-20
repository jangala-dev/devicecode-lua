local op = require 'fibers.op'
local sleep = require 'fibers.sleep'
local pulse = require 'fibers.pulse'
local channel = require 'fibers.channel'
local safe = require 'coxpcall'
local runfibers = require 'tests.support.run_fibers'
local at = require 'services.hal.backends.modem.at'
local linux_mm = require 'services.hal.backends.modem.providers.linux_mm.impl'
local quectel = require 'services.hal.backends.modem.models.quectel'
local provider = require 'services.hal.backends.modem.provider'
local driver = require 'services.hal.drivers.modem'
local args = require 'services.hal.types.capability_args'
local caps = require 'services.hal.types.capabilities'
local cache = require 'shared.cache'

local tests = {}
local function eq(a, b) assert(a == b, 'expected ' .. tostring(b) .. ', got ' .. tostring(a)) end
---@return ModemBackend
local function backend()
    local b = setmetatable({ identity = { at_port = '/dev/test-at' } }, linux_mm._test.ModemBackend)
    quectel.add_model_funcs(b, { model = 'unknown-quectel' })
    return b
end
local function with_at(responder, body, timeout)
    local saved = at.send_op
    local commands = {}
    at.send_op = function(port, command)
        eq(port, '/dev/test-at')
        commands[#commands + 1] = command
        return responder(command, #commands)
    end
    local ok, err = safe.pcall(function()
        runfibers.run(function() body(backend(), commands) end, { timeout = timeout or 2 })
    end)
    at.send_op = saved
    assert(ok, err)
end
local function context_line(cid, pdp_type)
    return ('+CGDCONT: %d,"%s","","",0,0'):format(cid, pdp_type)
end

---@param plugin string
---@param model string
---@param revision string?
---@return ModemBackend backend
---@return ModemIdentityInfo identity_info
local function construct_backend(plugin, model, revision)
    local info = { plugin = plugin, model = model, revision = revision or '' }
    local b = setmetatable({
        identity = { at_port = '/dev/test-at' },
        base = 'linux_mm',
        read_identity = function() return info, '' end,
        _read_firmware = function() return '01.003', '' end,
    }, { __index = function(_, key)
        -- Stub mode operations; retain the real provider's PDP defaults.
        return linux_mm._test.ModemBackend[key] or function() return true, '' end
    end })
    local module_name = 'services.hal.backends.modem.providers.linux_mm.init'
    local saved = package.loaded[module_name]
    package.loaded[module_name] = {
        is_supported = function() return true end,
        backend = { new = function() return b end },
    }
    local ok, result = safe.pcall(function() return provider.new('test-modem') end)
    package.loaded[module_name] = saved
    assert(ok, result)
    return result, info
end

---@return nil
function tests.test_pdp_constructor_installs_quectel_operations_for_tested_models()
    for _, model in ipairs({
        { name = 'UNKNOWN', revision = 'EG25GGBR07A08M2G', normalized = 'eg25' },
        { name = 'em12-g', normalized = 'em12' },
        { name = 'em06-e', normalized = 'em06' },
        { name = 'rm520n-gl', normalized = 'rm520n' },
    }) do
        local b, info = construct_backend('quectel', model.name, model.revision)
        eq(info.model, model.normalized)
        for _, method in ipairs({ 'read_pdp_contexts', 'read_active_pdp_contexts', 'read_pdp_info', 'set_pdn_type' }) do
            assert(b[method] ~= linux_mm._test.ModemBackend[method])
        end
    end
end

---@return nil
function tests.test_pdp_constructor_installs_quectel_operations_for_unlisted_models()
    local b, info = construct_backend('QuEcTeL', 'new-model')
    eq(info.model, 'new-model')
    eq(b.connect, linux_mm._test.ModemBackend.connect)
    for _, method in ipairs({ 'read_pdp_contexts', 'read_active_pdp_contexts', 'read_pdp_info', 'set_pdn_type' }) do
        assert(b[method] ~= linux_mm._test.ModemBackend[method])
    end
end

---@return nil
function tests.test_pdp_constructor_leaves_other_manufacturers_unsupported_without_at_commands()
    for _, plugin in ipairs({ 'fibocom', 'generic' }) do
        local b = construct_backend(plugin, 'other-model')
        for _, method in ipairs({ 'read_pdp_contexts', 'read_active_pdp_contexts', 'read_pdp_info' }) do
            local value, err = b[method](b)
            eq(value, nil)
            eq(err, 'pdp_not_supported')
        end
        local ok, err = b:set_pdn_type(1, 'IP')
        eq(ok, false)
        eq(err, 'pdp_not_supported')
    end
end

function tests.test_pdp_parsers_handle_whitespace_empty_fields_and_optional_fields()
    local contexts, err = quectel._test.parse_pdp_contexts({
        'AT+CGDCONT?', '+CGDCONT: 3, "IPV4V6", "apn,example", "", 0,0',
        '+CGDCONT: 1,"IP","","10.0.0.1"',
    })
    eq(err, '')
    eq(#contexts, 2)
    eq(contexts[1].cid, 3)
    eq(contexts[1].apn, 'apn,example')
    eq(contexts[1].pdp_addr, '')
    eq(contexts[2].pdp_type, 'IP')
    local activations = assert(quectel._test.parse_pdp_activations({ '+CGACT: 3,1', '+CGACT: 1, 0' }))
    eq(activations[1].active, true)
    eq(activations[2].active, false)
    eq(#assert(quectel._test.parse_pdp_contexts({})), 0)
    eq(#assert(quectel._test.parse_pdp_activations({})), 0)
end

function tests.test_pdp_parsers_reject_malformed_or_duplicate_records()
    for _, line in ipairs({ '+CGDCONT: bad', '+CGDCONT: 0,"IP","",""',
        '+CGDCONT: 1,"IP","",""junk', '+CGDCONT: 1,"IP",""' }) do
        local result, err = quectel._test.parse_pdp_contexts({ line })
        eq(result, nil)
        assert(err:find('malformed_pdp_context', 1, true))
    end
    eq(quectel._test.parse_pdp_contexts({ context_line(1, 'IP'), context_line(1, 'IP') }), nil)
    for _, line in ipairs({ '+CGACT: 1,2', '+CGACT: 0,1', '+CGACT: bad' }) do
        eq(quectel._test.parse_pdp_activations({ line }), nil)
    end
    eq(quectel._test.parse_pdp_activations({ '+CGACT: 1,0', '+CGACT: 1,1' }), nil)
end

function tests.test_pdp_composite_joins_by_cid_and_defaults_missing_activation_to_false()
    with_at(function(command)
        if command == 'AT+CGDCONT?' then
            return op.always({ context_line(3, 'IPV6'), context_line(1, 'IP'), context_line(2, 'IPV4V6') })
        end
        eq(command, 'AT+CGACT?')
        return op.always({ '+CGACT: 1,0', '+CGACT: 3,1' })
    end, function(b)
        local info, err = b:read_pdp_info()
        eq(err, '')
        eq(info.pdp_contexts[1].active, true)
        eq(info.pdp_contexts[2].active, false)
        eq(info.pdp_contexts[3].active, false)
    end)
end

function tests.test_pdp_composite_propagates_read_errors()
    with_at(function(command)
        if command == 'AT+CGDCONT?' then return op.always({ context_line(1, 'IP') }) end
        return op.always(nil, 'error')
    end, function(b)
        local info, err = b:read_pdp_info()
        eq(info, nil)
        eq(err, 'error')
    end)
end

function tests.test_pdp_type_options_reject_invalid_cids_and_command_injection()
    for _, cid in ipairs({ 0, -1, 1.5, math.huge, 0/0, '1' }) do
        eq(args.new.ModemSetPdnTypeOpts(cid, 'IP'), nil)
    end
    for _, pdp_type in ipairs({ '', 'IP"', 'IP\rAT', 'IP,IP', 'IP V6' }) do
        eq(args.new.ModemSetPdnTypeOpts(1, pdp_type), nil)
    end
    local opts = assert(args.new.ModemSetPdnTypeOpts(3, 'ipv4v6'))
    eq(opts.pdp_type, 'IPV4V6')
    with_at(function() error('invalid options reached AT') end, function(b)
        eq(b:set_pdn_type(0, 'IP'), false)
        eq(b:set_pdn_type(1, 'IP"'), false)
    end)
end

function tests.test_pdp_setter_verifies_ok_response_and_clears_apn()
    with_at(function(command, n)
        if n == 1 then
            eq(command, 'AT+CGDCONT=3,"IP",""')
            return op.always({})
        end
        eq(command, 'AT+CGDCONT?')
        return op.always({ context_line(1, 'IPV6'), context_line(3, 'IP') })
    end, function(b, commands)
        local ok, err = b:set_pdn_type(3, 'ip')
        eq(ok, true)
        eq(err, '')
        eq(#commands, 2)
    end)
end

function tests.test_pdp_setter_verifies_silent_timeout()
    with_at(function(_, n)
        if n == 1 then return sleep.sleep_op(math.huge) end
        return op.always({ context_line(1, 'IP') })
    end, function(b, commands)
        local ok, err = b:set_pdn_type(1, 'IP')
        eq(ok, true)
        eq(err, '')
        eq(#commands, 2)
    end, 5)
end

function tests.test_pdp_setter_does_not_trust_ok_or_reboot_on_read_failure()
    for _, response in ipairs({ { context_line(1, 'IPV6') }, {}, false }) do
        with_at(function(_, n)
            if n == 1 then return op.always({}) end
            if response == false then return op.always(nil, 'read failed') end
            return op.always(response)
        end, function(b)
            local ok, err = b:set_pdn_type(1, 'IP')
            eq(ok, false)
            assert(err ~= '')
        end)
    end
    with_at(function() return op.always({}, 'error') end, function(b, commands)
        local ok, err = b:set_pdn_type(1, 'IP')
        eq(ok, false)
        eq(err, 'error')
        eq(#commands, 1)
    end)
end

local function modem(b, state)
    return setmetatable({ backend = b, card_state = state, cache = cache.new() }, driver._test.Modem)
end

function tests.test_pdp_driver_reads_are_fresh_and_do_not_enter_cache()
    local calls = 0
    local m = modem({ read_pdp_info = function()
        calls = calls + 1
        return { pdp_contexts = { { cid = calls, active = true } } }, ''
    end }, 'disabled')
    m.cache:set('pdp', { pdp_contexts = { { cid = 99 } } })
    local opts = assert(args.new.ModemGetOpts('pdp_contexts'))
    local ok, contexts = m:get(opts)
    eq(ok, true)
    eq(contexts[1].cid, 1)
    ok, contexts = m:get(opts)
    eq(ok, true)
    eq(contexts[1].cid, 2)
    eq(m.cache:get('pdp').pdp_contexts[1].cid, 99)
end

function tests.test_pdp_driver_guards_get_and_set_before_backend_calls()
    local m = modem({
        read_pdp_info = function() error('unexpected PDP read') end,
        set_pdn_type = function() error('unexpected PDP write') end,
    })
    for _, state in ipairs({ false, 'enabling', 'connecting', 'connected', 'failed' }) do
        m.card_state = state or nil
        local ok, err = m:get(assert(args.new.ModemGetOpts('pdp_contexts')))
        eq(ok, false)
        assert(err:find('modem_invalid_pdp_state:', 1, true))
        ok, err = m:set_pdn_type(assert(args.new.ModemSetPdnTypeOpts(1, 'IP')))
        eq(ok, false)
        assert(err:find('modem_invalid_pdp_state:', 1, true))
    end
    eq(m:set_pdn_type({ cid = 1, pdp_type = 'IP' }), false)
end

function tests.test_pdp_driver_dispatches_set_and_restart_and_advertises_capability()
    local m = modem({
        set_pdn_type = function(_, cid, pdp_type) eq(cid, 2); eq(pdp_type, 'IP'); return true, '' end,
        reset = function() return true, '' end,
    }, 'registered')
    for _, state in ipairs({ 'disabled', 'registered' }) do
        m.card_state = state
        eq(m:set_pdn_type(assert(args.new.ModemSetPdnTypeOpts(2, 'IP'))), true)
    end
    for _, state in ipairs({ 'registered', 'connected', 'disabled', 'connecting', 'failed' }) do
        m.card_state = state
        eq(m:restart(), true)
    end
    local cap = assert(caps.new.ModemCapability('test', channel.new()))
    eq(cap.offerings.set_pdn_type, true)
    eq(cap.offerings.restart, true)
end

function tests.test_pdp_driver_emits_existing_groups_without_fetching_pdp()
    runfibers.run(function()
        local fetched, emitted, count = {}, {}, 0
        local m = modem({})
        m.log = { debug = function() end }
        m.state_pulse = pulse.new()
        m._get_group = function(_, group)
            assert(group ~= 'pdp', 'emitter fetched request-only PDP group')
            fetched[group] = true
            count = count + 1
            if count == 6 then m.state_pulse:close() end
            return { imei = 'test', device = 'test-device', sim = 'test-sim',
                operator = 'test-operator', values = { lte = { rssi = -80 } }, rx_bytes = 123 }, ''
        end
        m._emit_meta = function(_, field, value) emitted[field] = value; return true end
        m.state_pulse:signal()
        m:emitter()
        eq(count, 6)
        assert(fetched.identity and fetched.ports and fetched.sim)
        assert(fetched.network and fetched.signal and fetched.traffic)
        eq(emitted.imei, 'test')
        eq(emitted.signal.lte.rssi, -80)
        eq(emitted.rx_bytes, 123)
        eq(emitted.pdp_contexts, nil)
    end)
end

function tests.test_pdp_driver_updates_guard_before_publishing_state()
    runfibers.run(function(scope)
        local events = channel.new(2)
        local done = channel.new(1)
        events:put({ to = 'registered', from = 'enabled' })
        events:put({ to = 'connected', from = 'registered' })
        local m = modem({
            monitor_state_op = function() return events:get_op():wrap(function(event) return event, '' end) end,
            wait_for_sim_present_op = function() return sleep.sleep_op(math.huge) end,
        })
        m.log = { debug = function() end, error = function() end }
        m.state_pulse = pulse.new()
        m.sim_state_ch = channel.new()
        m._emit_state = function(_, key, event)
            eq(key, 'card')
            eq(m.card_state, event.to)
            if event.to == 'registered' then eq(m:_require_pdp_state(), true) end
            if event.to == 'connected' then
                eq(m:_require_pdp_state(), false)
                done:put(true)
            end
        end
        assert(scope:spawn(function() m:modem_lifecycle_monitor() end))
        assert(done:get())
    end)
end

return tests
