local op = require 'fibers.op'
local channel = require 'fibers.channel'
local pulse = require 'fibers.pulse'
local sleep = require 'fibers.sleep'
local safe = require 'coxpcall'
local runfibers = require 'tests.support.run_fibers'
local gsm = require 'services.gsm'
local apns = require 'services.gsm.apn'

local tests = {}
local function eq(a, b) assert(a == b, 'expected ' .. tostring(b) .. ', got ' .. tostring(a)) end
local function reply(ok, reason) return op.always({ ok = ok, reason = reason or '' }) end
local function context(cid, pdp_type, active) return { cid = cid, pdp_type = pdp_type, active = active } end
local function fixture(contexts, overrides)
    overrides = overrides or {}
    local calls, logs, subs = {}, {}, {}
    local values = { mcc = '234', mnc = '30', imsi = '234300000000000', gid1 = '',
        pdp_contexts = contexts or {}, modem_state = 'disabled' }
    local cap = {
        call_control_op = function(_, method, opts)
            calls[#calls + 1] = { method = method, opts = opts }
            if overrides.call then
                local response = overrides.call(method, opts, subs, values)
                if response then return response end
            end
            if method == 'get' then return reply(true, values[opts.field]) end
            if method == 'set_pdn_type' then return reply(true) end
            if method == 'restart' then
                for _, sub in ipairs(subs) do
                    if sub.field == 'card' and not sub.closed then
                        sub.queue:put({ payload = { from = 'initializing', to = 'disabled' } })
                    end
                end
                return reply(true)
            end
            if method == 'connect' then return reply(false, 'connection failed') end
            return reply(true)
        end,
        get_state_sub = function(_, field, opts)
            local queue = channel.new(opts and opts.queue_len or 16)
            if opts and opts.full == 'drop_oldest' then
                local put = queue.put
                queue.put = function(q, message)
                    if not q:put_op(message).try_fn() then
                        q:get_op().try_fn()
                        put(q, message)
                    end
                end
            end
            if field == 'card' then
                queue:put({ payload = { from = 'disabled', to = 'disabled' } })
            end
            local sub = {
                queue = queue, field = field,
                recv = function() return queue:get() end,
                recv_op = function() return queue:get_op() end,
                unsubscribe = function(self) self.closed = true end,
            }
            subs[#subs + 1] = sub
            return sub
        end,
    }
    local m = setmetatable({
        name = 'primary', cap = cap, cfg = {}, config_pulse = pulse.new(),
        svc = { obs_log = function(_, _, payload) logs[#logs + 1] = payload end },
    }, gsm._test.GsmModem)
    return m, calls, logs, values, subs
end
local function count(calls, method)
    local n = 0
    for _, call in ipairs(calls) do if call.method == method then n = n + 1 end end
    return n
end

local function config(default, known)
    return { schema = 'devicecode.config/gsm/1', modems = { default = default or {}, known = known } }
end

function tests.test_pdp_config_accepts_supported_types_and_rejects_other_values()
    for _, pdp_type in ipairs({ 'IP', 'IPV4V6', 'IPV6' }) do
        local _, err = gsm._test.normalize_config(config({ pdp_type = pdp_type }, { { pdp_type = pdp_type } }))
        eq(err, '')
    end
    for _, pdp_type in ipairs({ '', 'ip', 'PPP', false, 1, {} }) do
        local _, err = gsm._test.normalize_config(config({ pdp_type = pdp_type }))
        eq(err, 'config.modems.default.pdp_type must be IP, IPV4V6 or IPV6')
        _, err = gsm._test.normalize_config(config({}, { { pdp_type = pdp_type } }))
        eq(err, 'config.modems.known[1].pdp_type must be IP, IPV4V6 or IPV6')
    end
end

function tests.test_pdp_config_inherits_default_and_supports_imei_and_device_overrides()
    local input = config({ pdp_type = 'IPV4V6', signal_freq = 10 }, {
        { imei = 'inherited', name = 'primary' },
        { imei = 'override', pdp_type = 'IPV6' },
        { id_field = 'device', device = '/dev/modem', pdp_type = 'IP' },
    })
    local cfg, err = gsm._test.normalize_config(input)
    eq(err, '')
    local inherited, name = gsm._test.get_modem_config(cfg, 'inherited', '')
    eq(inherited.pdp_type, 'IPV4V6')
    eq(inherited.signal_freq, 10)
    eq(name, 'primary')
    eq(gsm._test.get_modem_config(cfg, 'override', '').pdp_type, 'IPV6')
    eq(gsm._test.get_modem_config(cfg, 'other', '/dev/modem').pdp_type, 'IP')
    eq(gsm._test.get_modem_config(cfg, 'unknown', '').pdp_type, 'IPV4V6')
    eq(input.modems.known[1].pdp_type, nil)
end

function tests.test_pdp_config_without_type_defaults_to_ip_without_mutating_input()
    local input = config({}, { { imei = 'known' } })
    local cfg, err = gsm._test.normalize_config(input)
    eq(err, '')
    eq(gsm._test.get_modem_config(cfg, 'unknown', '').pdp_type, 'IP')
    eq(gsm._test.get_modem_config(cfg, 'known', '').pdp_type, 'IP')
    eq(input.modems.default.pdp_type, nil)
    eq(input.modems.known[1].pdp_type, nil)
end

function tests.test_pdp_recovery_uses_configured_type_and_skips_matching_contexts()
    runfibers.run(function()
        for _, pdp_type in ipairs({ 'IP', 'IPV4V6', 'IPV6' }) do
            local m, calls = fixture({
                context(1, 'IP', true), context(2, 'IPV4V6', true), context(3, 'IPV6', true),
                context(4, 'OTHER', false),
            })
            local cfg = gsm._test.normalize_config(config({ pdp_type = pdp_type }))
            m:apply_config(gsm._test.get_modem_config(cfg, 'unknown', ''))
            eq(m:_configure_pdp(), true)
            eq(count(calls, 'set_pdn_type'), 2)
            eq(count(calls, 'restart'), 1)
            for _, call in ipairs(calls) do
                if call.method == 'set_pdn_type' then
                    eq(call.opts.pdp_type, pdp_type)
                    assert(({ 'IP', 'IPV4V6', 'IPV6' })[call.opts.cid] ~= pdp_type)
                end
            end
        end
    end)
end

function tests.test_pdp_recovery_does_not_restart_when_configured_type_already_matches()
    runfibers.run(function()
        for _, pdp_type in ipairs({ 'IP', 'IPV4V6', 'IPV6' }) do
            local m, calls = fixture({ context(1, pdp_type, true) })
            m.cfg.pdp_type = pdp_type
            local restarted, err = m:_configure_pdp()
            eq(restarted, false)
            eq(err, '')
            eq(count(calls, 'set_pdn_type'), 0)
            eq(count(calls, 'restart'), 0)
        end
    end)
end

function tests.test_pdp_configuration_changes_active_mismatched_contexts_and_restarts_once()
    runfibers.run(function()
        local m, calls, _, _, subs = fixture({
            context(3, 'IPV6', true), context(2, 'IP', true),
            context(1, 'IPV4V6', true), context(4, 'IPV6', false),
        })
        local restarted, err, state = m:_configure_pdp()
        eq(restarted, true)
        eq(err, '')
        eq(state, 'disabled')
        eq(count(calls, 'set_pdn_type'), 2)
        eq(calls[2].opts.cid, 1)
        eq(calls[3].opts.cid, 3)
        eq(calls[2].opts.pdp_type, 'IP')
        eq(count(calls, 'restart'), 1)
        eq(m.pdp_restart_needed, false)
        eq(m.pdp_restart_waiting, false)
        eq(subs[1].closed, true)
    end)
end

function tests.test_pdp_configuration_skips_empty_inactive_and_matching_contexts()
    runfibers.run(function()
        for _, contexts in ipairs({ {}, { context(1, 'IP', true), context(2, 'IPV6', false) } }) do
            local m, calls = fixture(contexts)
            local restarted, err = m:_configure_pdp()
            eq(restarted, false)
            eq(err, '')
            eq(count(calls, 'set_pdn_type'), 0)
            eq(count(calls, 'restart'), 0)
        end
    end)
end

function tests.test_pdp_recovery_read_and_verification_failures_do_not_restart()
    runfibers.run(function()
        for _, failure_method in ipairs({ 'get', 'set_pdn_type' }) do
            local m, calls = fixture({ context(1, 'IPV6', true) }, {
                call = function(method)
                    if method == failure_method then return reply(false, 'AT failed') end
                end,
            })
            eq(m:_configure_pdp(), false)
            eq(count(calls, 'restart'), 0)
        end
    end)
end

function tests.test_pdp_recovery_restarts_once_after_partial_verified_changes()
    runfibers.run(function()
        local m, calls = fixture({ context(1, 'IPV6', true), context(2, 'IPV6', true) }, {
            call = function(method, opts)
                if method == 'set_pdn_type' and opts.cid == 1 then return reply(false, 'verification failed') end
            end,
        })
        eq(m:_configure_pdp(), true)
        eq(count(calls, 'set_pdn_type'), 2)
        eq(count(calls, 'restart'), 1)
    end)
end

---@return nil
function tests.test_pdp_recovery_stops_commands_on_state_error_and_restarts_verified_changes()
    runfibers.run(function()
        local m, calls = fixture({
            context(1, 'IPV6', true), context(2, 'IPV6', true), context(3, 'IPV6', true),
        }, {
            call = function(method, opts)
                if method == 'set_pdn_type' and opts.cid == 2 then
                    return reply(false, 'modem_invalid_pdp_state:connecting')
                end
            end,
        })
        local restarted, err, state = m:_configure_pdp()
        eq(restarted, true)
        eq(err, '')
        eq(state, 'disabled')
        eq(m.pdp_restart_needed, false)
        eq(count(calls, 'set_pdn_type'), 2)
        eq(count(calls, 'restart'), 1)
    end)
end

---@return nil
function tests.test_pdp_recovery_restarts_after_verified_change_without_querying_modem_state()
    runfibers.run(function()
        for _, state in ipairs({ 'connected', 'disabled', 'connecting', 'failed', 'unknown' }) do
            local m, calls = fixture({ context(1, 'IPV6', true) }, {
                call = function(method, opts, _, values)
                    if method == 'set_pdn_type' then values.modem_state = state end
                    if method == 'get' and opts.field == 'modem_state' then
                        error('a verified change must not require a state check before restart')
                    end
                end,
            })
            eq(m:_configure_pdp(), true)
            eq(count(calls, 'set_pdn_type'), 1)
            eq(count(calls, 'restart'), 1)
        end
    end)
end

---@return nil
function tests.test_pdp_recovery_retries_required_restart_even_when_inspection_is_state_rejected()
    runfibers.run(function()
        local m, calls = fixture({}, {
            call = function(method, opts)
                if method == 'get' and opts.field == 'pdp_contexts' then
                    return reply(false, 'modem_invalid_pdp_state:connecting')
                end
            end,
        })
        m.pdp_restart_needed = true -- A prior cycle verified a change but its restart failed.
        eq(m:_configure_pdp(), true)
        eq(count(calls, 'set_pdn_type'), 0)
        eq(count(calls, 'restart'), 1)
        eq(m.pdp_restart_needed, false)
    end)
end

---@return nil
function tests.test_pdp_recovery_does_not_restart_after_state_rejection_without_verified_change()
    runfibers.run(function()
        local m, calls = fixture({ context(1, 'IPV6', true), context(2, 'IPV6', true) }, {
            call = function(method)
                if method == 'set_pdn_type' then return reply(false, 'modem_invalid_pdp_state:connecting') end
            end,
        })
        local restarted, err, state = m:_configure_pdp()
        eq(restarted, false)
        eq(err, 'modem_invalid_pdp_state:connecting')
        eq(state, 'connecting')
        eq(count(calls, 'set_pdn_type'), 1)
        eq(count(calls, 'restart'), 0)
    end)
end

function tests.test_pdp_recovery_late_connection_and_state_errors_do_not_restart()
    runfibers.run(function()
        for _, state in ipairs({ 'connected', 'enabling', 'connecting' }) do
            local m, calls = fixture({}, {
                call = function(method, opts)
                    if method == 'get' and opts.field == 'pdp_contexts' then
                        return reply(false, 'error getting field pdp_contexts: modem_invalid_pdp_state:' .. state)
                    end
                end,
            })
            local restarted, _, observed_state = m:_configure_pdp()
            eq(restarted, false)
            eq(observed_state, state)
            eq(count(calls, 'restart'), 0)
        end
    end)
end

function tests.test_pdp_restart_failure_preserves_verified_change_and_closes_subscription()
    runfibers.run(function()
        local m, _, _, _, subs = fixture({ context(1, 'IPV6', true) }, {
            call = function(method) if method == 'restart' then return reply(false, 'reset failed') end end,
        })
        local restarted, err = m:_configure_pdp()
        eq(restarted, false)
        eq(err, 'reset failed')
        eq(m.pdp_restart_needed, true)
        eq(subs[1].closed, true)
    end)
end

function tests.test_pdp_restart_unobserved_transition_restores_retry_state()
    runfibers.run(function()
        local m, _, _, _, subs = fixture({ context(1, 'IPV6', true) }, {
            call = function(method, _, active_subs)
                if method == 'restart' then
                    active_subs[1].recv_op = function() return op.always(nil) end
                    return reply(true)
                end
            end,
        })
        local restarted, err = m:_configure_pdp()
        eq(restarted, false)
        eq(err, 'state subscription interrupted')
        eq(m.pdp_restart_needed, true)
        eq(m.pdp_restart_waiting, false)
        eq(subs[1].closed, true)
    end)
end

function tests.test_pdp_restart_discards_stale_disabled_events()
    runfibers.run(function()
        local m = fixture({ context(1, 'IPV6', true) }, {
            call = function(method, _, subs)
                if method == 'restart' then
                    subs[1].queue:put({ payload = { from = 'disabled', to = 'disabled' } })
                    subs[1].queue:put({ payload = { from = 'initializing', to = 'disabled' } })
                    return reply(true)
                end
            end,
        })
        local restarted, err, state = m:_configure_pdp()
        eq(restarted, true)
        eq(err, '')
        eq(state, 'disabled')
        eq(m.pdp_restart_waiting, false)
    end)
end

local function with_rankings(body)
    local saved = apns.get_ranked_apns
    apns.get_ranked_apns = function()
        return { first = { apn = 'first' }, second = { apn = 'second' } },
            { { name = 'first', rank = 0 }, { name = 'second', rank = 1 } }
    end
    local ok, err = safe.pcall(function() runfibers.run(body) end)
    apns.get_ranked_apns = saved
    assert(ok, err)
end

function tests.test_pdp_configuration_does_not_run_after_apn_exhaustion()
    with_rankings(function()
        local m, calls = fixture({}, {
            call = function(method, _, subs)
                if method == 'connect' then
                    local queue = subs[#subs].queue
                    queue:put({ payload = { to = 'connecting' } })
                    queue:put({ payload = { to = 'registered' } })
                end
            end,
        })
        local _, err = m:_apn_connect()
        eq(err, 'no apn connected')
        eq(count(calls, 'connect'), 2)
        for _, call in ipairs(calls) do
            assert(not (call.method == 'get' and call.opts.field == 'pdp_contexts'))
        end
    end)
end

function tests.test_pdp_recovery_does_not_run_for_success_throttling_or_unsettled_state()
    with_rankings(function()
        for _, reason in ipairs({ 'success', 'pdn-ipv4-call-throttled', 'unsettled', 'late connected' }) do
            local m, calls = fixture({}, {
                call = function(method, _, subs)
                    if method == 'connect' then
                        if reason == 'success' then return reply(true) end
                        if reason == 'pdn-ipv4-call-throttled' then return reply(false, reason) end
                        local queue = subs[#subs].queue
                        queue:put({ payload = { to = 'connecting' } })
                        queue:put({ payload = { to = 'connected' } })
                    end
                end,
            })
            if reason == 'unsettled' then
                m.cap.get_state_sub = function()
                    return { recv = function() end, recv_op = function() return op.always(nil) end,
                        unsubscribe = function() end }
                end
                m.cap.call_control_op = function(_, method, opts)
                    calls[#calls + 1] = { method = method, opts = opts }
                    if method == 'get' then return reply(true, '234') end
                    return reply(false, 'connection failed')
                end
            end
            m:_apn_connect()
            eq(count(calls, 'connect'), 1)
            for _, call in ipairs(calls) do
                assert(not (call.method == 'get' and call.opts.field == 'pdp_contexts'))
            end
        end
    end)
end

function tests.test_pdp_recovery_skips_zero_attempts_and_missing_identifiers()
    with_rankings(function()
        for _, missing_identifier in ipairs({ false, true }) do
            local m, calls = fixture({}, {
                call = function(method, opts)
                    if missing_identifier and method == 'get' and opts.field == 'mcc' then
                        return reply(false, 'missing mcc')
                    end
                end,
            })
            m.cfg.apn_rank_cutoff = -1
            m:_apn_connect()
            eq(count(calls, 'connect'), 0)
            for _, call in ipairs(calls) do
                assert(not (call.method == 'get' and call.opts.field == 'pdp_contexts'))
            end
        end
    end)
end

---@param modem GsmModem
---@return nil
local function prepare_autoconnect(modem)
    modem.cfg.autoconnect = true
    modem.domain = { retain = function() end }
    modem._publish_uplink_state = function() end
    modem._emit_metric = function() end
    modem.svc.obs_event = function(_, event, payload)
        if event == 'connection_changed' and payload.connected then modem.config_pulse:close() end
    end
end

---@return nil
function tests.test_pdp_disabled_check_corrects_restarts_rereads_then_connects_successfully()
    with_rankings(function()
        for _, target in ipairs({ 'IP', 'IPV4V6', 'IPV6' }) do
            local wrong_type = target == 'IP' and 'IPV6' or 'IP'
            local contexts = { context(1, wrong_type, true) }
            local reads = 0
            local m, calls = fixture(contexts, {
                call = function(method, opts, subs)
                    if method == 'get' and opts.field == 'pdp_contexts' then reads = reads + 1 end
                    if method == 'set_pdn_type' then contexts[1].pdp_type = opts.pdp_type end
                    if method == 'enable' then
                        assert(reads >= 2, 'enable ran before post-restart PDP check')
                        eq(contexts[1].pdp_type, target)
                        subs[1].queue:put({ payload = { from = 'enabling', to = 'registered' } })
                    end
                    if method == 'connect' then
                        subs[1].queue:put({ payload = { from = 'connecting', to = 'connected' } })
                        return reply(true)
                    end
                end,
            })
            prepare_autoconnect(m)
            m.cfg.pdp_type = target
            m:_autoconnect_loop()
            assert(count(calls, 'set_pdn_type') == 1, 'expected one PDP write for ' .. target)
            assert(count(calls, 'restart') == 1, 'expected one restart for ' .. target)
            assert(count(calls, 'enable') == 1, 'expected one enable for ' .. target)
            assert(count(calls, 'connect') == 1, 'expected one connection for ' .. target)
            assert(reads >= 2, 'expected PDP read before and after restart')
        end
    end)
end

---@return nil
function tests.test_pdp_disabled_check_enables_without_restarting_when_already_correct()
    with_rankings(function()
        local m, calls = fixture({ context(1, 'IPV6', true) }, {
            call = function(method, _, subs)
                if method == 'enable' then
                    subs[1].queue:put({ payload = { from = 'enabling', to = 'registered' } })
                elseif method == 'connect' then
                    subs[1].queue:put({ payload = { from = 'connecting', to = 'connected' } })
                    return reply(true)
                end
            end,
        })
        prepare_autoconnect(m)
        m.cfg.pdp_type = 'IPV6'
        m:_autoconnect_loop()
        eq(calls[1].method, 'get')
        eq(calls[1].opts.field, 'pdp_contexts')
        eq(calls[2].method, 'enable')
        eq(count(calls, 'set_pdn_type'), 0)
        eq(count(calls, 'restart'), 0)
        eq(count(calls, 'connect'), 1)
    end)
end

---@return nil
function tests.test_pdp_disabled_check_prevents_enable_on_read_or_write_failure()
    runfibers.run(function()
        for _, fail_method in ipairs({ 'get', 'set_pdn_type' }) do
            local m, calls
            m, calls = fixture({ context(1, 'IPV6', true) }, {
                call = function(method)
                    if method == fail_method then
                        m.config_pulse:close()
                        return reply(false, 'AT failed')
                    end
                end,
            })
            prepare_autoconnect(m)
            m:_autoconnect_loop()
            eq(count(calls, 'enable'), 0)
            eq(count(calls, 'connect'), 0)
            eq(count(calls, 'restart'), 0)
        end
    end)
end

---@return nil
function tests.test_pdp_disabled_check_retries_read_write_and_restart_failures_before_enabling()
    local saved_sleep_op = sleep.sleep_op
    local ok, err = safe.pcall(function()
        with_rankings(function()
            for _, fail_method in ipairs({ 'get', 'set_pdn_type', 'restart' }) do
                local contexts = { context(1, 'IPV6', true) }
                local failed, retry_pending, retries = false, false, 0
                local m, calls = fixture(contexts, {
                    call = function(method, opts, subs)
                        if method == fail_method and not failed
                            and (method ~= 'get' or opts.field == 'pdp_contexts') then
                            failed, retry_pending = true, true
                            return reply(false, 'temporary failure')
                        end
                        if method == 'set_pdn_type' then contexts[1].pdp_type = opts.pdp_type end
                        if method == 'enable' then
                            eq(retries, 1)
                            eq(contexts[1].pdp_type, 'IP')
                            subs[1].queue:put({ payload = { from = 'enabling', to = 'registered' } })
                        elseif method == 'connect' then
                            subs[1].queue:put({ payload = { from = 'connecting', to = 'connected' } })
                            return reply(true)
                        end
                    end,
                })
                sleep.sleep_op = function(seconds)
                    if retry_pending and seconds == 20 then
                        retry_pending = false
                        retries = retries + 1
                        eq(count(calls, 'enable'), 0)
                        eq(count(calls, 'connect'), 0)
                        return op.always()
                    end
                    return saved_sleep_op(seconds)
                end
                prepare_autoconnect(m)
                m:_autoconnect_loop()
                eq(failed, true)
                eq(retries, 1)
                eq(count(calls, 'enable'), 1)
                eq(count(calls, 'connect'), 1)
                eq(count(calls, 'set_pdn_type'), fail_method == 'set_pdn_type' and 2 or 1)
                eq(count(calls, 'restart'), fail_method == 'restart' and 2 or 1)
            end
        end)
    end)
    sleep.sleep_op = saved_sleep_op
    assert(ok, err)
end

---@return nil
function tests.test_pdp_disabled_check_still_runs_when_autoconnect_is_off()
    runfibers.run(function()
        local contexts = { context(1, 'IPV6', true) }
        local reads = 0
        local m, calls
        m, calls = fixture(contexts, {
            call = function(method, opts)
                if method == 'get' and opts.field == 'pdp_contexts' then
                    reads = reads + 1
                    if reads == 2 then m.config_pulse:close() end
                elseif method == 'set_pdn_type' then
                    contexts[1].pdp_type = opts.pdp_type
                end
            end,
        })
        prepare_autoconnect(m)
        m.cfg.autoconnect = false
        m:_autoconnect_loop()
        assert(reads >= 2, 'expected PDP read before and after restart')
        eq(count(calls, 'set_pdn_type'), 1)
        eq(count(calls, 'restart'), 1)
        eq(count(calls, 'enable'), 0)
        eq(count(calls, 'connect'), 0)
    end)
end

---@return nil
function tests.test_pdp_disabled_check_allows_unsupported_modems_to_enable()
    with_rankings(function()
        local m, calls = fixture({}, {
            call = function(method, opts, subs)
                if method == 'get' and opts.field == 'pdp_contexts' then
                    return reply(false, 'error getting field pdp_contexts: pdp_not_supported')
                elseif method == 'enable' then
                    subs[1].queue:put({ payload = { from = 'enabling', to = 'registered' } })
                elseif method == 'connect' then
                    subs[1].queue:put({ payload = { from = 'connecting', to = 'connected' } })
                    return reply(true)
                end
            end,
        })
        prepare_autoconnect(m)
        m:_autoconnect_loop()
        eq(count(calls, 'enable'), 1)
        eq(count(calls, 'connect'), 1)
        eq(count(calls, 'restart'), 0)
    end)
end

return tests
