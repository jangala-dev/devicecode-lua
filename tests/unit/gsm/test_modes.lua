local modes = require 'services.gsm.modes'
local values = require 'services.hal.types.modem_modes'
local gsm = require 'services.gsm'
local op = require 'fibers.op'
local pulse = require 'fibers.pulse'
local channel = require 'fibers.channel'
local sleep = require 'fibers.sleep'
local runfibers = require 'tests.support.run_fibers'
local T = {}

local function pair(preferred, allowed)
    local result = assert(values.normalize(preferred, allowed))
    return result
end

local function selected(request, supported, expected)
    local actual = assert(modes.select(request, supported))
    assert(values.equal(actual, expected), values.key(actual) .. ' ~= ' .. values.key(expected))
end

function T.exact_match_ignores_order_and_duplicates()
    local wanted = { preferred = '4g', allowed = { '4g', '3g', '4g' } }
    local exact = pair('4g', { '3g', '4g' })
    selected(wanted, { pair('4g', { '2g', '3g', '4g' }), exact }, exact)
end

function T.same_preference_with_different_allowed_generations_is_rejected()
    local narrow = pair('4g', { '4g' })
    local broad = pair('4g', { '2g', '3g', '4g' })
    assert(modes.select(pair('4g', { '3g', '4g' }), { broad, narrow }) == nil)
    assert(modes.select(pair('4g', { '3g', '4g' }), { narrow, broad }) == nil)
    assert(modes.select(pair('4g', { '4g', '5g' }), { broad }) == nil)
end

function T.same_allowed_generations_with_different_preference_is_rejected()
    local allowed = { '3g', '4g' }
    assert(modes.select(pair('4g', allowed), { pair('3g', allowed), pair('none', allowed) }) == nil)
    assert(modes.select(pair('none', allowed), { pair('4g', allowed) }) == nil)
    assert(modes.select(pair('4g', { '3g' }), { pair('4g', allowed) }) == nil)
end

function T.single_generation_without_explicit_preference_requires_an_exact_match()
    local request = pair('5g', { '4g', '5g' })
    local automatic = pair('none', { '4g', '5g' })
    local single = pair('none', { '5g' })
    assert(modes.select(request, { automatic, single }) == nil)
    assert(modes.select(pair('5g', { '5g' }), { single }) == nil)
    assert(modes.select(request, { automatic, pair('4g', { '4g', '5g' }) }) == nil)
    selected(pair('none', { '5g' }), { automatic, single }, single)
end

