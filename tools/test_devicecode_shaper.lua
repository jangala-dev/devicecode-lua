-- test_tc_shaper_veth.lua
-- Lua 5.1 / LuaJIT
--
-- Requires:
--   * tc_shaper.lua in current directory
--   * fibers + fibers.io.exec
--   * ip (with netns), tc, ping
--
-- What it does:
--   * creates veth pair dc0 <-> dc1 (dc1 moved into netns)
--   * assigns 10.12.0.1/20 on dc0
--   * assigns 10.12.0.2/20 and 10.12.15.2/20 on dc1
--   * applies tc_shaper on dc0 for egress + ingress(IFB)
--   * sends pings both directions
--   * checks class counters for per-host classes on dc0 and ifb_dc0

package.path    = '../src/?.lua;' .. package.path

local safe    = require 'coxpcall'

local fibers    = require 'fibers'
local exec_mod  = require 'fibers.io.exec'
local performer = require 'fibers.performer'
local shaper    = require 'services.hal.backends.tc_u32_shaper'

local perform   = performer.perform
local unpack    = unpack or table.unpack

local NS        = 'dcns_tc'
local DEV0      = 'dc0'
local DEV1      = 'dc1'
local IFB       = 'ifb_dc0'

local function run_cmd(argv)
    local cmd = exec_mod.command(unpack(argv))
    local out, st, code, sig, err = perform(cmd:combined_output_op())
    local ok = (st == 'exited' and code == 0)
    return ok, out or '', err, code, st, sig
end

local function try_cmd(argv)
    return run_cmd(argv)
end

local function must_cmd(argv, label)
    local ok, out, err, code = run_cmd(argv)
    if not ok then
        error((label or table.concat(argv, ' ')) .. ': ' .. tostring(err or out or ('exit ' .. tostring(code))), 1)
    end
    return out
end

