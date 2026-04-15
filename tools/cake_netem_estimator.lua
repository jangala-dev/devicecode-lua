-- cake_netem_estimator.lua  (Lua 5.1 / LuaJIT)
--
-- Synthetic harness:
--   root(veth_dc0) -> dcisp(veth_isp0 .. veth_isp1) -> dcpeer(veth_peer0)
--   CAKE on root veth, netem rate limiter on dcisp egress to peer.
--
-- Notes:
--   * This harness intentionally does NOT configure netem delay/jitter.
--   * The estimator does NOT read netem stats; it uses only:
--       - delivered bytes via /sys/class/net/<dev>/statistics/tx_bytes (root namespace)
--       - CAKE queue signals via `tc -j -s qdisc show dev <dev>`
--   * Optional: real ICMP ping probes (root->peer and/or peer->root) to observe RTT under load.
--
-- Usage:
--   luajit cake_netem_estimator.lua
--     [--duration 120] [--initial 120] [--min 5] [--max 500] [--margin 0.07]
--     [--probe-period 1.6] [--probe-dur 0.35] [--netem-step 8.0]
--     [--ping both|root|peer|off] [--ping-interval 0.2] [--ping-size 24] [--ping-log-period 1.0]
--
--   (also supports internal server mode; harness starts it via exec)
--
-- Assumptions:
--   * ip, tc, netns, cake, netem available
--   * fibres + fibres.io.socket + fibres.io.exec on package.path

local function add_path(prefix)
    package.path = prefix .. '?.lua;' .. prefix .. '?/init.lua;' .. package.path
end

add_path('../src/')
add_path('../vendor/lua-fibers/src/')
add_path('../vendor/lua-bus/src/')
add_path('./')

local fibers  = require 'fibers'
local sleep   = require 'fibers.sleep'
local runtime = require 'fibers.runtime'
local mailbox = require 'fibers.mailbox'
local socket  = require 'fibers.io.socket'
local exec    = require 'fibers.io.exec'

local perform = fibers.perform
local unpack_ = _G.unpack or rawget(table, 'unpack')

-------------------------------------------------------------------------------
-- CLI
-------------------------------------------------------------------------------

local function parse_args(argv)
    local out = {
        duration_s        = 120,
        initial_mbit      = 120,
        min_mbit          = 5,
        max_mbit          = 500,
        margin            = 0.07,

        probe_period_s    = 1.6,
        probe_dur_s       = 0.35,

        netem_step_s      = 8.0,

        -- Real ICMP ping probes:
        --   off  : disable
        --   root : root -> peer
        --   peer : peer -> root (run ping inside dcpeer)
        --   both : both directions (default)
        ping_mode         = 'both',
        ping_interval_s   = 0.2,
        ping_size_bytes   = 24,
        ping_log_period_s = 1.0,
    }
    local i = 1
    while i <= #argv do
        local a = argv[i]
        if a == '--duration' then
            out.duration_s = tonumber(argv[i + 1] or '') or out.duration_s; i = i + 1
        elseif a == '--initial' then
            out.initial_mbit = tonumber(argv[i + 1] or '') or out.initial_mbit; i = i + 1
        elseif a == '--min' then
            out.min_mbit = tonumber(argv[i + 1] or '') or out.min_mbit; i = i + 1
        elseif a == '--max' then
            out.max_mbit = tonumber(argv[i + 1] or '') or out.max_mbit; i = i + 1
        elseif a == '--margin' then
            out.margin = tonumber(argv[i + 1] or '') or out.margin; i = i + 1
        elseif a == '--probe-period' then
            out.probe_period_s = tonumber(argv[i + 1] or '') or out.probe_period_s; i = i + 1
        elseif a == '--probe-dur' then
            out.probe_dur_s = tonumber(argv[i + 1] or '') or out.probe_dur_s; i = i + 1
        elseif a == '--netem-step' then
            out.netem_step_s = tonumber(argv[i + 1] or '') or out.netem_step_s; i = i + 1
        elseif a == '--ping' then
            out.ping_mode = tostring(argv[i + 1] or out.ping_mode); i = i + 1
        elseif a == '--ping-interval' then
            out.ping_interval_s = tonumber(argv[i + 1] or '') or out.ping_interval_s; i = i + 1
        elseif a == '--ping-size' then
            out.ping_size_bytes = tonumber(argv[i + 1] or '') or out.ping_size_bytes; i = i + 1
        elseif a == '--ping-log-period' then
            out.ping_log_period_s = tonumber(argv[i + 1] or '') or out.ping_log_period_s; i = i + 1

            -- Legacy/ignored (previous versions accepted delay/jitter; now intentionally unused).
        elseif a == '--netem-delay' or a == '--netem-delay-ms' or a == '--delay' then
            i = i + 1
        elseif a == '--netem-jitter' or a == '--netem-jitter-ms' or a == '--jitter' then
            i = i + 1
        end
        i = i + 1
    end

    -- Normalise ping mode.
    local pm = tostring(out.ping_mode or 'both')
    if pm ~= 'both' and pm ~= 'root' and pm ~= 'peer' and pm ~= 'off' then
        pm = 'both'
    end
    out.ping_mode = pm

    if type(out.ping_interval_s) ~= 'number' or out.ping_interval_s <= 0 then out.ping_interval_s = 0.2 end
    if type(out.ping_size_bytes) ~= 'number' or out.ping_size_bytes < 0 then out.ping_size_bytes = 24 end
    if type(out.ping_log_period_s) ~= 'number' or out.ping_log_period_s <= 0 then out.ping_log_period_s = 1.0 end

    return out
