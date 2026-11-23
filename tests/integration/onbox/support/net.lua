local logs = require 'onbox.support.logs'
local util = require 'onbox.support.util'

local M = {}

function M.members(config)
	local net = assert(config.net and config.net.data, 'Missing NET config')
	local wan = assert(net.wan, 'Missing NET WAN config')
	assert(wan.enabled ~= false, 'NET WAN is disabled')
	return assert(wan.members, 'Missing WAN members'), net
end

function M.status_event(line)
	local what, member, state, interface, device, suffix = line:match(
		'%f[%w]LOG%s+net%s+%S+%s+(%S+)%s+mwan member (%S+) (%S+) interface=(%S+) ifname=(%S+)(.*)$')
	if (what == 'mwan_member_online' and state == 'online') or (what == 'mwan_member_offline' and state == 'offline') then
		local alias = suffix:match('^ via=(%S+)%s*$')
		return { member = member, state = state, interface = interface, device = device ~= '?' and device or nil,
			alias = alias ~= '?' and alias or nil, event_monotonic_s = logs.event_time(line) }
	end
end

function M.snapshot(box)
	local ssh = box.ssh
	local mwan = util.decode(ssh:run('ubus call mwan3 status', { timeout = 20 }).stdout)
	local dump = util.decode(ssh:run('ubus call network.interface dump', { timeout = 20 }).stdout)
	local interfaces = {}
	for _, item in ipairs(assert(dump.interface, 'Missing netifd interfaces')) do interfaces[item.interface] = item end
	return assert(mwan.interfaces, 'Missing mwan3 interfaces'), interfaces
end

function M.online_binding(alias, mwan, interfaces)
	local status = mwan[alias]
	if not status then return nil, 'mwan3 interface absent' end
	local online = status.status == 'online' or (status.status == nil and status.online == true)
	if status.enabled == false or not online then
		return nil, 'mwan3 ' .. (status.enabled == false and 'disabled' or tostring(status.status or 'unknown'))
	end
	local interface = interfaces[alias]
	if not interface or interface.up ~= true then return nil, 'netifd interface down' end
	local device = interface.l3_device or interface.device
	if type(device) ~= 'string' or device == '' then return nil, 'no Linux device' end
	local ipv4 = interface['ipv4-address'] or {}
	local address = ipv4[1]
	return { device = device, address = address and address.address, ipv4_count = #ipv4, alias = alias }
end

function M.speedtest_event(line)
	local summary = line:match('%f[%w]LOG%s+net%s+%S+%s+speedtest_completed%s+(.+)$')
	if not summary then return end
	local member, interface, device, mbps, suffix = summary:match('^speedtest (%S+) on ([^/]+)/(%S+): ([%d.]+) Mbps(.*)$')
	if member then
		local flags, address, alias = suffix:match('^(.-) source=(%S+) via=(%S+)%s*$')
		flags = flags or suffix
		if flags ~= '' and flags ~= ' (lower bound)' then return end
		return { member = member, interface = interface, device = device, mbps = tonumber(mbps),
			lower_bound = flags ~= '', address = address, alias = alias,
			monotonic_s = tonumber(line:match('%(mono=([%d.]+)%)')) }
	end
	local id, err = summary:match('^speedtest (%S+) failed: (.+)$')
	if id then return { member = id, error = err } end
end

return M
