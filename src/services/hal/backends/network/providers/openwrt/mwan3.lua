-- services/hal/backends/network/providers/openwrt/mwan3.lua
-- MWAN3 UCI and live-weight helpers for the OpenWrt network provider.

local unpack = _G.unpack or rawget(table, 'unpack')

local M = {}

local function is_plain_table(v) return type(v) == 'table' and getmetatable(v) == nil end
local function sorted_keys(t)
	local ks = {}
	for k in pairs(t or {}) do ks[#ks + 1] = k end
	table.sort(ks, function(a, b) return tostring(a) < tostring(b) end)
	return ks
end
local function sid(v)
	local s = tostring(v or ''):gsub('[^%w_]', '_')
	if s == '' then s = '_' end
	return s
end
local function set_section(changes, config, section, stype)
	changes[#changes + 1] = { op = 'set', config = config, section = section, option = stype }
end
local function set_option(changes, config, section, option, value)
	if value == nil then return end
	changes[#changes + 1] = { op = 'set', config = config, section = section, option = option, value = value }
end

local function bool_uci(v) if v == nil then return nil end return v and '1' or '0' end

local function member_iface(id, spec)
	return spec.interface or spec.iface or spec.network_interface or spec.openwrt_interface or id
end

function M.build_changes(intent)
	local wan = is_plain_table(intent and intent.wan) and intent.wan or {}
	local members = is_plain_table(wan.members) and wan.members or {}
	local changes, known = {}, {}
	if wan.enabled == false or next(members) == nil then
		return changes, known, { enabled = false }
	end
	set_section(changes, 'mwan3', 'globals', 'globals')
	known.globals = true
	set_option(changes, 'mwan3', 'globals', 'mmx_mask', (wan.runtime and wan.runtime.mmx_mask) or '0x3F00')
	set_option(changes, 'mwan3', 'globals', 'logging', bool_uci(wan.runtime and wan.runtime.logging))

	local health = is_plain_table(wan.health) and wan.health or {}
	local member_sections = {}
	for _, mid in ipairs(sorted_keys(members)) do
		local m = is_plain_table(members[mid]) and members[mid] or {}
		local iface = member_iface(mid, m)
		local metric = math.floor(tonumber(m.metric or m.priority or 1) or 1)
		local weight = math.max(1, math.floor(tonumber(m.weight or 1) or 1))
		local ifsec = sid(iface)
		known[ifsec] = true
		set_section(changes, 'mwan3', ifsec, 'interface')
		set_option(changes, 'mwan3', ifsec, 'enabled', '1')
		set_option(changes, 'mwan3', ifsec, 'family', m.family or health.family or 'ipv4')
		set_option(changes, 'mwan3', ifsec, 'track_ip', m.track_ip or (m.health and m.health.track_ip) or health.track_ip)
		set_option(changes, 'mwan3', ifsec, 'reliability', m.reliability or health.reliability)
		set_option(changes, 'mwan3', ifsec, 'count', m.count or health.count)
		set_option(changes, 'mwan3', ifsec, 'timeout', m.timeout or health.timeout)
		set_option(changes, 'mwan3', ifsec, 'interval', m.interval or health.interval)
		set_option(changes, 'mwan3', ifsec, 'up', m.up or health.up)
		set_option(changes, 'mwan3', ifsec, 'down', m.down or health.down)
		local member_sec = sid(mid .. '_m' .. tostring(metric) .. '_w' .. tostring(weight))
		known[member_sec] = true
		set_section(changes, 'mwan3', member_sec, 'member')
		set_option(changes, 'mwan3', member_sec, 'interface', ifsec)
		set_option(changes, 'mwan3', member_sec, 'metric', metric)
		set_option(changes, 'mwan3', member_sec, 'weight', weight)
		member_sections[#member_sections + 1] = member_sec
	end
	table.sort(member_sections)
	local policy_name = (wan.load_balancing and wan.load_balancing.policy) or wan.policy_name or 'balanced'
	if policy_name == 'failover' or policy_name == 'weighted_failover' then policy_name = 'balanced' end
	policy_name = sid(policy_name)
	known[policy_name] = true
	set_section(changes, 'mwan3', policy_name, 'policy')
	set_option(changes, 'mwan3', policy_name, 'use_member', member_sections)
	set_option(changes, 'mwan3', policy_name, 'last_resort', wan.last_resort or 'unreachable')
	known.default_rule_v4 = true
	set_section(changes, 'mwan3', 'default_rule_v4', 'rule')
	set_option(changes, 'mwan3', 'default_rule_v4', 'dest_ip', '0.0.0.0/0')
	set_option(changes, 'mwan3', 'default_rule_v4', 'family', 'ipv4')
	set_option(changes, 'mwan3', 'default_rule_v4', 'use_policy', policy_name)
	return changes, known, { enabled = true, policy = policy_name, members = member_sections }
end

function M.persist_weights_op(mgr, req)
	local members = req and req.members or {}
	local live = { wan = { enabled = true, members = {} } }
	for i = 1, #members do
		local m = members[i]
		local id = m.id or m.link_id or m.interface or ('member' .. tostring(i))
		live.wan.members[id] = { interface = m.interface or m.iface or m.link_id, metric = m.metric or 1, weight = m.weight or 1 }
	end
	local changes = M.build_changes(live)
	return mgr:submit_op({ config = 'mwan3', changes = changes, restart_cmds = {} })
end

local function default_capture(argv)
	local fibers = require 'fibers'
	local exec = require 'fibers.io.exec'
	local cmd = exec.command(unpack(argv))
	local out, st, code, sig, err = fibers.perform(cmd:combined_output_op())
	local ok = (st == 'exited' and code == 0)
	if ok then return true, out or '', nil end
	local detail = err or out or ('status=' .. tostring(st))
	if st == 'exited' then
		detail = tostring(detail) .. ' (exit ' .. tostring(code) .. ')'
	elseif st == 'signalled' then
		detail = tostring(detail) .. ' (signal ' .. tostring(sig) .. ')'
	end
	return nil, out or '', detail
end

local function default_run(argv)
	local ok, _out, err = default_capture(argv)
	return ok == true, err
end

local function line_has(line, needle)
	return type(line) == 'string' and line:find(needle, 1, true) ~= nil
end

local function normalise_policy(policy)
	return sid(policy or 'balanced')
end

local function interface_from_member(m, index)
	if type(m) ~= 'table' then return nil end
	local iface = m.interface or m.iface or m.openwrt_interface or m.link_id or m.id
	if type(iface) ~= 'string' or iface == '' then return nil, 'members[' .. tostring(index) .. '] missing interface' end
	return sid(iface), nil
end

local function explicit_mark(m)
	if type(m) ~= 'table' then return nil end
	local v = m.mark or m.fwmark or m.xmark
	if type(v) == 'number' then return string.format('0x%x', v) end
	if type(v) == 'string' and v ~= '' then
		local mark = v:match('^(0x%x+)') or v:match('^(%d+)$')
		return mark
	end
	return nil
end

function M.parse_mangle_ruleset(text)
	local parsed = {
		mask = nil,
		iface_marks = {},
		policy_rules = {},
		chains = {},
	}
	for line in tostring(text or ''):gmatch('[^\r\n]+') do
		local chain = line:match('^:([^%s]+)')
		if chain then parsed.chains[chain] = true end
		local achain, rest = line:match('^%-A%s+([^%s]+)%s+(.+)$')
		if achain then
			local mask = rest:match('%-%-set%-xmark%s+0x%x+/(0x%x+)') or rest:match('%-%-mark%s+0x%x+/(0x%x+)')
			if mask and not parsed.mask then parsed.mask = mask end
			if achain:match('^mwan3_iface_in_') then
				local iface = rest:match('%-%-comment%s+"?([^"%s]+)"?%s+%-j%s+MARK')
				local mark = rest:match('%-%-set%-xmark%s+(0x%x+)/0x%x+')
				if iface and mark and iface ~= 'default' then parsed.iface_marks[sid(iface)] = mark end
			elseif achain:match('^mwan3_policy_') then
				parsed.policy_rules[achain] = parsed.policy_rules[achain] or {}
				parsed.policy_rules[achain][#parsed.policy_rules[achain] + 1] = line
			end
		end
	end
	parsed.mask = parsed.mask or '0x3f00'
	return parsed
end

local function normalise_members(members, parsed)
	local out, total = {}, 0
	for i = 1, #(members or {}) do
		local m = members[i]
		if type(m) == 'table' then
			local weight = math.floor(tonumber(m.weight or m.live_weight or 0) or 0)
			if weight > 0 then
				local iface, ierr = interface_from_member(m, i)
				if not iface then return nil, ierr end
				local mark = explicit_mark(m) or (parsed and parsed.iface_marks and parsed.iface_marks[iface])
				if not mark then return nil, 'no MWAN3 firewall mark found for interface ' .. tostring(iface) end
				total = total + weight
				out[#out + 1] = {
					interface = iface,
					weight = weight,
					metric = math.floor(tonumber(m.metric or 1) or 1),
					mark = mark,
				}
			end
		end
	end
	if #out == 0 then return nil, 'no positive-weight MWAN3 members supplied' end
	return out, nil, total
end

function M.build_policy_rule_argv(chain, mask, member, remaining_weight, include_statistic)
	local argv = { 'iptables', '-t', 'mangle', '-A', chain, '-m', 'mark', '--mark', '0x0/' .. mask }
	if include_statistic then
		local probability = member.weight / remaining_weight
		if probability < 0 then probability = 0 end
		if probability > 1 then probability = 1 end
		argv[#argv + 1] = '-m'; argv[#argv + 1] = 'statistic'
		argv[#argv + 1] = '--mode'; argv[#argv + 1] = 'random'
		argv[#argv + 1] = '--probability'; argv[#argv + 1] = string.format('%.11f', probability)
	end
	argv[#argv + 1] = '-m'; argv[#argv + 1] = 'comment'
	argv[#argv + 1] = '--comment'; argv[#argv + 1] = string.format('%s %d %d', member.interface, member.weight, remaining_weight)
	argv[#argv + 1] = '-j'; argv[#argv + 1] = 'MARK'
	argv[#argv + 1] = '--set-xmark'; argv[#argv + 1] = member.mark .. '/' .. mask
	return argv
end

function M.build_live_weight_commands(req, ruleset_text)
	req = req or {}
	local parsed = M.parse_mangle_ruleset(ruleset_text or '')
	local policy = normalise_policy(req.policy or 'balanced')
	local chain = 'mwan3_policy_' .. policy
	if not parsed.chains[chain] and not parsed.policy_rules[chain] then
		return nil, 'MWAN3 policy chain not found: ' .. chain
	end
	local members, merr, total = normalise_members(req.members, parsed)
	if not members then return nil, merr end
	local mask = tostring(req.mask or req.mmx_mask or parsed.mask or '0x3f00')
	local commands = { { 'iptables', '-t', 'mangle', '-F', chain } }
	local remaining = total
	for i = 1, #members do
		local member = members[i]
		commands[#commands + 1] = M.build_policy_rule_argv(chain, mask, member, remaining, i < #members)
		remaining = remaining - member.weight
	end
	return commands, nil, {
		policy = policy,
		chain = chain,
		mask = mask,
		members = members,
		total_weight = total,
	}
end

function M.apply_live_weights(req, opts)
	req = req or {}; opts = opts or {}
	if type(opts.apply_mwan_live_weights) == 'function' then
		local ok, err, detail = opts.apply_mwan_live_weights(req)
		return { ok = ok == true, changed = ok == true, applied = ok == true, err = err, detail = detail, backend = 'openwrt' }
	end

	local capture = opts.run_cmd_capture or default_capture
	local run_cmd = opts.run_cmd or default_run
	local ok, ruleset, err = capture({ 'iptables-save', '-t', 'mangle' })
	if ok ~= true then
		return { ok = false, err = 'failed to read MWAN3 mangle rules: ' .. tostring(err), backend = 'openwrt', code = 'mwan_live_weights_read_failed' }
	end
	local commands, cerr, detail = M.build_live_weight_commands(req, ruleset or '')
	if not commands then
		return { ok = false, err = cerr, backend = 'openwrt', code = 'mwan_live_weights_plan_failed' }
	end
	for i = 1, #commands do
		local rok, rerr = run_cmd(commands[i])
		if rok ~= true then
			return {
				ok = false,
				err = 'MWAN3 live weight command failed: ' .. tostring(rerr),
				backend = 'openwrt',
				code = 'mwan_live_weights_apply_failed',
				failed_command = commands[i],
				detail = detail,
			}
		end
	end
	return { ok = true, changed = true, applied = true, backend = 'openwrt', detail = detail, commands = commands }
end

return M