end

local CFG = parse_args(arg or {})

-------------------------------------------------------------------------------
-- Utils
-------------------------------------------------------------------------------

local function printf(fmt, ...)
    io.stdout:write(string.format(fmt, ...) .. "\n")
    io.stdout:flush()
end

local function ts() return runtime.now() end

local function clamp(x, lo, hi)
    if x < lo then return lo end
    if x > hi then return hi end
    return x
end

local function mbit_to_bps(mbit) return (tonumber(mbit) or 0) * 1000 * 1000 end
local function bps_to_mbit(bps) return (tonumber(bps) or 0) / 1000 / 1000 end

-------------------------------------------------------------------------------
-- Exec helpers
-------------------------------------------------------------------------------

local function run_capture(argv)
    local cmd = exec.command(unpack_(argv))
    local out, st, code, sig, err = perform(cmd:combined_output_op())
    local ok = (st == 'exited' and code == 0)
    return ok, (out or ''), err, code, st, sig
end

local function try_cmd(argv)
    local ok, out, err, code = run_capture(argv)
    return ok, out, err, code
end

local function must_cmd(argv, label)
    local ok, out, err, code = run_capture(argv)
    if not ok then
        return nil, string.format('%s failed: %s %s',
            label or 'command',
            tostring(err or ''),
            tostring(out or ('exit ' .. tostring(code))))
    end
    return true, nil
end

local function ns_argv(ns, argv)
    local a = { 'ip', 'netns', 'exec', ns }
    for i = 1, #argv do a[#a + 1] = argv[i] end
    return a
end

local function spawn_long(scope, argv, label)
    local cmd = exec.command(unpack_(argv))
    cmd:set_stdin('null')
    cmd:set_stdout('null')
    cmd:set_stderr('null')

    scope:spawn(function()
        local st, code, sig, err = perform(cmd:run_op())
        printf('peer process exit label=%s status=%s code=%s sig=%s err=%s',
            tostring(label), tostring(st), tostring(code), tostring(sig), tostring(err))
    end)

    return cmd
end

-------------------------------------------------------------------------------
-- sysfs counters (root namespace)
-------------------------------------------------------------------------------

local function read_sysfs_u64(path)
    local f = io.open(path, 'rb')
    if not f then return nil, 'open failed' end
    local s = f:read('*a')
    f:close()
    if not s then return nil, 'read failed' end
    local n = tonumber((s:gsub('%s+', '')))
    if not n then return nil, 'parse failed' end
    return n, nil
end

local function dev_tx_bytes(dev)
    return read_sysfs_u64('/sys/class/net/' .. tostring(dev) .. '/statistics/tx_bytes')
