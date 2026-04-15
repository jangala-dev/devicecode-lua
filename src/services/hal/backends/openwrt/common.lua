-- services/hal/backends/openwrt/common.lua
--
-- Shared helpers for the OpenWrt HAL backend.

local fibers  = require 'fibers'
local file    = require 'fibers.io.file'
local exec    = require 'fibers.io.exec'

local perform = fibers.perform

local M       = {}

function M.is_plain_table(x) return type(x) == 'table' and getmetatable(x) == nil end

function M.sorted_keys(t)
	local ks = {}
	for k in pairs(t or {}) do ks[#ks + 1] = k end
	table.sort(ks, function(a, b) return tostring(a) < tostring(b) end)
	return ks
end

function M.sanitise_component(s)
	s = tostring(s or '')
	s = s:gsub('[^%w%._%-]', '_')
	if s == '' then s = '_' end
	return s
end

function M.sid(x)
	return M.sanitise_component(x):gsub('%-', '_')
end

function M.uci_sec_id(prefix, name)
	local s = M.sanitise_component(name):gsub('%-', '_'):gsub('%.', '_')
	return prefix .. s
end

function M.state_path(state_dir, ns, key)
	return state_dir .. '/' .. M.sanitise_component(ns) .. '/' .. M.sanitise_component(key)
end

function M.ns_dir(state_dir, ns)
	return state_dir .. '/' .. M.sanitise_component(ns)
end

function M.trim(s)
	if s == nil then return nil end
	return (tostring(s):gsub('^%s+', ''):gsub('%s+$', ''))
end

function M.split_lines(s)
	local out = {}
	for line in tostring(s or ''):gmatch('[^\n]+') do
		out[#out + 1] = line
	end
	return out
end

function M.sorted_array_from_map_keys(t)
	local out = {}
	for k in pairs(t or {}) do out[#out + 1] = k end
	table.sort(out, function(a, b) return tostring(a) < tostring(b) end)
	return out
end

function M.cmd_ok(...)
	local cmd = exec.command(...)
	local out, st, code, sig, err = perform(cmd:combined_output_op())

	if st == 'exited' and code == 0 then
		return true, nil
	end

	local detail = err or out or ('status=' .. tostring(st))
	if st == 'exited' then
		detail = (detail or '') .. ' (exit ' .. tostring(code) .. ')'
	elseif st == 'signalled' then
		detail = (detail or '') .. ' (signal ' .. tostring(sig) .. ')'
	end
	return nil, detail
end

function M.cmd_capture(...)
	local cmd = exec.command(...)
	local out, st, code, sig, err = perform(cmd:combined_output_op())

	if st == 'exited' and code == 0 then
		return true, out or '', nil
	end

	local detail = err or out or ('status=' .. tostring(st))
	if st == 'exited' then
		detail = (detail or '') .. ' (exit ' .. tostring(code) .. ')'
	elseif st == 'signalled' then
		detail = (detail or '') .. ' (signal ' .. tostring(sig) .. ')'
	end
	return nil, out or '', detail
end

function M.mkdir_p(path)
	local ok, err = M.cmd_ok('mkdir', '-p', path)
	return ok ~= nil, err
end

function M.bool_uci(v)
	if v == nil then return nil end
	return v and '1' or '0'
end

function M.uci_set(cur, pkg, sec, opt, v)
	if v == nil then
		cur:delete(pkg, sec, opt)
		return
	end
	local tv = type(v)
	if tv == 'boolean' then
		cur:set(pkg, sec, opt, M.bool_uci(v))
	elseif tv == 'number' then
		cur:set(pkg, sec, opt, tostring(v))
	elseif tv == 'table' then
		cur:set(pkg, sec, opt, v)
	else
		cur:set(pkg, sec, opt, tostring(v))
	end
end

function M.uci_set_list(cur, pkg, sec, opt, list)
	if list == nil then
		cur:delete(pkg, sec, opt)
		return
	end
	if type(list) ~= 'table' then
		cur:set(pkg, sec, opt, { tostring(list) })
		return
	end
	local out = {}
	for i = 1, #list do out[i] = tostring(list[i]) end
	cur:set(pkg, sec, opt, out)
end

function M.uci_try_load(cur, pkg)
	pcall(function()
		if type(cur.load) == 'function' then cur:load(pkg) end
	end)
end

function M.ensure_pkg_file(host, pkg)
	if not host or not host.uci_confdir then return true end

	local path = host.uci_confdir .. '/' .. pkg
	local f = io.open(path, 'rb')
	if f then
		f:close()
		return true
	end

	local s, err = file.open(path, 'w')
	if not s then
		return nil, ('failed to create %s: %s'):format(path, tostring(err))
	end
	s:write('# devicecode generated (test confdir)\n')
	s:close()
	return true, nil
end

function M.wipe_pkg(cur, pkg)
	M.uci_try_load(cur, pkg)

	local all = cur:get_all(pkg)
	if type(all) == 'table' then
		for secname in pairs(all) do
			if type(secname) == 'string' and secname:sub(1, 1) ~= '.' then
				cur:delete(pkg, secname)
			end
		end
		return
	end

	local types = {
		network  = { 'globals', 'device', 'interface', 'route', 'route6', 'rule', 'rule6' },
		dhcp     = { 'dnsmasq', 'dhcp', 'domain', 'host' },
		firewall = { 'defaults', 'zone', 'forwarding', 'rule', 'redirect', 'include' },
		mwan3    = { 'globals', 'interface', 'member', 'policy', 'rule' },
	}
	for _, tp in ipairs(types[pkg] or {}) do
		cur:foreach(pkg, tp, function(s) cur:delete(pkg, s['.name']) end)
	end
end

function M.prefix_to_netmask(prefix)
	prefix = tonumber(prefix)
	if not prefix or prefix < 0 then return nil end
	if prefix > 32 then prefix = 32 end
	local rem = prefix
	local octs = {}
	for i = 1, 4 do
		local b
		if rem >= 8 then
			b = 255
			rem = rem - 8
		elseif rem > 0 then
			b = 256 - (2 ^ (8 - rem))
			rem = 0
		else
			b = 0
		end
		octs[i] = b
	end
	return string.format('%d.%d.%d.%d', octs[1], octs[2], octs[3], octs[4])
end

function M.resolve_ifname(host, ifname)
	if type(ifname) ~= 'string' then return ifname, nil end
	if ifname:sub(1, 7) == '@modem.' then
		if host and type(host.resolve_ifname) == 'function' then
			local r = host.resolve_ifname(ifname)
			if type(r) == 'string' and r ~= '' then return r, nil end
			return nil, 'unresolved selector ' .. ifname
		end
		return nil, 'no resolver for selector ' .. ifname
	end
	return ifname, nil
end

function M.read_first_line(path)
	local s, err = file.open(path, 'r')
	if not s then return nil, err end
	local line, rerr = s:read_line()
	s:close()
	if rerr ~= nil then return nil, rerr end
	if line == nil then return nil, 'empty file' end
	return tostring(line), nil
end

function M.read_u64_file(path)
	local line, err = M.read_first_line(path)
	if not line then return nil, err end
	local n = tonumber((line:gsub('%s+', '')))
	if n == nil then
		return nil, 'not a number: ' .. tostring(line)
	end
	return n, nil
end

function M.file_exists(path)
	local f = io.open(path, 'rb')
	if f then
		f:close()
		return true
	end
	return false
end

function M.resolve_network_device(cur, host, link_id)
	if type(link_id) ~= 'string' or link_id == '' then
		return nil, 'link_id must be a non-empty string'
	end

	M.uci_try_load(cur, 'network')

	local dev = cur:get('network', link_id, 'device')
	if type(dev) == 'string' and dev ~= '' then
		return dev, nil
	end

	dev = cur:get('network', link_id, 'ifname')
	if type(dev) == 'string' and dev ~= '' then
		local resolved, err = M.resolve_ifname(host, dev)
		if resolved then return resolved, nil end
		return nil, err
	end

	return nil, 'no device/ifname configured for network.' .. tostring(link_id)
end

function M.read_sysfs_link_facts(dev)
	local base = '/sys/class/net/' .. tostring(dev)
	if not M.file_exists(base) then
		return nil, 'device not present in sysfs: ' .. tostring(dev)
	end

	local operstate = M.read_first_line(base .. '/operstate')
	local carrier_s = M.read_first_line(base .. '/carrier')
	local mtu_s     = M.read_first_line(base .. '/mtu')

	return {
		operstate = operstate and M.trim(operstate) or nil,
		carrier   = (carrier_s ~= nil) and (tonumber(M.trim(carrier_s)) == 1) or nil,
		mtu       = tonumber(M.trim(mtu_s or '')),
	}, nil
end

function M.read_ipv4_addr_for_device(dev)
	local ok, out = M.cmd_capture('ip', '-4', 'addr', 'show', 'dev', dev)
	if not ok then return nil end

	for _, line in ipairs(M.split_lines(out)) do
		local addr = line:match('%s+inet%s+([^%s]+)')
		if addr then return addr end
	end
	return nil
end

function M.read_default_route_for_device(dev)
	local ok, out = M.cmd_capture('ip', '-4', 'route', 'show', 'default', 'dev', dev)
	if not ok then return nil end

	for _, line in ipairs(M.split_lines(out)) do
		local via = line:match('via%s+([^%s]+)')
		if via then return via end
	end
	return nil
end

function M.list_link_ids_from_req(req)
	local out = {}

	if type(req) ~= 'table' then return out end

	if type(req.links) == 'table' then
		local n = 0
		for _, v in ipairs(req.links) do
			n = n + 1
			if type(v) == 'string' and v ~= '' then
				out[#out + 1] = v
			end
		end
		if n > 0 then
			return out
		end

		local ks = M.sorted_array_from_map_keys(req.links)
		for i = 1, #ks do
			if type(ks[i]) == 'string' and ks[i] ~= '' then
				out[#out + 1] = ks[i]
			end
		end
	end

	return out
end

function M.ping_rtt_ms_for_device(dev, reflector, timeout_s, count)
	timeout_s = tonumber(timeout_s) or 2
	count     = math.max(1, math.floor(tonumber(count) or 1))

	local ok, out, err = M.cmd_capture(
		'ping', '-4',
		'-I', tostring(dev),
		'-c', tostring(count),
		'-W', tostring(math.floor(timeout_s)),
		tostring(reflector)
	)
	if not ok then
		return nil, err
	end

	local minv, avgv = out:match('round%-trip min/avg/max = ([%d%.]+)/([%d%.]+)/')
	if avgv then
		return tonumber(avgv), nil
	end
	if minv then
		return tonumber(minv), nil
	end

	return nil, 'could not parse ping RTT'
end

function M.persist_mwan3_live_state(cur, req)
	if type(req) ~= 'table' then
		return nil, 'request must be a table'
	end

	local policy = req.policy or 'default'
	local members = req.members
	if type(policy) ~= 'string' or policy == '' then
		return nil, 'policy must be a non-empty string'
	end
	if type(members) ~= 'table' then
		return nil, 'members must be an array'
	end

	M.uci_try_load(cur, 'mwan3')

	local use = {}

	for i = 1, #members do
		local m = members[i]
		if not M.is_plain_table(m) then
			return nil, ('members[%d] must be a table'):format(i)
		end

		local link_id = m.link_id
		local metric  = tonumber(m.metric)
		local weight  = tonumber(m.weight)

		if type(link_id) ~= 'string' or link_id == '' then
			return nil, ('members[%d].link_id must be a non-empty string'):format(i)
		end
		if metric == nil then
			return nil, ('members[%d].metric must be a number'):format(i)
		end
		if weight == nil then
			return nil, ('members[%d].weight must be a number'):format(i)
		end

		metric = math.max(1, math.floor(metric))
		weight = math.max(1, math.floor(weight))

		local member_sec = M.sid(string.format('%s_m%d_w1', link_id, metric))

		cur:set('mwan3', member_sec, 'member')
		M.uci_set(cur, 'mwan3', member_sec, 'interface', M.sid(link_id))
		M.uci_set(cur, 'mwan3', member_sec, 'metric', metric)
		M.uci_set(cur, 'mwan3', member_sec, 'weight', weight)

		use[#use + 1] = member_sec
	end

	local policy_sec = M.sid(policy)
	cur:set('mwan3', policy_sec, 'policy')
	M.uci_set_list(cur, 'mwan3', policy_sec, 'use_member', use)
	M.uci_set(cur, 'mwan3', policy_sec, 'last_resort', req.last_resort or 'unreachable')

	cur:commit('mwan3')
	return true, nil
end

function M.reload_services(desired, host)
	local ok, err

	ok, err = M.cmd_ok('/etc/init.d/network', 'reload')
	if not ok then return nil, 'network reload failed: ' .. tostring(err) end

	ok, err = M.cmd_ok('/etc/init.d/dnsmasq', 'restart')
	if not ok then return nil, 'dnsmasq restart failed: ' .. tostring(err) end

	ok, err = M.cmd_ok('/etc/init.d/firewall', 'restart')
	if not ok then return nil, 'firewall restart failed: ' .. tostring(err) end

	if not (host and host.no_reload) and desired.multiwan then
		local ok1 = M.cmd_ok('sh', '-c', '[ -x /etc/init.d/mwan3 ]')
		if ok1 then
			ok, err = M.cmd_ok('/etc/init.d/mwan3', 'restart')
			if not ok then return nil, 'mwan3 restart failed: ' .. tostring(err) end
		else
			if host and host.log then
				host.log('info', { what = 'mwan3_not_applied', reason = 'init_script_missing' })
			end
		end
	end

	return true, nil
end

return M
