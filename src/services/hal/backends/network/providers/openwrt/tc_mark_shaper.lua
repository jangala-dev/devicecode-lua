-- services/hal/backends/network/providers/openwrt/tc_mark_shaper.lua
-- Mark-based WAN shaper.  The mangle/connmark contract is owned by shaping_marks.lua.

local fibers = require 'fibers'
local exec_mod = require 'fibers.io.exec'

local M = {}
local ACTIVE_RUN_CMD = nil

local function is_plain_table(x) return type(x) == 'table' and getmetatable(x) == nil end
local function ifb_name(iface) return 'ifb_' .. tostring(iface or ''):gsub('[^%w]', '_'):sub(1, 11) end
local function exec_spec(argv) local spec = { stdin = 'null', stdout = 'pipe', stderr = 'stdout' }; for i=1,#argv do spec[i]=argv[i] end; return spec end
local function classid(minor) return '1:' .. tostring(minor) end

local function run_cmd(argv)
	if type(ACTIVE_RUN_CMD) == 'function' then
		local ok, out, err, code = ACTIVE_RUN_CMD(argv)
		if ok == true then return true, out or '', err, code or 0 end
		return nil, out or '', err or out or 'command failed', code
	end
	local cmd = exec_mod.command(exec_spec(argv))
	local out, st, code = fibers.perform(cmd:combined_output_op())
	if st == 'exited' and code == 0 then return true, out or '', nil, code end
	return nil, out or '', out or ('exit ' .. tostring(code)), code
end

local function try_cmd(argv) run_cmd(argv); return true end
local function must_cmd(argv, label)
	local ok, out, err, code = run_cmd(argv)
	if ok == true then return true, nil end
	return nil, (label or table.concat(argv, ' ')) .. ': ' .. tostring(err or out or ('exit ' .. tostring(code)))
end