end

-------------------------------------------------------------------------------
-- Minimal JSON scraping for tc -j output (no full JSON parser)
-------------------------------------------------------------------------------

local function json_first_number(section, key)
    if not section then return nil end
    local pat = '"' .. key .. '"%s*:%s*([%-]?%d+)'
    return tonumber(section:match(pat))
end

local function extract_tin0(json)
    return type(json) == 'string' and json:match('"tins"%s*:%s*%[%s*{(.-)}%s*%]') or nil
end

local function parse_cake_json(json)
    local tin = extract_tin0(json)
    if not tin then return nil, 'no tins in tc json' end
    local out = {
        target_us     = json_first_number(tin, 'target_us') or 0,
        interval_us   = json_first_number(tin, 'interval_us') or 0,
        avg_delay_us  = json_first_number(tin, 'avg_delay_us') or 0,
        peak_delay_us = json_first_number(tin, 'peak_delay_us') or 0,
        backlog_bytes = json_first_number(tin, 'backlog_bytes') or 0,
        sent_bytes    = json_first_number(tin, 'sent_bytes') or 0,
        sent_packets  = json_first_number(tin, 'sent_packets') or 0,
        drops         = json_first_number(tin, 'drops') or 0,
        ecn_mark      = json_first_number(tin, 'ecn_mark') or 0,
        ack_drops     = json_first_number(tin, 'ack_drops') or 0,
    }
    out.overlimits = tonumber(json:match('"overlimits"%s*:%s*(%d+)')) or 0
    return out, nil
end

-------------------------------------------------------------------------------
-- Topology
-------------------------------------------------------------------------------

local NS_ISP    = 'dcisp'
local NS_PEER   = 'dcpeer'

local DEV_ROOT  = 'veth_dc0'
local DEV_ISP0  = 'veth_isp0'
local DEV_ISP1  = 'veth_isp1'
local DEV_PEER  = 'veth_peer0'

local IP_ROOT   = '10.123.0.1/24'
local IP_ISP0   = '10.123.0.2/24'
local IP_ISP1   = '10.123.1.1/24'
local IP_PEER   = '10.123.1.2/24'

local PEER_HOST = '10.123.1.2'
local PEER_PORT = 5001

local function teardown_topology()
    pcall(function() try_cmd({ 'tc', 'qdisc', 'del', 'dev', DEV_ROOT, 'root' }) end)
    pcall(function() try_cmd(ns_argv(NS_ISP, { 'tc', 'qdisc', 'del', 'dev', DEV_ISP1, 'root' })) end)

    pcall(function() try_cmd({ 'ip', 'link', 'del', DEV_ROOT }) end)
    pcall(function() try_cmd({ 'ip', 'netns', 'del', NS_PEER }) end)
    pcall(function() try_cmd({ 'ip', 'netns', 'del', NS_ISP }) end)
end

