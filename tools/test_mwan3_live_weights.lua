#!/usr/bin/env lua
--
-- test_mwan3_live_weights_daemon.lua
--
-- Event-driven dry-run daemon for live mwan3 policy-chain rewrites.
--
-- Behaviour
--   * reads events from stdin, or from a FIFO path given as arg[1]
--   * debounces bursts of events
--   * recomputes the desired policy chain on each settled burst
--   * prints a new rewrite plan only when the effective state changes
--
-- Intended event format
--   ACTION=connected INTERFACE=wan DEVICE=eth0
--   ACTION=disconnected INTERFACE=wanb DEVICE=wwan0
--   ACTION=ifup INTERFACE=wan
--   ACTION=ifdown INTERFACE=wanb
--   RECOMPUTE=1
--
-- Environment
--   MWAN3_POLICY         policy to explore; default "balanced"
--   MWAN3_INTERFACES     fallback iface list; default "wan,wanb"
--   MWAN3_MMX_MASK       optional override; else from UCI/current chain; default "0x3f00"
--   MWAN3_DEBOUNCE_SEC   debounce window; default 1.0
--
-- Optional per-interface overrides
--   MWAN3_WEIGHT_<IFACE>   desired weight override
--   MWAN3_MARK_<IFACE>     desired mark override
--
-- Usage
--   stdin:
--     ubus listen network.interface | luajit test_mwan3_live_weights_daemon.lua
--
--   FIFO:
--     mkfifo /tmp/mwan3-events
--     luajit test_mwan3_live_weights_daemon.lua /tmp/mwan3-events
--     printf 'ACTION=connected INTERFACE=wan DEVICE=eth0\n' > /tmp/mwan3-events

local fibers   = require 'fibers'
local mailbox  = require 'fibers.mailbox'
local sleep    = require 'fibers.sleep'
local exec_mod = require 'fibers.io.exec'
local file_mod = require 'fibers.io.file'
local op       = require 'fibers.op'

local perform = fibers.perform

--------------------------------------------------------------------------------
-- Small helpers
--------------------------------------------------------------------------------

local function trim(s)
	if s == nil then return nil end
	return (tostring(s):gsub('^%s+', ''):gsub('%s+$', ''))
end

