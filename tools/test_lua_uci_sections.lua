-- tools/test_lua_uci_sections.lua
--
-- Proves what libuci-lua does with section names (not options) containing '-'.
-- Writes only under /tmp.

local uci   = require('uci')

local root  = '/tmp/dc-uci-uciunit'
local conf  = root .. '/etc/config'
local saved = root .. '/.uci'

os.execute(string.format('mkdir -p %q %q', conf, saved))
os.execute(string.format('printf "# test\\n" > %q', conf .. '/network'))

local c = uci.cursor(conf, saved)

-- Case A: section name contains '-'
c:set('network', 'br-adm', 'device')
c:set('network', 'br-adm', 'name', 'br-adm')
c:set('network', 'br-adm', 'type', 'bridge')

-- Case B: safe section name, with option name containing '-'
c:set('network', 'dev_br_adm', 'device')
c:set('network', 'dev_br_adm', 'name', 'br-adm')
c:set('network', 'dev_br_adm', 'type', 'bridge')

c:commit('network')

print('--- uci show (CLI, isolated)')
os.execute(string.format('uci -c %q -p %q show network', conf, saved))

print('--- readback via libuci-lua get_all')
local all = c:get_all('network') or {}
for k, v in pairs(all) do
    print(k, v['.type'], v.name, v.type)
end