local function setup_topology()
    printf('=== create veth + netns ===')

    try_cmd({ 'ip', 'link', 'del', DEV_ROOT })
    try_cmd({ 'ip', 'netns', 'del', NS_PEER })
    try_cmd({ 'ip', 'netns', 'del', NS_ISP })

    local ok, err

    ok, err = must_cmd({ 'ip', 'netns', 'add', NS_ISP }, 'netns add dcisp'); if not ok then return nil, err end
    ok, err = must_cmd({ 'ip', 'netns', 'add', NS_PEER }, 'netns add dcpeer'); if not ok then return nil, err end

    ok, err = must_cmd({ 'ip', 'link', 'add', DEV_ROOT, 'type', 'veth', 'peer', 'name', DEV_ISP0 }, 'veth add root-isp0')
    if not ok then return nil, err end
    ok, err = must_cmd({ 'ip', 'link', 'set', DEV_ISP0, 'netns', NS_ISP }, 'move isp0 into dcisp'); if not ok then return
        nil, err end

    ok, err = must_cmd(ns_argv(NS_ISP, { 'ip', 'link', 'add', DEV_ISP1, 'type', 'veth', 'peer', 'name', DEV_PEER }),
        'veth add isp1-peer')
    if not ok then return nil, err end
    ok, err = must_cmd(ns_argv(NS_ISP, { 'ip', 'link', 'set', DEV_PEER, 'netns', NS_PEER }), 'move peer into dcpeer')
    if not ok then return nil, err end

    ok, err = must_cmd({ 'ip', 'addr', 'add', IP_ROOT, 'dev', DEV_ROOT }, 'addr root'); if not ok then return nil, err end
    ok, err = must_cmd({ 'ip', 'link', 'set', DEV_ROOT, 'up' }, 'link up root'); if not ok then return nil, err end

    ok, err = must_cmd(ns_argv(NS_ISP, { 'ip', 'addr', 'add', IP_ISP0, 'dev', DEV_ISP0 }), 'addr isp0'); if not ok then return
        nil, err end
    ok, err = must_cmd(ns_argv(NS_ISP, { 'ip', 'addr', 'add', IP_ISP1, 'dev', DEV_ISP1 }), 'addr isp1'); if not ok then return
        nil, err end
    ok, err = must_cmd(ns_argv(NS_ISP, { 'ip', 'link', 'set', DEV_ISP0, 'up' }), 'link up isp0'); if not ok then return
        nil, err end
    ok, err = must_cmd(ns_argv(NS_ISP, { 'ip', 'link', 'set', DEV_ISP1, 'up' }), 'link up isp1'); if not ok then return
        nil, err end

    ok, err = must_cmd(ns_argv(NS_PEER, { 'ip', 'addr', 'add', IP_PEER, 'dev', DEV_PEER }), 'addr peer'); if not ok then return
        nil, err end
    ok, err = must_cmd(ns_argv(NS_PEER, { 'ip', 'link', 'set', DEV_PEER, 'up' }), 'link up peer'); if not ok then return
        nil, err end

    try_cmd({ 'ip', 'route', 'del', '10.123.1.0/24' })
    ok, err = must_cmd({ 'ip', 'route', 'add', '10.123.1.0/24', 'via', '10.123.0.2', 'dev', DEV_ROOT },
        'route root->peer')
    if not ok then return nil, err end

    try_cmd(ns_argv(NS_PEER, { 'ip', 'route', 'del', 'default' }))
    ok, err = must_cmd(ns_argv(NS_PEER, { 'ip', 'route', 'add', 'default', 'via', '10.123.1.1' }), 'default route peer')
    if not ok then return nil, err end

    ok, err = must_cmd(ns_argv(NS_ISP, { 'sysctl', '-w', 'net.ipv4.ip_forward=1' }), 'ip_forward')
    if not ok then return nil, err end

    return true, nil
end

-------------------------------------------------------------------------------
-- Qdisc programming
-------------------------------------------------------------------------------

local function set_cake_bandwidth_bps(bps)
    local rate = math.floor(tonumber(bps) or 0)
    if rate < 1000000 then rate = 1000000 end

    local argv_change = {
        'tc', 'qdisc', 'change', 'dev', DEV_ROOT, 'root',
        'cake',
        'bandwidth', tostring(rate) .. 'bit',
        'besteffort',
        'triple-isolate',
        'no-ack-filter',
        'split-gso',
        'raw',
    }
    local ok = select(1, try_cmd(argv_change))
    if ok then return true end

    local argv_replace = {
        'tc', 'qdisc', 'replace', 'dev', DEV_ROOT, 'root',
        'cake',
        'bandwidth', tostring(rate) .. 'bit',
        'besteffort',
        'triple-isolate',
        'no-ack-filter',
        'split-gso',
        'raw',
    }
    local ok2, err = must_cmd(argv_replace, 'cake replace')
    if not ok2 then error(err, 2) end
    return true
end

-- netem rate only (no delay/jitter)
local function set_netem_rate_mbit(rate_mbit)
    local r = math.floor(tonumber(rate_mbit) or 1)
    if r < 1 then r = 1 end

    local argv = { 'tc', 'qdisc', 'replace', 'dev', DEV_ISP1, 'root', 'netem', 'rate', tostring(r) .. 'mbit' }
    local ok, err = must_cmd(ns_argv(NS_ISP, argv), 'netem replace')
    if not ok then error(err, 2) end
    return true