function T.config_inherits_fields_but_replaces_allowed_list_without_mutation()
    local cfg = { modems = {
        default = { cellular_modes = pair('4g', { '2g', '3g', '4g' }) },
        known = { { imei = 'one', cellular_modes = { allowed = { '4g' } } },
            { imei = 'two', cellular_modes = { preferred = '3g' } } },
    } }
    local one = gsm._test.get_modem_config(cfg, 'one', '')
    assert(one.cellular_modes.preferred == '4g' and #one.cellular_modes.allowed == 1)
    one.cellular_modes.allowed[1] = '5g'
    local two = gsm._test.get_modem_config(cfg, 'two', '')
    assert(two.cellular_modes.preferred == '3g' and #two.cellular_modes.allowed == 3)
    local unknown = gsm._test.get_modem_config(cfg, 'other', '')
    unknown.cellular_modes.allowed[1] = '5g'
    assert(cfg.modems.default.cellular_modes.allowed[1] == '2g')
    assert(cfg.modems.known[1].cellular_modes.allowed[1] == '4g')
end

local function modem_fixture(request, current, supported)
    local state = { current = current, supported = supported, writes = 0, reads = 0, logs = {}, calls = {} }
    local modem = setmetatable({ name = 'primary', cfg = { cellular_modes = request },
        config_pulse = pulse.new(),
        svc = { obs_log = function(_, _, payload)
            if type(payload) == 'table' then state.logs[payload.what] = payload end
        end },
        cap = { call_control_op = function(_, method, opts)
            state.calls[#state.calls + 1] = method == 'get' and opts.field or method
            if method == 'set_signal_update_freq' then return op.always({ ok = true }) end
            if method == 'get' then
                state.reads = state.reads + 1
                if state.read_failure then return op.always({ ok = false, reason = 'read failed' }) end
                if opts.field == 'modem_state' and state.refresh_failure then
                    return op.always({ ok = false, reason = 'state refresh failed' })
                end
                local result = ({ supported_modes = state.supported, current_modes = state.current,
                    modem_state = state.modem_state or 'registered' })[opts.field]
                return op.always({ ok = true, reason = result })
            end
            assert(method == 'set_modes')
            state.writes = state.writes + 1
            if state.write_failure then return op.always({ ok = false, reason = 'write failed' }) end
            if not state.mismatch then state.current = pair(opts.preferred, opts.allowed) end
            return op.always({ ok = true })
        end },
    }, gsm._test.GsmModem)
    return modem, state
end

function T.reconcile_applies_exact_match_verifies_and_does_not_repeat_writes()
    runfibers.run(function()
        local target = pair('4g', { '4g' })
        local modem, state = modem_fixture(target, pair('none', { '3g' }), { target })
        local settled, wrote = modem:_reconcile_modes()
        assert(settled and wrote and state.writes == 1)
        assert(state.logs.cellular_modes_applied)
        settled, wrote = modem:_reconcile_modes()
        assert(settled and not wrote and state.writes == 1)
        modem:apply_config({})
        local reads = state.reads
        assert(modem:_reconcile_modes())
        assert(state.reads == reads and state.writes == 1)
    end)
end

function T.invalid_and_unsupported_settings_leave_modes_unchanged()
    runfibers.run(function()
        for _, request in ipairs({ false, {}, { preferred = 'lte', allowed = { '4g' } },
            { preferred = '4g', allowed = {} }, pair('5g', { '5g' }),
            pair('4g', { '3g', '4g' }), pair('none', { '3g', '4g' }), pair('4g', { '3g' }) }) do
            local current = pair('none', { '3g', '4g' })
            local modem, state = modem_fixture(request, current,
                { pair('4g', { '4g' }), pair('none', { '4g' }), pair('none', { '5g' }) })
            local settled, wrote = modem:_reconcile_modes()
            assert(settled and not wrote and state.writes == 0 and state.current == current)
            assert(state.logs.cellular_modes_invalid or state.logs.cellular_modes_unsupported)
        end
    end)
end

function T.read_write_and_verification_failures_remain_pending()
    runfibers.run(function()
        local target = pair('4g', { '3g', '4g' })
        for _, failure in ipairs({ 'read_failure', 'write_failure', 'mismatch' }) do
            local modem, state = modem_fixture(target, pair('none', { '3g', '4g' }), { target })
            state[failure] = true
            assert(not modem:_reconcile_modes())
            state[failure] = false
            assert(modem:_reconcile_modes())
            assert(values.equal(state.current, target))
        end
    end)
end

local function loop_fixture(scope, autoconnect)
    local target = pair('4g', { '4g' })
    local modem, state = modem_fixture(target, pair('none', { '3g', '4g' }), { target })
    modem.cfg.autoconnect = autoconnect
    local events = channel.new(8)
    local connections = channel.new(8)
    modem.cap.get_state_sub = function(_, name)
        return {
            recv_op = function()
                if name == 'card' then return events:get_op() end
                return sleep.sleep_op(math.huge)
            end,
            unsubscribe = function() end,
        }
    end
    modem._emit_metric = function() end
    modem._publish_uplink_state = function() end
    modem._apn_connect = function()
        connections:put('connect')
        return nil, '', nil
    end
    modem.domain = { retain = function() end }
    modem.svc.obs_event = function() end
    modem.svc.custom_apns = {}
    scope:spawn(function() modem:_autoconnect_loop() end)
    return modem, state, events, connections
end

function T.control_loop_applies_without_autoconnect_and_handles_live_changes_and_recovery()
    runfibers.run(function(scope)
        local modem, state, events = loop_fixture(scope, false)
        state.modem_state = 'connected'
        events:put({ payload = { to = 'connected' } })
        sleep.sleep(0.01)
        assert(state.writes == 1)
        state.supported[#state.supported + 1] = pair('5g', { '5g' })
        modem:apply_config({ autoconnect = false, cellular_modes = pair('5g', { '5g' }) })
        sleep.sleep(0.01)
        assert(state.writes == 2 and state.current.allowed[1] == '5g')
        modem:apply_config({ autoconnect = false, cellular_modes = pair('5g', { '4g', '5g' }) })
        -- Unsupported allowed pair leaves the current setting unchanged.
        sleep.sleep(0.01)
        assert(state.writes == 2 and state.current.preferred == '5g' and #state.current.allowed == 1)
        assert(state.logs.cellular_modes_unsupported)
        modem:apply_config({ autoconnect = false, cellular_modes = pair('5g', { '5g' }) })
        sleep.sleep(0.01)
        assert(state.writes == 2)
        state.current = pair('none', { '3g', '4g' })
        events:put({ payload = { to = 'failed' } })
        events:put({ payload = { to = 'disabled' } })
        sleep.sleep(0.01)
        assert(state.writes == 3)
    end)
end

function T.control_loop_refreshes_state_before_connecting_and_defers_locked_modem()
    runfibers.run(function(scope)
        local _, state, events, connections = loop_fixture(scope, true)
        events:put({ payload = { to = 'initializing' } })
        sleep.sleep(0.01)
        assert(state.writes == 0)
        events:put({ payload = { to = 'locked' } })
        sleep.sleep(0.01)
        assert(state.writes == 0)
        state.modem_state = 'searching'
        events:put({ payload = { to = 'registered' } })
        sleep.sleep(0.01)
        assert(state.writes == 1)
        assert(state.calls[#state.calls] == 'modem_state')
        events:put({ payload = { to = 'registered' } })
        assert(connections:get() == 'connect')
    end)
end

function T.failed_state_refresh_prevents_connecting_from_a_queued_state_event()
    runfibers.run(function(scope)
        local modem, state, events = loop_fixture(scope, true)
        local connects = 0
        modem._apn_connect = function() connects = connects + 1; return nil, '', nil end
        state.refresh_failure = true
        events:put({ payload = { to = 'registered' } })
        sleep.sleep(0.01)
        assert(state.writes == 1 and state.logs.cellular_modes_state_refresh_failed)
        events:put({ payload = { to = 'registered' } })
        sleep.sleep(0.01)
        assert(connects == 0)
    end)
end

function T.mode_retry_does_not_preempt_apn_backoff()
    runfibers.run(function(scope)
        local modem, state, events = loop_fixture(scope, true)
        local connects = 0
        modem._apn_connect = function()
            connects = connects + 1
            return nil, 'throttled', 360
        end
        state.write_failure = true
        events:put({ payload = { to = 'registered' } })
        sleep.sleep(0.01)
        assert(state.writes == 1 and connects == 1)
        state.write_failure = false
        sleep.sleep(20.05)
        assert(state.writes == 2, 'mode settings should retry without a state event')
        assert(connects == 1, 'mode retry must preserve the APN backoff')
        assert(state.current.preferred == '4g')
    end, { timeout = 22 })
end

function T.expired_apn_retry_waits_for_failed_mode_state_refresh_to_recover()
    runfibers.run(function(scope)
        local modem, state, events = loop_fixture(scope, true)
        local connects = 0
        modem._apn_connect = function()
            connects = connects + 1
            if connects == 1 then return nil, 'retry later', 30 end
            return nil, '', nil
        end
        state.write_failure = true
        events:put({ payload = { to = 'registered' } })
        sleep.sleep(0.01)
        assert(connects == 1)
        state.write_failure, state.refresh_failure = false, true
        sleep.sleep(30.05)
        assert(connects == 1 and state.logs.cellular_modes_state_refresh_failed)
        state.refresh_failure = false
        sleep.sleep(10.05)
        assert(connects == 2, 'APN retry should resume after fresh modem state is available')
    end, { timeout = 44 })
end

return T
