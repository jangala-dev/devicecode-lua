-- services/hal/backends/network/providers/openwrt/tc_u32_shaper.lua
-- Prototype per-host shaping backend for OpenWrt.
--
-- This module is HAL-side only.  It deliberately accepts a semantic shaping
-- request and turns it into tc commands.  NET must not depend on this module.

local exec = require 'fibers.io.exec'
local file = require 'fibers.io.file'
local fibers = require 'fibers'

local perform = fibers.perform
local unpack = _G.unpack or rawget(table, 'unpack')

local M = {}

local function is_plain_table(v) return type(v) == 'table' and getmetatable(v) == nil end
local function sorted_keys(t)
	local ks = {}
	for k in pairs(t or {}) do ks[#ks + 1] = k end
	table.sort(ks, function(a, b) return tostring(a) < tostring(b) end)
	return ks
end

local function shell_escape(s)
	s = tostring(s or '')
	return "'" .. s:gsub("'", "'\\''") .. "'"
end

local function run_cmd(argv, runner)
	if type(runner) == 'function' then return runner(argv) end
	local cmd = exec.command(unpack(argv))
	local out, st, code, sig, err = perform(cmd:combined_output_op())
	if st == 'exited' and code == 0 then return true, out or '', nil end
	local detail = err or out or ('status=' .. tostring(st))
	if st == 'exited' then detail = tostring(detail) .. ' (exit ' .. tostring(code) .. ')'
	elseif st == 'signalled' then detail = tostring(detail) .. ' (signal ' .. tostring(sig) .. ')' end
	return nil, out or '', detail
end

local function try_cmd(argv, runner)
	local ok = run_cmd(argv, runner)
	return ok == true or ok == nil -- best effort; callers do not inspect try errors
end

local function tc_line(argv)
	if type(argv) ~= 'table' or argv[1] ~= 'tc' then return nil, 'argv must begin with tc' end
	local out = {}
	for i = 2, #argv do
		local token = tostring(argv[i])
		if token:find('[\r\n]') then return nil, 'newline in token' end
		out[#out + 1] = token
	end
	return table.concat(out, ' '), nil
end

local function run_tc_batch(cmds, runner)
	if #cmds == 0 then return true, '', nil end
	if type(runner) == 'function' then
		for i = 1, #cmds do
			local ok, _out, err = run_cmd(cmds[i], runner)
			if ok ~= true then return nil, '', err end
		end
		return true, '', nil
	end
	local lines = {}
	for i = 1, #cmds do
		local line, err = tc_line(cmds[i])
		if not line then return nil, '', err end
		lines[#lines + 1] = line
	end
	local tmp, terr = file.tmpfile('rw-r--r--')
	if not tmp then return nil, '', 'tmpfile failed: ' .. tostring(terr) end
	local path = tmp:filename()
	local ok, werr = tmp:write(table.concat(lines, '\n') .. '\n')
	if not ok then tmp:close(); return nil, '', 'batch write failed: ' .. tostring(werr) end
	local fok, ferr = tmp:flush()
	if not fok then tmp:close(); return nil, '', 'batch flush failed: ' .. tostring(ferr) end
	local bok, out, berr = run_cmd({ 'tc', '-batch', path })
	tmp:close()
	return bok, out, berr
end

local function classid(major, minor) return tostring(major) .. ':' .. tostring(minor) end
local function qdisc(major) return tostring(major) .. ':' end

local function htb_replace(dev, parent, cls, rate, ceil)
	return { 'tc', 'class', 'replace', 'dev', dev, 'parent', parent, 'classid', cls, 'htb', 'rate', tostring(rate), 'ceil', tostring(ceil or rate) }
end

local function fq_add(dev, parent, fq)
	fq = is_plain_table(fq) and fq or {}
	local argv = { 'tc', 'qdisc', 'add', 'dev', dev, 'parent', parent, 'fq_codel' }
	if fq.limit then argv[#argv+1] = 'limit'; argv[#argv+1] = tostring(fq.limit) end
	if fq.flows then argv[#argv+1] = 'flows'; argv[#argv+1] = tostring(fq.flows) end
	if fq.target then argv[#argv+1] = 'target'; argv[#argv+1] = tostring(fq.target) end
	if fq.interval then argv[#argv+1] = 'interval'; argv[#argv+1] = tostring(fq.interval) end
	if fq.memory_limit then argv[#argv+1] = 'memory_limit'; argv[#argv+1] = tostring(fq.memory_limit) end
	return argv
end

local function host_list(cfg)
	local out = {}
	local hosts = cfg.hosts or cfg.clients or {}
	if not is_plain_table(hosts) then return out end
	for _, ip in ipairs(sorted_keys(hosts)) do out[#out + 1] = { ip = ip, cfg = hosts[ip] or {} } end
	return out
end

local function apply_direction(link_id, iface, kind, cfg, runner)
	if cfg == nil or cfg.enabled == false then
		try_cmd({ 'tc', 'qdisc', 'del', 'dev', iface, kind == 'egress' and 'root' or 'ingress' }, runner)
		return true, nil, false
	end
	local dev = iface
	if kind == 'ingress' then
		local ifb = cfg.ifb or cfg.ingress_ifb or ('ifb_' .. tostring(iface):gsub('[^%w]', '_'))
		try_cmd({ 'ip', 'link', 'add', ifb, 'type', 'ifb' }, runner)
		local ok, _out, err = run_cmd({ 'ip', 'link', 'set', 'dev', ifb, 'up' }, runner)
		if ok ~= true then return nil, err or 'ifb up failed' end
		try_cmd({ 'tc', 'qdisc', 'del', 'dev', iface, 'ingress' }, runner)
		ok, _out, err = run_cmd({ 'tc', 'qdisc', 'add', 'dev', iface, 'handle', 'ffff:', 'ingress' }, runner)
		if ok ~= true then return nil, err or 'ingress qdisc failed' end
		ok, _out, err = run_cmd({ 'tc', 'filter', 'add', 'dev', iface, 'parent', 'ffff:', 'protocol', 'ip', 'u32', 'match', 'u32', '0', '0', 'action', 'mirred', 'egress', 'redirect', 'dev', ifb }, runner)
		if ok ~= true then return nil, err or 'ingress redirect failed' end
		dev = ifb
	else
		try_cmd({ 'tc', 'qdisc', 'del', 'dev', dev, 'root' }, runner)
	end

	local major = tonumber(cfg.major) or (kind == 'egress' and 10 or 20)
	local default_minor = tonumber(cfg.default_minor) or 10
	local base_minor = tonumber(cfg.base_minor) or 1000
	local root_rate = cfg.pool_rate or cfg.rate or '1gbit'
	local root_ceil = cfg.pool_ceil or cfg.ceil or root_rate
	local cmds = {
		{ 'tc', 'qdisc', 'add', 'dev', dev, 'root', 'handle', qdisc(major), 'htb', 'default', tostring(default_minor) },
		htb_replace(dev, qdisc(major), classid(major, default_minor), root_rate, root_ceil),
	}
	local fq = cfg.default_fq_codel or cfg.fq_codel
	if fq ~= false then cmds[#cmds + 1] = fq_add(dev, classid(major, default_minor), fq) end
	local hosts = host_list(cfg)
	for i = 1, #hosts do
		local h = hosts[i]
		local hcfg = is_plain_table(h.cfg) and h.cfg or {}
		local minor = base_minor + i
		local cid = classid(major, minor)
		cmds[#cmds + 1] = htb_replace(dev, qdisc(major), cid, hcfg.rate or cfg.host_rate or '1mbit', hcfg.ceil or cfg.host_ceil or hcfg.rate or cfg.host_rate or '1mbit')
		if hcfg.fq_codel ~= false then cmds[#cmds + 1] = fq_add(dev, cid, hcfg.fq_codel or cfg.fq_codel) end
		cmds[#cmds + 1] = { 'tc', 'filter', 'add', 'dev', dev, 'parent', qdisc(major), 'protocol', 'ip', 'prio', tostring(100 + i), 'u32', 'match', 'ip', (kind == 'egress' and (cfg.match or 'dst') or (cfg.match or 'src')), tostring(h.ip) .. '/32', 'flowid', cid }
	end
	local ok, _out, err = run_tc_batch(cmds, runner)
	if ok ~= true then return nil, err or 'tc batch failed' end
	return true, nil, #cmds > 0
end

function M.apply(req, opts)
	req = req or {}
	opts = opts or {}
	local links = req.links or req.policy or {}
	local runner = opts.run_cmd or req.run_cmd
	local applied, changed = {}, false
	for _, link_id in ipairs(sorted_keys(links)) do
		local spec = links[link_id]
		if is_plain_table(spec) then
			local iface = spec.iface or spec.device or spec.linux_interface or spec.interface
			if type(iface) ~= 'string' or iface == '' then
				return nil, 'shaping link ' .. tostring(link_id) .. ' missing iface/device'
			end
			local ok, err, ch = apply_direction(link_id, iface, 'egress', spec.egress, runner)
			if ok ~= true then return nil, 'egress ' .. tostring(link_id) .. ': ' .. tostring(err) end
			changed = changed or ch == true
			ok, err, ch = apply_direction(link_id, iface, 'ingress', spec.ingress, runner)
			if ok ~= true then return nil, 'ingress ' .. tostring(link_id) .. ': ' .. tostring(err) end
			changed = changed or ch == true
			applied[link_id] = { iface = iface, ok = true }
		end
	end
	return { ok = true, applied = true, changed = changed, backend = 'openwrt', links = applied }
end

function M.clear(req, opts)
	req = req or {}
	opts = opts or {}
	local runner = opts.run_cmd or req.run_cmd
	local links = req.links or {}
	for _, link_id in ipairs(sorted_keys(links)) do
		local spec = links[link_id]
		local iface = spec and (spec.iface or spec.device or spec.interface)
		if type(iface) == 'string' and iface ~= '' then
			try_cmd({ 'tc', 'qdisc', 'del', 'dev', iface, 'root' }, runner)
			try_cmd({ 'tc', 'qdisc', 'del', 'dev', iface, 'ingress' }, runner)
		end
	end
	return { ok = true, cleared = true, backend = 'openwrt' }
end

return M