end

local function read_cake_stats()
    local ok, out = run_capture({ 'tc', '-j', '-s', 'qdisc', 'show', 'dev', DEV_ROOT })
    if not ok then return nil, 'tc cake read failed' end
    return parse_cake_json(out)
end

-------------------------------------------------------------------------------
-- Peer sink server
-------------------------------------------------------------------------------

local function server_sink_main(host, port)
    local srv, err = socket.listen_inet(host, port)
    assert(srv, 'listen failed: ' .. tostring(err))

    while true do
        local cli = srv:accept()
        if cli then
            fibers.spawn(function()
                while true do
                    local s = cli:read_some(64 * 1024)
                    if not s then break end
                end
                pcall(function() cli:close() end)
            end)
        end
    end
end

local function wait_port_up(deadline_s)
    local t0 = ts()
    while ts() - t0 < deadline_s do
        local s = socket.connect_inet(PEER_HOST, PEER_PORT, {})
        if s then
            pcall(function() s:close() end)
            return true
        end
        sleep.sleep(0.05)
    end
    return nil
end

-------------------------------------------------------------------------------
-- Real ping probes (ICMP) - one-shot loop (BusyBox-friendly)
-------------------------------------------------------------------------------

local function extract_ping_rtt_ms(text)
    if type(text) ~= 'string' then return nil end
    -- BusyBox: "64 bytes from ...: seq=0 ttl=63 time=0.558 ms"
    local tms = text:match('time[=<]([%d%.]+)%s*ms')
    return tms and tonumber(tms) or nil
end

local function ping_once(ns, host, size_bytes, timeout_s)
    size_bytes = math.floor(tonumber(size_bytes) or 24)
    if size_bytes < 0 then size_bytes = 0 end

    -- BusyBox supports -c, -W, -s, -n reliably. Avoid fractional -i.
    local argv = { 'ping', '-n', '-c', '1', '-W', tostring(math.floor(timeout_s or 1)), '-s', tostring(size_bytes), host }
    if ns then
        argv = ns_argv(ns, argv)
    end

    local ok, out = run_capture(argv)
    if not ok then
        -- Out may contain the error message; caller can decide what to do.
        return nil, out
    end

    local rtt = extract_ping_rtt_ms(out)
    if not rtt then
        return nil, out
    end
    return rtt, nil
end

local function ping_probe_loop(scope, label, ns, host, state, state_key, stop_at)
    scope:spawn(function()
        local win_t0 = ts()
        local n, sum, mn, mx = 0, 0.0, nil, nil

        local function flush(now)
            if n > 0 then
                local avg = sum / n
                state[state_key] = avg
                printf('PING %s rtt_ms avg=%.3f min=%.3f max=%.3f n=%d',
                    tostring(label), avg, mn or 0, mx or 0, n)
            else
                printf('PING %s no_samples', tostring(label))
            end
            win_t0, n, sum, mn, mx = now, 0, 0.0, nil, nil
        end

        while ts() < stop_at do
            local rtt, perr = ping_once(ns, host, CFG.ping_size_bytes, 1)
            if rtt then
                n = n + 1
                sum = sum + rtt
                mn = mn and math.min(mn, rtt) or rtt
                mx = mx and math.max(mx, rtt) or rtt
            end

            local now = ts()
            if (now - win_t0) >= (CFG.ping_log_period_s or 1.0) then
                flush(now)
            end

            sleep.sleep(CFG.ping_interval_s or 0.2)
        end

        flush(ts())
    end)
end

-------------------------------------------------------------------------------
-- Traffic generator
-------------------------------------------------------------------------------

local function connect_sink()
    local s, err = socket.connect_inet(PEER_HOST, PEER_PORT, {})
    if not s then return nil, err end
    s:setvbuf('full', 65536)
    return s, nil
end