local function say(...)
    local parts = {}
    for i = 1, select('#', ...) do
        parts[#parts + 1] = tostring(select(i, ...))
    end
    io.stdout:write(table.concat(parts, ' ') .. '\n')
end

local function section(name)
    say(('='):rep(72))
    say(name)
    say(('='):rep(72))
end

local function parse_ipv4(s)
    local a, b, c, d = tostring(s):match('^(%d+)%.(%d+)%.(%d+)%.(%d+)$')
    a, b, c, d = tonumber(a), tonumber(b), tonumber(c), tonumber(d)
    if not (a and b and c and d) then return nil end
    if a > 255 or b > 255 or c > 255 or d > 255 then return nil end
    return ((a * 256 + b) * 256 + c) * 256 + d
end

local function parse_cidr(cidr)
    local ip_s, pfx_s = tostring(cidr):match('^([^/]+)/(%d+)$')
    if not ip_s then return nil, nil end
    local ip = parse_ipv4(ip_s)
    local pfx = tonumber(pfx_s)
    if not ip or not pfx then return nil, nil end
    local host_bits = 32 - pfx
    local net = ip
    if host_bits > 0 then
        local block = 2 ^ host_bits
        net = ip - (ip % block)
    end
    return net, pfx
end

local function host_classid(cidr, ip_s)
    local net_u, pfx = parse_cidr(cidr)
    local ip_u = parse_ipv4(ip_s)
    if not net_u or not ip_u then return nil end
    local off = ip_u - net_u
    if off < 0 then return nil end
    -- tc_shaper default base_minor is 1000, inner major is 20
    local minor = 1000 + off
    return '20:' .. tostring(minor)
end

local function class_sent_bytes(dev, classid)
    local out = must_cmd({ 'tc', '-s', 'class', 'show', 'dev', dev }, 'tc -s class show ' .. dev)

    local cur = nil
    for line in tostring(out):gmatch('[^\r\n]+') do
        local cid = line:match('^class%s+htb%s+([^%s]+)')
        if cid then
            cur = cid
        elseif cur == classid then
            local n = line:match('Sent%s+(%d+)%s+bytes')
            if n then return tonumber(n) or 0, out end
        end
    end

    return 0, out
end

local function cleanup()
    -- Best-effort cleanup; ignore failures.
    pcall(function() shaper.clear(DEV0, { ifb = IFB, delete_ifb = true }) end)
    try_cmd({ 'ip', 'link', 'del', DEV0 })
    try_cmd({ 'ip', 'netns', 'del', NS })
end

local function main()
    section('Cleanup any leftovers')
    cleanup()

    section('Sanity checks')
    must_cmd({ 'id', '-u' }, 'id -u')
    must_cmd({ 'ip', '-V' }, 'ip -V')
    must_cmd({ 'tc', '-V' }, 'tc -V')
    must_cmd({ 'ping', '-c', '1', '127.0.0.1' }, 'ping self-test')

    section('Set up veth + netns')
    must_cmd({ 'ip', 'netns', 'add', NS }, 'ip netns add')
    must_cmd({ 'ip', 'link', 'add', DEV0, 'type', 'veth', 'peer', 'name', DEV1 }, 'ip link add veth')
    must_cmd({ 'ip', 'link', 'set', DEV1, 'netns', NS }, 'move peer to netns')

    must_cmd({ 'ip', 'addr', 'add', '10.12.0.1/20', 'dev', DEV0 }, 'addr add dc0')
    must_cmd({ 'ip', 'link', 'set', DEV0, 'up' }, 'link up dc0')

    must_cmd({ 'ip', 'netns', 'exec', NS, 'ip', 'link', 'set', 'lo', 'up' }, 'netns lo up')
    must_cmd({ 'ip', 'netns', 'exec', NS, 'ip', 'addr', 'add', '10.12.0.2/20', 'dev', DEV1 }, 'addr add dc1 primary')
    must_cmd({ 'ip', 'netns', 'exec', NS, 'ip', 'addr', 'add', '10.12.15.2/20', 'dev', DEV1 }, 'addr add dc1 secondary')
    must_cmd({ 'ip', 'netns', 'exec', NS, 'ip', 'link', 'set', DEV1, 'up' }, 'link up dc1')

    section('Apply tc_shaper (egress + ingress via IFB)')
    local ok, err = shaper.apply({
        iface   = DEV0,
        subnet  = '10.12.0.0/20',

        log     = function(level, payload)
            if level == 'error' or level == 'warn' then
                say(
                    '[', level, ']',
                    tostring(payload and payload.what or ''),
                    tostring(payload and payload.label or ''),
                    tostring(payload and payload.cmd or ''),
                    tostring(payload and payload.err or ''),
                    tostring(payload and payload.out or '')
                )
            end
        end,

        egress  = {
            enabled     = true,
            match       = 'dst',
            pool_rate   = '100mbit',
            pool_ceil   = '100mbit',
            host_rate   = '2mbit',
            host_ceil   = '2mbit',
            host_burst  = '16k',
            host_cburst = '16k',
            fq_codel    = {
                flows = 64,
                limit = 256,
                memory_limit = '1Mb',
                target = '5ms',
                interval = '100ms',
                ecn = true,
            },
            hosts       = {
                ['10.12.0.2']  = { rate = '1mbit', ceil = '1mbit' },
                ['10.12.15.2'] = { rate = '3mbit', ceil = '3mbit' },
            },
        },

        ingress = {
            enabled     = true,
            ifb         = IFB,
            match       = 'src', -- matches reply/source IPs from netns in this test
            pool_rate   = '100mbit',
            pool_ceil   = '100mbit',
            host_rate   = '2mbit',
            host_ceil   = '2mbit',
            host_burst  = '16k',
            host_cburst = '16k',
            fq_codel    = {
                flows = 64,
                limit = 256,
                memory_limit = '1Mb',
                target = '5ms',
                interval = '100ms',
                ecn = true,
            },
            hosts       = {
                ['10.12.0.2']  = { rate = '1mbit', ceil = '1mbit' },
                ['10.12.15.2'] = { rate = '3mbit', ceil = '3mbit' },
            },
        },
    })
    if not ok then
        error('shaper.apply failed: ' .. tostring(err))
    end

    section('Generate traffic (both directions)')
    -- Root namespace -> both peer IPs (exercises egress dst match; replies exercise ingress src match)
    must_cmd({ 'ping', '-c', '2', '-W', '1', '-I', '10.12.0.1', '10.12.0.2' }, 'ping to 10.12.0.2')
    must_cmd({ 'ping', '-c', '2', '-W', '1', '-I', '10.12.0.1', '10.12.15.2' }, 'ping to 10.12.15.2')

    -- Optional reverse traffic from netns.
    -- Root->netns pings already exercise both:
    --   * dc0 egress (request)
    --   * IFB ingress shaping (reply)
    -- So reverse ping is not required for the test to be valid.
    do
        local ok1, out1, err1 = try_cmd({ 'ip', 'netns', 'exec', NS, 'ping', '-c', '2', '-W', '1', '-I', '10.12.0.2',
            '10.12.0.1' })
        if not ok1 then
            say('WARN: netns reverse ping (10.12.0.2 -> 10.12.0.1) failed; continuing')
            if out1 and out1 ~= '' then io.stdout:write(out1) end
            if err1 and tostring(err1) ~= '' then io.stdout:write(tostring(err1) .. '\n') end
        end

        local ok2, out2, err2 = try_cmd({ 'ip', 'netns', 'exec', NS, 'ping', '-c', '2', '-W', '1', '-I', '10.12.15.2',
            '10.12.0.1' })
        if not ok2 then
            say('WARN: netns reverse ping (10.12.15.2 -> 10.12.0.1) failed; continuing')
            if out2 and out2 ~= '' then io.stdout:write(out2) end
            if err2 and tostring(err2) ~= '' then io.stdout:write(tostring(err2) .. '\n') end
        end
    end

    section('Check class counters')
    local c_a        = assert(host_classid('10.12.0.0/20', '10.12.0.2'))
    local c_b        = assert(host_classid('10.12.0.0/20', '10.12.15.2'))

    local e_a, e_out = class_sent_bytes(DEV0, c_a)
    local e_b, _     = class_sent_bytes(DEV0, c_b)

    local i_a, i_out = class_sent_bytes(IFB, c_a)
    local i_b, _     = class_sent_bytes(IFB, c_b)

    say('Egress ', DEV0, ' ', c_a, ' Sent bytes = ', e_a)
    say('Egress ', DEV0, ' ', c_b, ' Sent bytes = ', e_b)
    say('Ingress ', IFB, ' ', c_a, ' Sent bytes = ', i_a)
    say('Ingress ', IFB, ' ', c_b, ' Sent bytes = ', i_b)

    local failed = false
    if (e_a or 0) <= 0 then
        failed = true
        say('FAIL: no egress bytes in ', c_a)
    end
    if (e_b or 0) <= 0 then
        failed = true
        say('FAIL: no egress bytes in ', c_b)
    end
    if (i_a or 0) <= 0 then
        failed = true
        say('FAIL: no ingress(IFB) bytes in ', c_a)
    end
    if (i_b or 0) <= 0 then
        failed = true
        say('FAIL: no ingress(IFB) bytes in ', c_b)
    end

    if failed then
        section('Debug dump: tc -s class show')
        say('--- tc -s class show dev ', DEV0, ' ---')
        io.stdout:write(e_out or '')
        if (e_out or ''):sub(-1) ~= '\n' then io.stdout:write('\n') end

        say('--- tc -s class show dev ', IFB, ' ---')
        io.stdout:write(i_out or '')
        if (i_out or ''):sub(-1) ~= '\n' then io.stdout:write('\n') end

        error('traffic did not hit expected per-host classes')
    end

    section('PASS')
    say('Per-host egress and ingress(IFB) shaping counters incremented on /20')
    say('Classes used: ', c_a, ' and ', c_b)
end

fibers.run(function()
    local ok, err = safe.xpcall(main, debug.traceback)
    section('Cleanup')
    cleanup()
    if not ok then
        io.stderr:write(tostring(err) .. '\n')
        os.exit(1)
    end
end)
