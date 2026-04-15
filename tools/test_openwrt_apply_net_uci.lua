-- tools/test_openwrt_apply_net_uci.lua
--
-- Usage:
--   lua tools/test_openwrt_apply_net_uci.lua ./src/services/hal/backends/hosttest/services.json
--
-- This will:
--   * read JSON config blob (config-service shape)
--   * compile net desired state
--   * apply to an isolated UCI confdir under /tmp
--   * print "uci show" output for the isolated confdir
--
-- It does NOT touch /etc/config and does NOT restart services.

package.path   = '../src/?.lua;' .. package.path

local cjson    = require 'cjson.safe'
local compiler = require 'services.net.compiler'
local backend  = require 'services.hal.backends.openwrt'

local fibers   = require 'fibers'
local exec     = require 'fibers.io.exec'
local file     = require 'fibers.io.file'

local perform  = fibers.perform

local function read_all(path)
    local f, err = io.open(path, 'rb')
    if not f then return nil, err end
    local s = f:read('*a')
    f:close()
    return s, nil
end

local function ensure_pkg_file(confdir, pkg)
    local p = confdir .. '/' .. pkg
    -- Create if missing; do not overwrite if already present.
    local f = io.open(p, 'rb')
    if f then
        f:close(); return
    end
    local s, err = file.open(p, 'w')
    if not s then error('failed to create ' .. p .. ': ' .. tostring(err)) end
    s:write('# devicecode test uci package: ' .. pkg .. '\n')
    s:close()
end

local function mkdir_p(path)
    local cmd = exec.command('mkdir', '-p', path)
    local out, st, code, sig, err = perform(cmd:combined_output_op())
    if st == 'exited' and code == 0 then return true end
    error(('mkdir -p failed: %s'):format(err or out or st))
end

local function uci_show(confdir, pkg)
    local cmd = exec.command('uci', '-c', confdir, 'show', pkg)
    local out, st, code, sig, err = perform(cmd:combined_output_op())
    if st == 'exited' and code == 0 then
        return out
    end
    return ('<uci show failed: %s>'):format(err or out or st)
end

local function main()
    local path = arg[1]
    if not path or path == '' then
        io.stderr:write('usage: lua tools/test_openwrt_apply_net_uci.lua <services.json>\n')
        os.exit(2)
    end

    local blob, rerr = read_all(path)
    if not blob then
        io.stderr:write('read failed: ' .. tostring(rerr) .. '\n')
        os.exit(2)
    end

    local doc, jerr = cjson.decode(blob)
    if not doc then
        io.stderr:write('json decode failed: ' .. tostring(jerr) .. '\n')
        os.exit(2)
    end

    local net = doc.net
    if type(net) ~= 'table' or type(net.rev) ~= 'number' or type(net.data) ~= 'table' then
        io.stderr:write('expected doc.net = { rev:number, data:table }\n')
        os.exit(2)
    end

    local rev = math.floor(net.rev)
    local gen = 1

    local desired, derr = compiler.compile(net.data, { rev = rev, gen = gen, state_schema = 'devicecode.state/2.5' })
    if not desired then
        io.stderr:write('compile failed: ' .. cjson.encode(derr) .. '\n')
        os.exit(1)
    end

    -- Isolated UCI workspace
    local root = '/tmp/dc-uci-test'
    local confdir = root .. '/etc/config'
    local savedir = root .. '/.uci'

    mkdir_p(confdir)
    mkdir_p(savedir)

    ensure_pkg_file(confdir, 'network')
    ensure_pkg_file(confdir, 'dhcp')
    ensure_pkg_file(confdir, 'firewall')
    ensure_pkg_file(confdir, 'mwan3') -- harmless even if not used

    -- Construct backend with alternate UCI dirs and no reload
    local host = {
        state_dir   = root .. '/state',
        uci_confdir = confdir,
        uci_savedir = savedir,
        no_reload   = true,

        log         = function(_, payload)
            -- optional: print minimal logs during test
            -- io.stderr:write(cjson.encode(payload) .. '\n')
        end,
    }
    mkdir_p(host.state_dir)

    local b = backend.new(host)

    local reply = b:apply_net(desired, { id = 'test' })
    print('-- apply_net reply')
    print(cjson.encode(reply))

    print('\n-- uci show network (isolated)')
    print(uci_show(confdir, 'network'))

    print('\n-- uci show dhcp (isolated)')
    print(uci_show(confdir, 'dhcp'))

    print('\n-- uci show firewall (isolated)')
    print(uci_show(confdir, 'firewall'))

    print('\n-- uci show mwan3 (isolated)')
    print(uci_show(confdir, 'mwan3'))
end

fibers.run(function()
    main()
end)
