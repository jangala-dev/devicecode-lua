-- services/hal/backends/network/providers/openwrt/shaping_marks.lua
-- Devicecode-owned mangle marks for WAN client shaping with router exemption.

local fibers = require 'fibers'
local exec_mod = require 'fibers.io.exec'
local bit = rawget(_G, 'bit') or rawget(_G, 'bit32')

local function band(a, b)
	if bit and type(bit.band) == 'function' then return bit.band(a, b) end
	local res, bitv = 0, 1
	a = math.floor(tonumber(a) or 0); b = math.floor(tonumber(b) or 0)
	while a > 0 or b > 0 do
		local aa, bb = a % 2, b % 2
		if aa == 1 and bb == 1 then res = res + bitv end
		a = math.floor(a / 2); b = math.floor(b / 2); bitv = bitv * 2
	end
	return res
end

local M = {}

local DEFAULT_MASK = '0x00f00000'
local DEFAULT_CONTROL = '0x00100000'
local DEFAULT_CLIENT = '0x00200000'

local function is_plain_table(x) return type(x) == 'table' and getmetatable(x) == nil end

local function exec_spec(argv, opts)
	opts = opts or {}
	local spec = { stdin = opts.stdin or 'null', stdout = opts.stdout or 'pipe', stderr = opts.stderr or 'stdout' }
	for i = 1, #argv do spec[i] = argv[i] end
	return spec
end

local function hex_number(v)
	if type(v) == 'number' then return v end
	if type(v) ~= 'string' then return nil end
	local hx = v:match('^%s*0x(%x+)%s*$')
	if hx then return tonumber(hx, 16) end
	local dec = v:match('^%s*(%d+)%s*$')
	return dec and tonumber(dec) or nil
end

local function mark_spec(req)
	local marks = is_plain_table(req and req.marks) and req.marks or {}
	local mask = marks.mask or req.mark_mask or DEFAULT_MASK
	local control = marks.control or req.control_mark or DEFAULT_CONTROL
	local client = marks.client or req.client_mark or DEFAULT_CLIENT
	return tostring(mask), tostring(control), tostring(client)
end

local function quote_restore_arg(s)
	s = tostring(s or '')
	if s:find('[\r\n]') then error('newline in iptables-restore argument') end
	if s:find('%s') or s:find('"') then return '"' .. s:gsub('(["\\])', '\\%1') .. '"' end
	return s
end

local function restore_line(argv)
	local out = {}
	for i = 1, #argv do out[i] = quote_restore_arg(argv[i]) end
	return table.concat(out, ' ')
end

function M.default_marks()
	return { mask = DEFAULT_MASK, control = DEFAULT_CONTROL, client = DEFAULT_CLIENT }
end

function M.validate_marks(req, mwan_mask)
	local mask, control, client = mark_spec(req)
	local mn, cn, cln = hex_number(mask), hex_number(control), hex_number(client)
	if not (mn and cn and cln) then return nil, 'invalid shaping mark values' end
	if cn == cln then return nil, 'control and client marks must differ' end
	if mwan_mask then
		local mm = hex_number(mwan_mask)
		if mm and band(mn, mm) ~= 0 then return nil, 'shaping mark mask overlaps MWAN mask' end
	end
	return { mask = mask, control = control, client = client }, nil
end

local function link_iface(link)
	return link.iface or link.device or link.interface or link.linux_interface
end