local function append_fq(argv, fq)
	fq = fq or {}
	argv[#argv + 1] = 'fq_codel'
	if fq.limit then argv[#argv+1]='limit'; argv[#argv+1]=tostring(fq.limit) end
	if fq.flows then argv[#argv+1]='flows'; argv[#argv+1]=tostring(fq.flows) end
	if fq.quantum then argv[#argv+1]='quantum'; argv[#argv+1]=tostring(fq.quantum) end
	if fq.target then argv[#argv+1]='target'; argv[#argv+1]=tostring(fq.target) end
	if fq.interval then argv[#argv+1]='interval'; argv[#argv+1]=tostring(fq.interval) end
	if fq.memory_limit then argv[#argv+1]='memory_limit'; argv[#argv+1]=tostring(fq.memory_limit) end
	if fq.ecn == false then argv[#argv+1]='noecn' elseif fq.ecn ~= nil then argv[#argv+1]='ecn' end
end

local function class_argv(dev, parent, minor, cfg)
	cfg = cfg or {}
	local rate = tostring(cfg.rate or cfg.limit or '1gbit')
	local ceil = tostring(cfg.ceil or cfg.limit or rate)
	local argv = { 'tc', 'class', 'replace', 'dev', dev, 'parent', parent, 'classid', classid(minor), 'htb', 'rate', rate, 'ceil', ceil }
	if cfg.burst then argv[#argv+1]='burst'; argv[#argv+1]=tostring(cfg.burst) end
	if cfg.cburst then argv[#argv+1]='cburst'; argv[#argv+1]=tostring(cfg.cburst) end
	if cfg.prio then argv[#argv+1]='prio'; argv[#argv+1]=tostring(cfg.prio) end
	return argv
end

local function fq_argv(dev, minor, fq)
	local argv = { 'tc', 'qdisc', 'replace', 'dev', dev, 'parent', classid(minor) }
	append_fq(argv, fq)
	return argv
end

local function ensure_root(dev, cfg)
	try_cmd({ 'tc', 'qdisc', 'del', 'dev', dev, 'root' })
	local ok, err = must_cmd({ 'tc', 'qdisc', 'add', 'dev', dev, 'root', 'handle', '1:', 'htb', 'default', '20' }, 'add root htb ' .. dev)
	if not ok then return nil, err end
	ok, err = must_cmd(class_argv(dev, '1:', 1, cfg.root or { rate = '1gbit', ceil = '1gbit' }), 'root class ' .. dev)
	if not ok then return nil, err end
	ok, err = must_cmd(class_argv(dev, '1:1', 10, cfg.control or { rate = '1gbit', ceil = '1gbit' }), 'control class ' .. dev)
	if not ok then return nil, err end
	ok, err = must_cmd(class_argv(dev, '1:1', 20, cfg.client or { rate = cfg.limit or '1gbit', ceil = cfg.limit or '1gbit' }), 'client class ' .. dev)
	if not ok then return nil, err end
	must_cmd(fq_argv(dev, 10, cfg.control_fq_codel or cfg.fq_codel), 'control fq ' .. dev)
	return must_cmd(fq_argv(dev, 20, cfg.client_fq_codel or cfg.fq_codel), 'client fq ' .. dev)
end

local function add_mark_filters(dev, marks)
	marks = marks or {}
	local control = tostring(marks.control or '0x00100000')
	local client = tostring(marks.client or '0x00200000')
	local mask = tostring(marks.mask or '0x00f00000')
	try_cmd({ 'tc', 'filter', 'del', 'dev', dev, 'parent', '1:', 'protocol', 'ip', 'prio', '10' })
	try_cmd({ 'tc', 'filter', 'del', 'dev', dev, 'parent', '1:', 'protocol', 'ip', 'prio', '20' })
	local ok, err = must_cmd({ 'tc', 'filter', 'add', 'dev', dev, 'parent', '1:', 'protocol', 'ip', 'prio', '10', 'handle', control .. '/' .. mask, 'fw', 'flowid', '1:10' }, 'control fw filter ' .. dev)
	if not ok then return nil, err end
	return must_cmd({ 'tc', 'filter', 'add', 'dev', dev, 'parent', '1:', 'protocol', 'ip', 'prio', '20', 'handle', client .. '/' .. mask, 'fw', 'flowid', '1:20' }, 'client fw filter ' .. dev)
end

local function ensure_ingress_redirect(iface, ifb, marks)
	try_cmd({ 'ip', 'link', 'add', ifb, 'type', 'ifb' })
	local ok, err = must_cmd({ 'ip', 'link', 'set', 'dev', ifb, 'up' }, 'ifb up')
	if not ok then return nil, err end
	try_cmd({ 'tc', 'qdisc', 'del', 'dev', iface, 'ingress' })
	ok, err = must_cmd({ 'tc', 'qdisc', 'add', 'dev', iface, 'handle', 'ffff:', 'ingress' }, 'add ingress ' .. iface)
	if not ok then return nil, err end
	local mask = tostring((marks and marks.mask) or '0x00f00000')
	-- ctinfo restores the saved connmark into skb mark before the packet is redirected to the IFB.
	return must_cmd({ 'tc', 'filter', 'add', 'dev', iface, 'parent', 'ffff:', 'protocol', 'ip', 'prio', '1', 'u32', 'match', 'u32', '0', '0', 'action', 'ctinfo', 'cpmark', mask, 'action', 'mirred', 'egress', 'redirect', 'dev', ifb }, 'ingress ctinfo redirect ' .. iface)
end

local function apply_one(link, marks)
	local iface = link.iface or link.device or link.interface or link.linux_interface
	if type(iface) ~= 'string' or iface == '' then return nil, 'wan_mark link missing iface' end
	if link.egress ~= nil and link.egress.enabled ~= false then
		local ok, err = ensure_root(iface, link.egress)
		if not ok then return nil, 'egress: ' .. tostring(err) end
		ok, err = add_mark_filters(iface, marks)
		if not ok then return nil, 'egress filters: ' .. tostring(err) end
	end
	if link.ingress ~= nil and link.ingress.enabled ~= false then
		local ifb = link.ingress.ifb or link.ifb or ifb_name(iface)
		local ok, err = ensure_ingress_redirect(iface, ifb, marks)
		if not ok then return nil, 'ingress redirect: ' .. tostring(err) end
		ok, err = ensure_root(ifb, link.ingress)
		if not ok then return nil, 'ingress ifb: ' .. tostring(err) end
		ok, err = add_mark_filters(ifb, marks)
		if not ok then return nil, 'ingress filters: ' .. tostring(err) end
	end
	return true, nil
end

function M.apply(req, opts)
	opts = opts or {}; req = req or {}
	local previous = ACTIVE_RUN_CMD
	ACTIVE_RUN_CMD = opts.run_cmd or req.run_cmd
	local marks = req.marks or { mask = '0x00f00000', control = '0x00100000', client = '0x00200000' }
	local applied = {}
	for id, link in pairs(req.links or {}) do
		if is_plain_table(link) and link.kind == 'wan_mark' and link.enabled ~= false then
			local ok, err = apply_one(link, marks)
			if ok ~= true then ACTIVE_RUN_CMD = previous; return { ok = false, err = tostring(id) .. ': ' .. tostring(err), backend = 'openwrt' } end
			applied[id] = { ok = true, iface = link.iface or link.device or link.interface, kind = 'wan_mark' }
		end
	end
	ACTIVE_RUN_CMD = previous
	return { ok = true, applied = true, changed = next(applied) ~= nil, links = applied, backend = 'openwrt' }
end

return M