local function split_csv(s)
	local out = {}
	for part in tostring(s or ''):gmatch('[^,%s]+') do
		out[#out + 1] = part
	end
	return out
end

local function env(name, default)
	local v = os.getenv(name)
	if v == nil or v == '' then return default end
	return v
end

local function env_num(name, default)
	local v = tonumber(os.getenv(name) or '')
	if v == nil then return default end
	return v
end

local function env_key_for_iface(prefix, iface)
	local k = tostring(iface):upper():gsub('[^A-Z0-9]', '_')
	return prefix .. '_' .. k
end

local function env_weight_for_iface(iface)
	local v = tonumber(os.getenv(env_key_for_iface('MWAN3_WEIGHT', iface)) or '')
	if v == nil then return nil end
	return math.max(1, math.floor(v))
end

local function env_mark_for_iface(iface)
	local v = os.getenv(env_key_for_iface('MWAN3_MARK', iface))
	if v == nil or v == '' then return nil end
	return v:lower()
end

local function shallow_copy(t)
	local out = {}
	for k, v in pairs(t or {}) do out[k] = v end
	return out
end

local function now_wall()
	return os.date('%Y-%m-%d %H:%M:%S')
end

local function lower_hexes(s)
	return (tostring(s):gsub('0x[%da-fA-F]+', function(h) return h:lower() end))
end

local function parse_set_xmark(s)
	local mark, mask = tostring(s or ''):match('^([^/]+)/([^/]+)$')
	if not mark then return nil, nil end
	return mark:lower(), mask:lower()
end

local function read_text_file(path)
	local f, err = file_mod.open(path, 'r')
	if not f then return nil, err end
	local data, rerr = f:read_all()
	f:close()
	if rerr ~= nil then return nil, rerr end
	return data or '', nil
end

local function run_capture(...)
	local cmd = exec_mod.command(...)
	local out, st, code, _, err = perform(cmd:combined_output_op())
	local ok = (st == 'exited' and code == 0)
	return ok, out or '', err, code
end

local function printf(...)
	io.stdout:write(string.format(...))
	io.stdout:write('\n')
	io.stdout:flush()
end

--------------------------------------------------------------------------------
-- Event parsing
--------------------------------------------------------------------------------

local function parse_kv_line(line)
	local ev = { raw = line }
	line = trim(line or '')
	if line == '' then return ev end

	for k, v in line:gmatch('([%w_]+)=([^%s]+)') do
		ev[k] = v
	end

	-- Convenience normalisation for common keys.
	if ev.ACTION then ev.action = ev.ACTION end
	if ev.INTERFACE then ev.interface = ev.INTERFACE end
	if ev.DEVICE then ev.device = ev.DEVICE end

	return ev
end

--------------------------------------------------------------------------------
-- Read tracking / status
--------------------------------------------------------------------------------

local function read_tracking_status_dir(iface)
	local path = '/var/run/mwan3track/' .. tostring(iface) .. '/STATUS'
	local txt = read_text_file(path)
	if not txt then return nil end
	return trim(txt)
end

local function parse_mwan3_interface_status(status_text)
	local out = {}
	local in_section = false

	for line in tostring(status_text or ''):gmatch('[^\n]+') do
		if line:match('^Interface status:') then
			in_section = true
		elseif in_section and line:match('^Current ipv4 policies:') then
			break
		elseif in_section then
			local iface, state = line:match('^%s*interface%s+([%w%._%-]+)%s+is%s+([%w_]+)')
			if iface and state then
				out[iface] = state
			end
		end
	end

	return out
end

--------------------------------------------------------------------------------
-- Parse UCI
--------------------------------------------------------------------------------

local function parse_uci_show_mwan3(txt)
	local cfg = {
		sections = {},
		globals  = {},
		members  = {},
	}

	local function ensure_section(name)
		local s = cfg.sections[name]
		if not s then
			s = { name = name, type = nil, opts = {} }
			cfg.sections[name] = s
		end
		return s
	end

	for line in tostring(txt or ''):gmatch('[^\n]+') do
		line = trim(line)
		if line ~= '' then
			local secname, sectype = line:match("^mwan3%.([^.=]+)=([%w_%-]+)$")
			if secname and sectype then
				local s = ensure_section(secname)
				s.type = sectype
			else
				local sname, opt, val = line:match("^mwan3%.([^.=]+)%.([%w_%-]+)='(.*)'$")
				if sname and opt then
					local s = ensure_section(sname)
					local cur = s.opts[opt]
					if cur == nil then
						s.opts[opt] = val
					elseif type(cur) == 'table' then
						cur[#cur + 1] = val
					else
						s.opts[opt] = { cur, val }
					end
				end
			end
		end
	end

	for _, s in pairs(cfg.sections) do
		if s.type == 'globals' then
			cfg.globals = shallow_copy(s.opts)
		elseif s.type == 'member' then
			cfg.members[s.name] = shallow_copy(s.opts)
		end
	end

	return cfg
end

local function as_list(v)
	if v == nil then return {} end
	if type(v) == 'table' then return v end
	return { v }
end

local function find_policy_section(uci_cfg, policy_name)
	if not uci_cfg or not uci_cfg.sections then return nil end

	local direct = uci_cfg.sections[policy_name]
	if direct and direct.type == 'policy' then
		return direct
	end

	for _, s in pairs(uci_cfg.sections) do
		if s.type == 'policy' then
			local n = s.opts and s.opts.name or nil
			if n == policy_name then return s end
		end
	end

	return nil
end

local function discover_policy_members_from_uci(uci_cfg, policy_name)
	local sec = find_policy_section(uci_cfg, policy_name)
	if not sec then return nil, 'policy not found in UCI' end

	local member_names = as_list(sec.opts.use_member)
	local out = {}

	for i = 1, #member_names do
		local mname = member_names[i]
		local m = uci_cfg.members[mname]
		if m then
			local iface  = m.interface
			local metric = tonumber(m.metric or '1') or 1
			local weight = tonumber(m.weight or '1') or 1
			if type(iface) == 'string' and iface ~= '' then
				out[#out + 1] = {
					member = mname,
					iface  = iface,
					metric = metric,
					weight = weight,
				}
			end
		end
	end

	if #out == 0 then
		return nil, 'policy found, but no members resolved'
	end

	return out, nil
end

--------------------------------------------------------------------------------
-- Read mangle table / current chain
--------------------------------------------------------------------------------

local function get_mangle_rules_text()
	local ok, out = run_capture('iptables-save', '-t', 'mangle')
	if ok then return out, 'iptables-save -t mangle' end

	ok, out = run_capture('iptables-save')
	if ok then return out, 'iptables-save' end

	ok, out = run_capture('iptables', '-t', 'mangle', '-S')
	if ok then return out, 'iptables -t mangle -S' end

	return nil, 'no iptables mangle dump available'
end

local function extract_policy_chain_lines(mangle_text, policy)
	local chain = 'mwan3_policy_' .. tostring(policy)
	local lines = {}

	for line in tostring(mangle_text or ''):gmatch('[^\n]+') do
		line = trim(line)
		if line:match('^-A%s+' .. chain .. '%s') then
			lines[#lines + 1] = line
		end
	end

	return lines
end

local function parse_policy_chain_members(current_chain_lines, policy)
	local chain = 'mwan3_policy_' .. tostring(policy)
	local out = {}

	for i = 1, #current_chain_lines do
		local line = current_chain_lines[i]
		if line:match('^-A%s+' .. chain .. '%s') then
			local comment = line:match('%-%-comment%s+"([^"]+)"')
			local iface = comment and comment:match('^([%w%._%-]+)')
			local setx = line:match('%-%-set%-xmark%s+([^%s]+)')
			local mark, mask = parse_set_xmark(setx)
			local prob = line:match('%-%-probability%s+([%d%.]+)')

			if iface and mark then
				out[#out + 1] = {
					iface = iface,
					mark  = mark,
					mask  = mask,
					prob  = prob and tonumber(prob) or nil,
					line  = line,
				}
			end
		end
	end

	return out
end

local function marks_from_policy_chain(current_chain_lines, policy)
	local members = parse_policy_chain_members(current_chain_lines, policy)
	local out = {}
	for i = 1, #members do
		out[members[i].iface] = members[i].mark
	end
	return out, members
end

--------------------------------------------------------------------------------
-- Build desired active set
--------------------------------------------------------------------------------

local function pick_effective_members_from_uci(policy_members, effective_state)
	local best_metric = nil

	for i = 1, #policy_members do
		local m = policy_members[i]
		if effective_state[m.iface] == 'online' then
			if best_metric == nil or m.metric < best_metric then
				best_metric = m.metric
			end
		end
	end

	local out = {}
	if best_metric == nil then return out, nil end

	for i = 1, #policy_members do
		local m = policy_members[i]
		if effective_state[m.iface] == 'online' and m.metric == best_metric then
			out[#out + 1] = shallow_copy(m)
		end
	end

	return out, best_metric
end

local function pick_effective_members_from_current_chain(current_members, effective_state)
	local out = {}
	for i = 1, #current_members do
		local m = current_members[i]
		if effective_state[m.iface] == 'online' then
			out[#out + 1] = {
				member = m.iface,
				iface  = m.iface,
				metric = 1,
				weight = 1,
				mark   = m.mark,
			}
		end
	end
	return out
end

local function apply_env_overrides(members, discovered_marks)
	local out = {}

	for i = 1, #members do
		local m = shallow_copy(members[i])

		local w = env_weight_for_iface(m.iface)
		if w ~= nil then
			m.weight = w
		else
			m.weight = math.max(1, tonumber(m.weight) or 1)
		end

		local mk = env_mark_for_iface(m.iface)
			or m.mark
			or (discovered_marks and discovered_marks[m.iface])
			or ('<mark_' .. tostring(m.iface) .. '>')

		m.mark = tostring(mk):lower()
		out[#out + 1] = m
	end

	return out
end

--------------------------------------------------------------------------------
-- Generate desired rules
--------------------------------------------------------------------------------

local function member_probabilities(members)
	local out = {}
	local total = 0

	for i = 1, #members do
		total = total + math.max(1, tonumber(members[i].weight) or 1)
	end

	local remaining = total
	for i = 1, #members do
		local w = math.max(1, tonumber(members[i].weight) or 1)
		local rec = shallow_copy(members[i])
		rec.final = (i == #members)
		rec.prob  = nil

		if i < #members then
			rec.prob = w / remaining
			remaining = remaining - w
		end

		out[#out + 1] = rec
	end

	return out
end

local function fmt_prob(p)
	if p == nil then return nil end
	return string.format('%.6f', p)
end

local function build_desired_chain_lines(policy, mmx_mask, members)
	local chain = 'mwan3_policy_' .. tostring(policy)
	local probs = member_probabilities(members)
	local lines = {}

	for i = 1, #probs do
		local m = probs[i]
		if m.final then
			lines[#lines + 1] = string.format(
				'-A %s -m mark --mark 0x0/%s -j MARK --set-xmark %s/%s',
				chain, mmx_mask, m.mark, mmx_mask
			)
		else
			lines[#lines + 1] = string.format(
				'-A %s -m mark --mark 0x0/%s -m statistic --mode random --probability %s -j MARK --set-xmark %s/%s',
				chain, mmx_mask, fmt_prob(m.prob), m.mark, mmx_mask
			)
		end
	end

	return lines
end

local function build_iptables_commands(policy, mmx_mask, members)
	local chain = 'mwan3_policy_' .. tostring(policy)
	local body = build_desired_chain_lines(policy, mmx_mask, members)
	local out = {}

	out[#out + 1] = string.format('iptables -t mangle -F %s', chain)
	for i = 1, #body do
		local suffix = body[i]:gsub('^-A%s+' .. chain .. '%s+', '')
		out[#out + 1] = string.format('iptables -t mangle -A %s %s', chain, suffix)
	end

	return out
end

local function build_iptables_restore_snippet(policy, mmx_mask, members)
	local chain = 'mwan3_policy_' .. tostring(policy)
	local body  = build_desired_chain_lines(policy, mmx_mask, members)
	local lines = {}

	lines[#lines + 1] = '*mangle'
	lines[#lines + 1] = ':' .. chain .. ' - [0:0]'
	lines[#lines + 1] = '-F ' .. chain
	for i = 1, #body do
		lines[#lines + 1] = body[i]
	end
	lines[#lines + 1] = 'COMMIT'

	return table.concat(lines, '\n')
end

--------------------------------------------------------------------------------
-- Semantic diff / signatures
--------------------------------------------------------------------------------

local function normalise_rule_line(s)
	s = trim(s or '')
	s = lower_hexes(s)
	s = s:gsub('%s+%-m%s+comment%s+%-%-comment%s+"[^"]+"', '')
	s = s:gsub('%-%-probability%s+([%d%.]+)', function(num)
		local n = tonumber(num)
		if not n then return '--probability ' .. tostring(num) end
		return '--probability ' .. string.format('%.6f', n)
	end)
	s = s:gsub('%s+', ' ')
	return s
end

local function signature_from_snapshot(snap)
	local parts = {}

	parts[#parts + 1] = 'policy=' .. tostring(snap.policy)
	parts[#parts + 1] = 'mask=' .. tostring(snap.mmx_mask)

	for i = 1, #snap.ifaces do
		local iface = snap.ifaces[i]
		parts[#parts + 1] = 'iface=' .. iface .. ',state=' .. tostring(snap.effective[iface] or 'unknown')
	end

	for i = 1, #snap.desired_chain do
		parts[#parts + 1] = 'rule=' .. normalise_rule_line(snap.desired_chain[i])
	end

	return table.concat(parts, '|')
end

local function semantically_same(current, desired)
	if #current ~= #desired then return false end
	for i = 1, #current do
		if normalise_rule_line(current[i]) ~= normalise_rule_line(desired[i]) then
			return false
		end
	end
	return true
end

--------------------------------------------------------------------------------
-- Snapshot / recompute
--------------------------------------------------------------------------------

local function gather_snapshot(policy, fallback_ifaces)
	local snap = {
		at_wall        = now_wall(),
		policy         = policy,
		mmx_mask       = env('MWAN3_MMX_MASK', nil),

		status_ok      = false,
		status_raw     = nil,
		cli_state      = {},
		file_state     = {},
		effective      = {},

		uci_ok         = false,
		uci_cfg        = nil,
		uci_members    = nil,
		uci_err        = nil,

		mangle_ok      = false,
		mangle_src     = nil,
		current_chain  = {},
		current_live   = {},
		discovered_marks = {},

		ifaces         = {},
		active_members = {},
		best_metric    = nil,
		desired_chain  = {},
	}

	-- status
	do
		local ok, out, err = run_capture('mwan3', 'status')
		if ok then
			snap.status_ok  = true
			snap.status_raw = out
			snap.cli_state  = parse_mwan3_interface_status(out)
		else
			snap.status_ok  = false
			snap.status_raw = err or out or 'mwan3 status failed'
		end
	end

	-- UCI
	do
		local ok, out = run_capture('uci', 'show', 'mwan3')
		if ok then
			snap.uci_ok  = true
			snap.uci_cfg = parse_uci_show_mwan3(out)
			if snap.mmx_mask == nil then
				local mm = snap.uci_cfg.globals and snap.uci_cfg.globals.mmx_mask or nil
				if type(mm) == 'string' and mm ~= '' then
					snap.mmx_mask = mm:lower()
				end
			end
			snap.uci_members, snap.uci_err = discover_policy_members_from_uci(snap.uci_cfg, policy)
		else
			snap.uci_ok = false
			snap.uci_err = 'uci unavailable'
		end
	end

	-- current chain
	do
		local txt, src = get_mangle_rules_text()
		if txt then
			snap.mangle_ok    = true
			snap.mangle_src   = src
			snap.current_chain = extract_policy_chain_lines(txt, policy)
			snap.discovered_marks, snap.current_live = marks_from_policy_chain(snap.current_chain, policy)
		end
	end

	if snap.mmx_mask == nil then
		if #snap.current_live > 0 and snap.current_live[1].mask then
			snap.mmx_mask = snap.current_live[1].mask
		else
			snap.mmx_mask = '0x3f00'
		end
	end
	snap.mmx_mask = snap.mmx_mask:lower()

	-- interface set
	do
		local seen = {}

		if snap.uci_members and #snap.uci_members > 0 then
			for i = 1, #snap.uci_members do
				local iface = snap.uci_members[i].iface
				if not seen[iface] then
					seen[iface] = true
					snap.ifaces[#snap.ifaces + 1] = iface
				end
			end
		elseif #snap.current_live > 0 then
			for i = 1, #snap.current_live do
				local iface = snap.current_live[i].iface
				if not seen[iface] then
					seen[iface] = true
					snap.ifaces[#snap.ifaces + 1] = iface
				end
			end
		else
			for i = 1, #fallback_ifaces do
				local iface = fallback_ifaces[i]
				if not seen[iface] then
					seen[iface] = true
					snap.ifaces[#snap.ifaces + 1] = iface
				end
			end
		end
	end

	-- effective state
	for i = 1, #snap.ifaces do
		local iface = snap.ifaces[i]
		local fstate = read_tracking_status_dir(iface)
		if fstate ~= nil then
			snap.file_state[iface] = fstate
		end
		snap.effective[iface] = fstate or snap.cli_state[iface] or 'unknown'
	end

	-- choose active set
	if snap.uci_members and #snap.uci_members > 0 then
		local chosen, best_metric = pick_effective_members_from_uci(snap.uci_members, snap.effective)
		snap.best_metric = best_metric
		snap.active_members = apply_env_overrides(chosen, snap.discovered_marks)
	else
		local chosen = pick_effective_members_from_current_chain(snap.current_live, snap.effective)
		snap.active_members = apply_env_overrides(chosen, snap.discovered_marks)
	end

	snap.desired_chain = build_desired_chain_lines(policy, snap.mmx_mask, snap.active_members)
	snap.same_as_current = semantically_same(snap.current_chain, snap.desired_chain)
	snap.signature = signature_from_snapshot(snap)

	return snap
end

--------------------------------------------------------------------------------
-- Output
--------------------------------------------------------------------------------

local function print_plan(snap, ev)
	printf('==============================================================================')
	printf('event-driven mwan3 dry-run at %s', snap.at_wall)
	printf('policy=%s  mask=%s', tostring(snap.policy), tostring(snap.mmx_mask))

	if ev then
		printf('trigger: %s', trim(ev.raw or '<synthetic>'))
	end

	printf('')
	printf('effective state:')
	for i = 1, #snap.ifaces do
		local iface = snap.ifaces[i]
		printf('  - %-8s %s (mark=%s)',
			iface,
			tostring(snap.effective[iface] or 'unknown'),
			tostring(snap.discovered_marks[iface] or '<unknown>')
		)
	end

	printf('')
	printf('desired live members:')
	if #snap.active_members == 0 then
		printf('  (none online)')
	else
		local probs = member_probabilities(snap.active_members)
		for i = 1, #probs do
			local m = probs[i]
			if m.final then
				printf('  - %-8s weight=%-3d mark=%-12s final',
					m.iface, m.weight, m.mark)
			else
				printf('  - %-8s weight=%-3d mark=%-12s probability=%s',
					m.iface, m.weight, m.mark, fmt_prob(m.prob))
			end
		end
	end

	printf('')
	if snap.same_as_current then
		printf('semantic diff: NO-OP')
	else
		printf('semantic diff: CHANGE REQUIRED')
	end

	printf('')
	printf('iptables commands:')
	local cmds = build_iptables_commands(snap.policy, snap.mmx_mask, snap.active_members)
	for i = 1, #cmds do
		printf('  %s', cmds[i])
	end

	printf('')
	printf('iptables-restore snippet:')
	io.stdout:write(build_iptables_restore_snippet(snap.policy, snap.mmx_mask, snap.active_members))
	io.stdout:write('\n\n')
	io.stdout:flush()
end

--------------------------------------------------------------------------------
-- Event source
--------------------------------------------------------------------------------

local function open_event_stream(path)
	if path and path ~= '' then
		local s, err = file_mod.open(path, 'r')
		if not s then error('failed to open event FIFO: ' .. tostring(err), 2) end
		return s
	end
	return file_mod.fdopen(0, { readable = true, writable = false }, 'stdin')
end

local function event_reader(path, tx)
	while true do
		local s = open_event_stream(path)

		while true do
			local line, err = s:read_line()
			if line == nil then
				s:close()
				if path and path ~= '' then
					-- FIFO writer may have closed; reopen and continue.
					break
				end
				tx:close('stdin closed')
				return
			end

			local ev = parse_kv_line(line)
			tx:send(ev)
		end
	end
end

--------------------------------------------------------------------------------
-- Controller
--------------------------------------------------------------------------------

local function controller(rx, policy, fallback_ifaces, debounce_sec)
	local last_sig = nil
	local pending = nil
	local need_recompute = true

	while true do
		if need_recompute and pending == nil then
			local snap = gather_snapshot(policy, fallback_ifaces)
			if snap.signature ~= last_sig then
				print_plan(snap, nil)
				last_sig = snap.signature
			end
			need_recompute = false
		end

		local ev = rx:recv()
		if ev == nil then
			return
		end

		pending = ev
		local deadline = fibers.now() + debounce_sec

		while true do
			local is_event, payload = perform(op.boolean_choice(
				rx:recv_op():wrap(function (e) return true, e end),
				sleep.sleep_until_op(deadline):wrap(function () return false end)
			))

			if is_event then
				if payload == nil then
					-- channel closed; treat as timer expiry then exit after recompute
					break
				end
				pending = payload
				deadline = fibers.now() + debounce_sec
			else
				break
			end
		end

		local snap = gather_snapshot(policy, fallback_ifaces)
		if snap.signature ~= last_sig then
			print_plan(snap, pending)
			last_sig = snap.signature
		end
		pending = nil
	end
end

--------------------------------------------------------------------------------
-- Main
--------------------------------------------------------------------------------

local function main(_scope)
	local policy       = env('MWAN3_POLICY', 'balanced')
	local ifaces       = split_csv(env('MWAN3_INTERFACES', 'wan,wanb'))
	local debounce_sec = env_num('MWAN3_DEBOUNCE_SEC', 1.0)
	local fifo_path    = arg and arg[1] or nil

	if #ifaces == 0 then
		error('MWAN3_INTERFACES must name at least one interface')
	end

	local tx, rx = mailbox.new(64, { full = 'drop_oldest' })

	-- Initial synthetic recompute.
	tx:send({ raw = 'RECOMPUTE=1', RECOMPUTE = '1' })

	fibers.spawn(function()
		event_reader(fifo_path, tx)
	end)

	controller(rx, policy, ifaces, debounce_sec)
end

fibers.run(main)