function M.build_restore(req)
	req = req or {}
	local mask, control, client = mark_spec(req)
	local lines = { '*mangle' }
	local outputs, forwards = {}, {}
	for link_id, link in pairs(req.links or {}) do
		if is_plain_table(link) and link.enabled ~= false and link.kind == 'wan_mark' then
			local iface = link_iface(link)
			if type(iface) == 'string' and iface ~= '' then
				outputs[#outputs + 1] = iface
				forwards[#forwards + 1] = iface
			end
		end
	end
	table.sort(outputs); table.sort(forwards)
	lines[#lines + 1] = ':DEVICECODE_SHAPING_OUTPUT - [0:0]'
	lines[#lines + 1] = ':DEVICECODE_SHAPING_FORWARD - [0:0]'
	lines[#lines + 1] = '-F DEVICECODE_SHAPING_OUTPUT'
	lines[#lines + 1] = '-F DEVICECODE_SHAPING_FORWARD'
	for _, iface in ipairs(outputs) do
		lines[#lines + 1] = restore_line({ '-A', 'DEVICECODE_SHAPING_OUTPUT', '-o', iface, '-m', 'comment', '--comment', 'devicecode-shaping router exempt', '-j', 'MARK', '--set-xmark', control .. '/' .. mask })
		lines[#lines + 1] = restore_line({ '-A', 'DEVICECODE_SHAPING_OUTPUT', '-o', iface, '-m', 'comment', '--comment', 'devicecode-shaping save router mark', '-j', 'CONNMARK', '--save-mark', '--mask', mask })
	end
	for _, iface in ipairs(forwards) do
		lines[#lines + 1] = restore_line({ '-A', 'DEVICECODE_SHAPING_FORWARD', '-o', iface, '-m', 'comment', '--comment', 'devicecode-shaping client', '-j', 'MARK', '--set-xmark', client .. '/' .. mask })
		lines[#lines + 1] = restore_line({ '-A', 'DEVICECODE_SHAPING_FORWARD', '-o', iface, '-m', 'comment', '--comment', 'devicecode-shaping save client mark', '-j', 'CONNMARK', '--save-mark', '--mask', mask })
	end
	lines[#lines + 1] = 'COMMIT'
	lines[#lines + 1] = ''
	return table.concat(lines, '\n'), { mask = mask, control = control, client = client }
end


local function call_runner(run_cmd, argv)
	if type(run_cmd) ~= 'function' then return true end
	local ok = run_cmd(argv)
	return ok == true
end

local function ensure_jumps(run_cmd)
	if type(run_cmd) ~= 'function' then return true end
	call_runner(run_cmd, { 'iptables', '-t', 'mangle', '-N', 'DEVICECODE_SHAPING_OUTPUT' })
	call_runner(run_cmd, { 'iptables', '-t', 'mangle', '-N', 'DEVICECODE_SHAPING_FORWARD' })
	if not call_runner(run_cmd, { 'iptables', '-t', 'mangle', '-C', 'OUTPUT', '-j', 'DEVICECODE_SHAPING_OUTPUT' }) then
		call_runner(run_cmd, { 'iptables', '-t', 'mangle', '-A', 'OUTPUT', '-j', 'DEVICECODE_SHAPING_OUTPUT' })
	end
	if not call_runner(run_cmd, { 'iptables', '-t', 'mangle', '-C', 'FORWARD', '-j', 'DEVICECODE_SHAPING_FORWARD' }) then
		call_runner(run_cmd, { 'iptables', '-t', 'mangle', '-A', 'FORWARD', '-j', 'DEVICECODE_SHAPING_FORWARD' })
	end
	return true
end

local function default_restore(content)
	local cmd = exec_mod.command(exec_spec({ 'iptables-restore', '--noflush' }, { stdin = 'pipe' }))
	local stdin, serr = cmd:stdin_stream()
	if not stdin then return nil, serr or 'failed to open iptables-restore stdin' end
	local ok, werr = stdin:write(content or '')
	if not ok then
		pcall(function() stdin:terminate('iptables-restore write failed') end)
		fibers.perform(cmd:shutdown_op(0.2))
		return nil, 'failed to write iptables-restore input: ' .. tostring(werr)
	end
	stdin:close()
	local out, st, code, sig, err = fibers.perform(cmd:combined_output_op())
	if st == 'exited' and code == 0 then return true, nil, out or '' end
	local detail = err or out or ('status=' .. tostring(st))
	if st == 'exited' then detail = tostring(detail) .. ' (exit ' .. tostring(code) .. ')'
	elseif st == 'signalled' then detail = tostring(detail) .. ' (signal ' .. tostring(sig) .. ')' end
	return nil, detail, out or ''
end

function M.apply(req, opts)
	opts = opts or {}
	local restore, marks = M.build_restore(req or {})
	if not restore or restore == '' then return { ok = true, applied = false, marks = marks, backend = 'openwrt' } end
	ensure_jumps(opts.run_cmd)
	local runner = opts.run_restore or opts.restore
	if type(runner) == 'function' then
		local ok, err, out = runner(restore)
		return { ok = ok == true, applied = ok == true, err = err, output = out, restore = restore, marks = marks, backend = 'openwrt' }
	end
	local ok, err, out = default_restore(restore)
	return { ok = ok == true, applied = ok == true, err = err, output = out, restore = restore, marks = marks, backend = 'openwrt' }
end

return M
