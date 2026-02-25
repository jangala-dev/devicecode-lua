-- tools/test_lua_uci_roundtrip.lua
--
-- Exercises libuci-lua behaviours relied on by the backend:
--   * safe section ids vs external ids stored in options
--   * list options
--   * delete option
--   * commit writes into an isolated confdir
--   * get_all round-trip

local uci = require('uci')

local root  = '/tmp/dc-uci-roundtrip'
local conf  = root .. '/etc/config'
local saved = root .. '/.uci'

os.execute(string.format('mkdir -p %q %q', conf, saved))
os.execute(string.format('printf "# test\\n" > %q', conf .. '/network'))

local c = uci.cursor(conf, saved)

-- wipe package if any
local all = c:get_all('network') or {}
for sec in pairs(all) do
  if type(sec) == 'string' and sec:sub(1,1) ~= '.' then
    c:delete('network', sec)
  end
end

-- Create a device with safe section id but external kernel name containing '-'
c:set('network', 'dev_br_adm', 'device')
c:set('network', 'dev_br_adm', 'name', 'br-adm')
c:set('network', 'dev_br_adm', 'type', 'bridge')
c:set('network', 'dev_br_adm', 'ports', { 'eth0.8', 'eth0.9' })

-- Create an interface referencing the kernel device name
c:set('network', 'adm', 'interface')
c:set('network', 'adm', 'proto', 'static')
c:set('network', 'adm', 'device', 'br-adm')
c:set('network', 'adm', 'ipaddr', '172.28.8.1')
c:set('network', 'adm', 'netmask', '255.255.255.0')

-- Delete-on-nil behaviour (simulate uci_set)
c:delete('network', 'adm', 'gateway')

c:commit('network')

print('--- get_all(network)')
local out = c:get_all('network') or {}
for sec, s in pairs(out) do
  if type(sec) == 'string' and sec:sub(1,1) ~= '.' then
    print(sec, s['.type'], s.name or '', s.device or '')
    if s.ports then
      print('  ports:', table.concat(s.ports, ','))
    end
  end
end

print('--- sanity checks')
assert(c:get('network', 'dev_br_adm', 'name') == 'br-adm')
assert(c:get('network', 'adm', 'device') == 'br-adm')

local ports = c:get('network', 'dev_br_adm', 'ports')
assert(type(ports) == 'table' and #ports == 2)

print('OK')
