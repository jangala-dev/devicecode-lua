#!/usr/bin/env sh
set -eu

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
VM_DIR="$(dirname "$SCRIPT_DIR")"
ROOT_DIR="$(CDPATH= cd -- "$VM_DIR/../../.." && pwd)"
SSH="$VM_DIR/scripts/ssh"
SCP_TO="$VM_DIR/scripts/scp-to"
REMOTE="/tmp/devicecode-network-provider-dnsmasq-groups-test"
WORK="$VM_DIR/work/network-provider-dnsmasq-groups-test"

mkdir -p "$WORK"
cat > "$WORK/run_openwrt_network_provider_dnsmasq_groups.lua" <<'LUA'
package.path = table.concat({ './src/?.lua', './src/?/init.lua', './vendor/lua-fibers/src/?.lua', './vendor/lua-fibers/src/?/init.lua', './vendor/lua-bus/src/?.lua', './vendor/lua-bus/src/?/init.lua', './vendor/lua-trie/src/?.lua', './vendor/lua-trie/src/?/init.lua', package.path }, ';')
local fibers = require 'fibers'
local uci = require 'uci'
local provider_loader = require 'services.hal.backends.network.provider'
local names_mod = require 'services.hal.backends.network.providers.openwrt.names'
local perform = fibers.perform
local function fail(msg) error(msg, 2) end
local function eq(a,b,msg) if a ~= b then fail((msg or 'values differ') .. ': expected ' .. tostring(b) .. ', got ' .. tostring(a)) end end
local function mkdir_p(path) local ok=os.execute("mkdir -p '"..path.."'"); if ok ~= true and ok ~= 0 then fail('mkdir failed') end end
local function contains(list, value) if type(list)=='table' then for i=1,#list do if list[i]==value then return true end end; return false end return list==value end

local tmp='/tmp/dc-network-provider-dnsmasq-groups'; os.execute("rm -rf '"..tmp.."'")
local conf, save=tmp..'/conf', tmp..'/save'; mkdir_p(conf); mkdir_p(save)
for _,pkg in ipairs({'network','dhcp','firewall','mwan3'}) do local f=assert(io.open(conf..'/'..pkg,'w')); f:close() end

local function seg(kind, vid, host_files)
  return { kind=kind or 'lan', vlan={id=vid}, addressing={ipv4={mode='static', cidr='192.168.'..tostring(vid)..'.1/24'}}, dhcp={enabled=true}, dns={local_server=true, host_files=host_files or {}, domain='bigbox.home'}, firewall={zone='lan'} }
end
local intent={ schema='devicecode.net.intent/1', rev=1, segments={ adm=seg('system',8,{'ads'}), ops=seg('system',9,{'ads'}), jan=seg('user',32,{'ads','adult'}), int=seg('system',100,{}) }, interfaces={}, dns={enabled=true, domain='bigbox.home', upstreams={'1.1.1.1'}, cache={size=1000}, host_files={base_dir='/data/devicecode/dns/hosts', addnmount=true, sources={ads={file='ads.hosts'}, adult={file='adult.hosts'}}}}, dhcp={}, firewall={zones={lan={}}}, routing={}, wan={}, shaping={}, vpn={}, diagnostics={} }
local name_ctx = assert(names_mod.allocate(intent))

fibers.run(function()
  local provider=assert(provider_loader.new({provider='openwrt', confdir=conf, savedir=save, debounce_s=0.01, platform={segment_trunk={ifname='eth0'}}, run_cmd=function() return true,nil end}, {}))
  local r=perform(provider:apply_op({intent=intent})); assert(r and r.ok==true, 'apply failed: '..tostring(r and r.err)); provider:terminate('done')
end)
local c=assert(uci.cursor(conf,save)); for _,pkg in ipairs({'dhcp'}) do if type(c.load)=='function' then pcall(function() c:load(pkg) end) end end
local dns_count=0; local ads_instance; local adult_instance; local standard_instance
for name,sec in pairs(c:get_all('dhcp') or {}) do
  if type(sec)=='table' and sec['.type']=='dnsmasq' then
    dns_count=dns_count+1
    assert(#name <= 15, 'dnsmasq instance name too long: '..name)
    if contains(sec.addnhosts, '/data/devicecode/dns/hosts/ads.hosts') and not contains(sec.addnhosts, '/data/devicecode/dns/hosts/adult.hosts') then ads_instance=name end
    if contains(sec.addnhosts, '/data/devicecode/dns/hosts/adult.hosts') then adult_instance=name end
    if sec.addnhosts == nil then standard_instance=name end
  end
end
eq(dns_count, 3, 'identical DNS policy should be grouped')
assert(ads_instance, 'ads instance expected'); assert(adult_instance, 'ads+adult instance expected'); assert(standard_instance, 'standard instance expected')
local all_dhcp = c:get_all('dhcp') or {}
assert(contains(all_dhcp[ads_instance].notinterface, 'lo'), 'ads instance should exclude loopback: '..ads_instance)
assert(contains(all_dhcp[adult_instance].notinterface, 'lo'), 'ads+adult instance should exclude loopback: '..adult_instance)
assert(not contains(all_dhcp[standard_instance].notinterface, 'lo'), 'standard/int instance should own loopback: '..standard_instance)
local function dhcp_for(seg)
  local wanted = name_ctx:iface(seg)
  for _,sec in pairs(c:get_all('dhcp') or {}) do if type(sec)=='table' and sec['.type']=='dhcp' and sec.interface==wanted then return sec end end
  fail('dhcp section not found for '..seg)
end
eq(dhcp_for('adm').instance, ads_instance, 'adm shares ads instance')
eq(dhcp_for('ops').instance, ads_instance, 'ops shares ads instance')
eq(dhcp_for('jan').instance, adult_instance, 'jan uses adult instance')
eq(dhcp_for('int').instance, standard_instance, 'int uses standard instance')
print('openwrt dnsmasq grouping: ok')
LUA

"$SSH" "rm -rf '$REMOTE'; mkdir -p '$REMOTE'"
"$SCP_TO" "$ROOT_DIR/src" "$REMOTE/src"
"$SCP_TO" "$ROOT_DIR/vendor" "$REMOTE/vendor"
"$SCP_TO" "$WORK/run_openwrt_network_provider_dnsmasq_groups.lua" "$REMOTE/run_openwrt_network_provider_dnsmasq_groups.lua"
"$SSH" "cd '$REMOTE' && lua ./run_openwrt_network_provider_dnsmasq_groups.lua"