local function traffic_loop(probe_tx, stop_at)
    local s, err = connect_sink()
    assert(s, 'connect sink failed: ' .. tostring(err))

    local chunk = string.rep('A', 16 * 1024)
    local next_probe = ts() + 0.7
    local next_demand_change = ts()
    local demand_mbit = 0

    while ts() < stop_at do
        local now = ts()

        if now >= next_demand_change then
            local choices = { 0, 2, 5, 10, 20, 40, 80, 120, 180 }
            demand_mbit = choices[math.random(1, #choices)]
            next_demand_change = now + 2.0
        end

        if now >= next_probe then
            local id = math.floor(now * 1000)
            local t0 = ts()
            perform(probe_tx:send_op({ kind = 'probe_begin', id = id, t = t0 }))

            local tend = t0 + CFG.probe_dur_s
            local writes = 0
            while ts() < tend do
                local n = s:write(chunk)
                if not n then break end
                writes = writes + 1
                if (writes % 32) == 0 then pcall(function() s:flush() end) end
            end
            pcall(function() s:flush() end)

            local t1 = ts()
            perform(probe_tx:send_op({ kind = 'probe_end', id = id, t = t1, dur = (t1 - t0) }))

            next_probe = t1 + CFG.probe_period_s
        else
            local tick = 0.02
            local want_bytes = (demand_mbit * 1000 * 1000 / 8) * tick
            local sent = 0

            while sent < want_bytes do
                local n = s:write(chunk)
                if not n then break end
                sent = sent + n
            end
            pcall(function() s:flush() end)
            sleep.sleep(tick)
        end
    end

    pcall(function() s:close() end)
end

-------------------------------------------------------------------------------
-- Netem schedule (rate only)
-------------------------------------------------------------------------------

local function netem_controller(state, stop_at)
    local rate = clamp(CFG.initial_mbit, CFG.min_mbit, CFG.max_mbit)
    while ts() < stop_at do
        local mults = { 0.6, 0.8, 1.0, 1.25, 1.6 }
        rate = math.floor(clamp(rate * mults[math.random(1, #mults)], CFG.min_mbit, CFG.max_mbit))

        set_netem_rate_mbit(rate)
        state.true_rate_mbit = rate
        state.last_netem_change = ts()
        printf('NETEM rate now %d mbit', rate)

        sleep.sleep(CFG.netem_step_s)
    end
end

-------------------------------------------------------------------------------
-- Estimator / tuner (no netem stats; CAKE + delivered bytes only)
-------------------------------------------------------------------------------

local function estimator_loop(probe_rx, state, stop_at)
    local min_bps = mbit_to_bps(CFG.min_mbit)
    local max_bps = mbit_to_bps(CFG.max_mbit)

    local link_est_bps = mbit_to_bps(CFG.initial_mbit)
    local cake_set_bps = math.floor(link_est_bps * (1.0 - CFG.margin))
    set_cake_bandwidth_bps(cake_set_bps)

    local UTIL_OVERSHOOT   = 0.90
    local UTIL_AT_LIMIT    = 0.95
    local UP_FAST          = 1.15
    local UP_SLOW          = 1.08
    local MAX_UP_STEP_S    = 1.25
    local DRAIN_MAX_S      = 0.25
    local DRAIN_POLL_S     = 0.01

    local probe_base       = nil
    local consec_overshoot = 0
    local consec_at_limit  = 0
    local last_up_t        = 0

    printf(
        'thresholds util_overshoot=%.3f util_at_limit=%.3f up_fast=%.3f up_slow=%.3f max_up_step_s=%.2f drain_max_s=%.2f margin=%.3f',
        UTIL_OVERSHOOT, UTIL_AT_LIMIT, UP_FAST, UP_SLOW, MAX_UP_STEP_S, DRAIN_MAX_S, CFG.margin)

    printf(
    't  true  est  cake_set  probe  util  ovl_d  avg_ms  pk_ms  q_ms  cb_kb  post_ms  ping_r2p ping_p2r  lowQ cakeQ  overC limC canUp  cOv cLim upAge  churn%%  implied  upF  action')

    local function wait_drain()
        local t0 = ts()
        local last = nil
        while (ts() - t0) < DRAIN_MAX_S do
            local c = select(1, read_cake_stats())
            if c then last = c end
            local cb = last and tonumber(last.backlog_bytes or 0) or 0
            if cb < 4096 then
                break
            end
            sleep.sleep(DRAIN_POLL_S)
        end
        return last, (ts() - t0)
    end

    while ts() < stop_at do
        local ev = perform(probe_rx:recv_op())
        if not ev then return end

        if ev.kind == 'probe_begin' then
            local cake0 = select(1, read_cake_stats())
            local b0    = select(1, dev_tx_bytes(DEV_ROOT))
            probe_base  = { id = ev.id, t0 = ev.t, cake0 = cake0, b0 = b0 }
        elseif ev.kind == 'probe_end' and probe_base and probe_base.id == ev.id then
            -- Extend measurement window until CAKE backlog drains (or timeout),
            -- then compute delivered rate over the whole window.
            local cake1, drain_s = wait_drain()
            if not cake1 then cake1 = assert(select(1, read_cake_stats())) end
            local b1  = select(1, dev_tx_bytes(DEV_ROOT)) or 0
            local t1  = ts()
            local dur = t1 - (probe_base.t0 or t1)
            if dur <= 0 then dur = 0.001 end

            local b0 = tonumber(probe_base.b0 or 0) or 0
            if b1 < b0 then b0 = 0 end

            local probe_bps = ((b1 - b0) * 8) / dur

            local target_us = tonumber(cake1.target_us or 5000) or 5000
            local avg_us    = tonumber(cake1.avg_delay_us or 0) or 0
            local pk_us     = tonumber(cake1.peak_delay_us or 0) or 0
            local cb        = tonumber(cake1.backlog_bytes or 0) or 0

            local ovl0      = tonumber(probe_base.cake0 and probe_base.cake0.overlimits or 0) or 0
            local ovl1      = tonumber(cake1.overlimits or 0) or 0
            local ovl_d     = ovl1 - ovl0
            if ovl_d < 0 then ovl_d = 0 end

            local util           = (cake_set_bps > 0) and (probe_bps / cake_set_bps) or 0
            local qtime_s        = (probe_bps > 0) and ((cb * 8) / probe_bps) or 0
            local qtime_ms       = qtime_s * 1000.0

            -- "Low enough" to allow upward search; relax vs CAKE target.
            local low_queue      =
                (avg_us < (0.60 * target_us)) and
                (cb < 32 * 1024) and
                (qtime_s < 0.004)

            local cake_queueing  =
                (avg_us > (0.45 * target_us)) or
                (qtime_s > 0.0015) or
                (cb > 16 * 1024)

            local overshoot_cond = (util < UTIL_OVERSHOOT) and low_queue
            local limit_cond     = (util > UTIL_AT_LIMIT)

            local now            = ts()
            local up_age         = (last_up_t > 0) and (now - last_up_t) or 9999.0
            local can_step       = up_age >= MAX_UP_STEP_S

            local action         = 'hold'
            local implied_mbit   = 0.0
            local up_factor      = 0.0

            if overshoot_cond then
                consec_overshoot = consec_overshoot + 1
                consec_at_limit = 0
                if consec_overshoot >= 1 then
                    local implied = clamp(probe_bps / (1.0 - CFG.margin), min_bps, max_bps)
                    link_est_bps = math.floor(implied)
                    implied_mbit = bps_to_mbit(implied)
                    action = 'down(external_limit)'
                    consec_overshoot = 0
                end
            elseif limit_cond then
                consec_overshoot = 0
                consec_at_limit = consec_at_limit + 1

                if can_step and cake_queueing then
                    up_factor = UP_FAST
                    link_est_bps = math.min(max_bps, math.floor(link_est_bps * up_factor))
                    last_up_t = now
                    action = 'up(bottleneck)'
                    consec_at_limit = 0
                elseif can_step and consec_at_limit >= 3 and low_queue then
                    up_factor = UP_SLOW
                    link_est_bps = math.min(max_bps, math.floor(link_est_bps * up_factor))
                    last_up_t = now
                    action = 'up(search)'
                    consec_at_limit = 0
                end
            else
                consec_overshoot = 0
                consec_at_limit = 0
            end

            link_est_bps = clamp(link_est_bps, min_bps, max_bps)
            local new_cake_set = math.floor(link_est_bps * (1.0 - CFG.margin))
            if new_cake_set < 1000000 then new_cake_set = 1000000 end

            local churn = (cake_set_bps > 0) and (math.abs(new_cake_set - cake_set_bps) / cake_set_bps) or 1.0
            local churn_pct = churn * 100.0

            if churn > 0.02 then
                set_cake_bandwidth_bps(new_cake_set)
                cake_set_bps = new_cake_set
            end

            local ping_r2p = tonumber(state.ping_root_to_peer_ms or 0) or 0
            local ping_p2r = tonumber(state.ping_peer_to_root_ms or 0) or 0

            printf(
                '%.3f  %4.0f  %4.1f  %7.1f  %6.1f  %4.2f  %5d  %6.3f  %6.3f  %5.3f  %5.1f  %7.1f  %8.3f %8.3f  %d    %d     %d    %d    %d    %3d  %4d  %5.2f  %6.2f  %7.1f  %4.2f  %s',
                now,
                tonumber(state.true_rate_mbit or 0) or 0,
                bps_to_mbit(link_est_bps),
                bps_to_mbit(cake_set_bps),
                bps_to_mbit(probe_bps),
                util,
                ovl_d,
                avg_us / 1000.0,
                pk_us / 1000.0,
                qtime_ms,
                cb / 1024.0,
                (drain_s or 0) * 1000.0,
                ping_r2p,
                ping_p2r,
                low_queue and 1 or 0,
                cake_queueing and 1 or 0,
                overshoot_cond and 1 or 0,
                limit_cond and 1 or 0,
                can_step and 1 or 0,
                consec_overshoot,
                consec_at_limit,
                up_age,
                churn_pct,
                implied_mbit,
                up_factor,
                action
            )

            probe_base = nil
        end
    end
end

-------------------------------------------------------------------------------
-- Main
-------------------------------------------------------------------------------

local function main(scope)
    math.randomseed(os.time() + math.floor(ts() * 1000))

    local ok, err = setup_topology()
    assert(ok, err)

    scope:finally(function() teardown_topology() end)

    printf('=== start peer sink server in netns (via exec; no shell backgrounding) ===')

    local script = tostring((arg and arg[0]) or 'cake_netem_estimator.lua')
    spawn_long(scope, ns_argv(NS_PEER, { 'luajit', script, '--server-internal' }), 'dcpeer_sink')

    assert(wait_port_up(2.0), 'peer server did not become reachable')

    printf('=== apply initial CAKE + netem(rate only) ===')
    set_netem_rate_mbit(CFG.initial_mbit)

    local stop_at = ts() + (tonumber(CFG.duration_s) or 120)
    local state = {
        true_rate_mbit = CFG.initial_mbit,
        ping_root_to_peer_ms = 0,
        ping_peer_to_root_ms = 0,
    }

    -- Optional: start ping probes (one-shot, BusyBox-friendly).
    if CFG.ping_mode ~= 'off' then
        if CFG.ping_mode == 'both' or CFG.ping_mode == 'root' then
            printf('=== start ping root->peer (one-shot) ===')
            ping_probe_loop(scope, 'root->peer', nil, PEER_HOST, state, 'ping_root_to_peer_ms', stop_at)
        end

        if CFG.ping_mode == 'both' or CFG.ping_mode == 'peer' then
            printf('=== start ping peer->root (one-shot, in netns) ===')
            ping_probe_loop(scope, 'peer->root', NS_PEER, '10.123.0.1', state, 'ping_peer_to_root_ms', stop_at)
        end
    end

    local probe_tx, probe_rx = mailbox.new(64, { full = 'drop_oldest' })

    scope:spawn(function() netem_controller(state, stop_at) end)
    scope:spawn(function() traffic_loop(probe_tx, stop_at) end)
    scope:spawn(function() estimator_loop(probe_rx, state, stop_at) end)

    sleep.sleep(CFG.duration_s)
    printf('=== done ===')
end

for i = 1, #(arg or {}) do
    if arg[i] == '--server-internal' then
        fibers.run(function() server_sink_main('0.0.0.0', PEER_PORT) end)
        return
    end
end

fibers.run(main)
