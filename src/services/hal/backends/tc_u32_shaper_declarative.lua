-- services/hal/backends/tc_u32_shaper_declarative.lua
--
-- Declarative per-host HTB shaper using u32 hashing + exact /32 rules.
--
-- Design:
--   * Per-direction full rebuild when config changes (simple and declarative)
--   * Small in-memory hash cache to skip true no-op applies
--   * If fq_codel is not declared, it is removed (no "leave as-is")
--   * Ingress shaping uses IFB (ingress redirect on real iface -> shape IFB egress)
--
-- Notes:
--   * Cache assumes this module is the only writer of tc state.
--   * Use spec.force = true to force re-apply if you suspect kernel drift.
--
-- Lua 5.1 / LuaJIT compatible.

local exec_mod  = require 'fibers.io.exec'
local performer = require 'fibers.performer'
local perform   = performer.perform
local unpack_   = (table and table.unpack) or _G.unpack

local bit       = rawget(_G, 'bit32')
if not bit then
	local ok, b = pcall(require, 'bit')
	if ok then bit = b end
end
assert(bit, 'tc_u32_shaper_declarative: requires bit32 or bit')

local band   = bit.band
local bor    = bit.bor
local lshift = bit.lshift
local rshift = bit.rshift

local M      = {}

-- Small cache:
-- STATE[iface] = {
--   egress  = { hash = "..." },
--   ingress = { hash = "...", ifb = "ifb_ethX" },
-- }
local STATE  = {}

------------------------------------------------------------------------
-- Command runner helpers
------------------------------------------------------------------------

local function argv_push(argv, ...)
	local n = select('#', ...)
	for i = 1, n do
		argv[#argv + 1] = select(i, ...)
	end
end

local function run_cmd(argv)
	local cmd = exec_mod.command(unpack_(argv))
	local out, st, code, sig, err = perform(cmd:combined_output_op())
	local ok = (st == 'exited' and code == 0)
	return ok, out or '', err, code, st, sig
end

local function str_contains(haystack, needle)
	return type(haystack) == 'string' and haystack:find(needle, 1, true) ~= nil
end

local function is_benign_try_error(argv, out, err, code)
	local a1, a2, a3 = argv[1], argv[2], argv[3]
	local msg = (out or '') .. '\n' .. tostring(err or '')

	-- qdisc delete when qdisc is absent/default
	if a1 == 'tc' and a2 == 'qdisc' and a3 == 'del' then
		if str_contains(msg, 'Cannot delete qdisc with handle of zero.') then
			return true
		end
		if str_contains(msg, 'Cannot find specified qdisc on specified device.') then
			return true
		end
		if str_contains(msg, 'Error: Invalid handle.') then
			return true
		end
	end

	-- filter delete when missing
	if a1 == 'tc' and a2 == 'filter' and a3 == 'del' then
		if str_contains(msg, 'Cannot find specified filter chain.') then
			return true
		end
		if str_contains(msg, 'RTNETLINK answers: No such file or directory') then
			return true
		end
	end

	-- ip link add ifb when already exists
	if a1 == 'ip' and a2 == 'link' and a3 == 'add' then
		if str_contains(msg, 'File exists') then
			return true
		end
	end

	-- ip link del ifb when absent
	if a1 == 'ip' and a2 == 'link' and a3 == 'del' then
		if str_contains(msg, 'Cannot find device') then
			return true
		end
		if str_contains(msg, 'does not exist') then
			return true
		end
	end

	return false
end

local function try_cmd(argv, logger)
	local ok, out, err, code = run_cmd(argv)
	if not ok then
		if not is_benign_try_error(argv, out, err, code) and logger then
			logger('warn', {
				what = 'tc_cmd_failed',
				cmd  = table.concat(argv, ' '),
				out  = out ~= '' and out or nil,
				err  = err and tostring(err) or nil,
				code = code,
			})
		end
	end
	return ok, out, err, code
end

local function must_cmd(argv, logger, label)
	local ok, out, err, code = run_cmd(argv)
	if not ok then
		local msg = (label or table.concat(argv, ' ')) .. ': ' ..
			tostring(err or out or ('exit ' .. tostring(code)))
		if logger then
			logger('error', {
				what  = 'tc_cmd_failed_fatal',
				label = label,
				cmd   = table.concat(argv, ' '),
				out   = out ~= '' and out or nil,
				err   = err and tostring(err) or nil,
				code  = code,
			})
		end
		return nil, msg
	end
	return true, nil
end

------------------------------------------------------------------------
-- Generic helpers
------------------------------------------------------------------------

local function is_plain_table(x)
	return type(x) == 'table' and getmetatable(x) == nil
end

local function sorted_keys(t)
	local ks = {}
	for k in pairs(t or {}) do ks[#ks + 1] = k end
	table.sort(ks, function(a, b)
		local ta, tb = type(a), type(b)
		if ta ~= tb then return ta < tb end
		return tostring(a) < tostring(b)
	end)
	return ks
end

local function shallow_copy(t)
	local o = {}
	for k, v in pairs(t or {}) do o[k] = v end
	return o
end

local function sanitise_ifb_name(iface)
	local base = 'ifb_' .. tostring(iface or '')
	if #base <= 15 then return base end
	return base:sub(1, 15)
end

local function parse_ipv4(s)
	if type(s) ~= 'string' then return nil end
	local a, b, c, d = s:match('^(%d+)%.(%d+)%.(%d+)%.(%d+)$')
	a, b, c, d = tonumber(a), tonumber(b), tonumber(c), tonumber(d)
	if not (a and b and c and d) then return nil end
	if a > 255 or b > 255 or c > 255 or d > 255 then return nil end
	return bor(lshift(a, 24), lshift(b, 16), lshift(c, 8), d)
end

local function ipv4_to_string(u)
	u = tonumber(u) or 0
	local a = band(rshift(u, 24), 0xff)
	local b = band(rshift(u, 16), 0xff)
	local c = band(rshift(u, 8), 0xff)
	local d = band(u, 0xff)
	return string.format('%d.%d.%d.%d', a, b, c, d)
end

local function mask_from_prefix(pfx)
	pfx = tonumber(pfx)
	if not pfx or pfx < 0 or pfx > 32 then return nil end
	if pfx == 0 then return 0 end
	local m = 0
	for i = 1, pfx do
		m = bor(m, lshift(1, 32 - i))
	end
	return m
end

local function parse_cidr(cidr)
	if type(cidr) ~= 'string' then return nil, nil, 'cidr must be a string' end
	local ip_s, pfx_s = cidr:match('^([^/]+)/(%d+)$')
	if not ip_s then return nil, nil, 'bad cidr format' end
	local ip = parse_ipv4(ip_s)
	local pfx = tonumber(pfx_s)
	if not ip or not pfx then return nil, nil, 'bad cidr value' end
	if pfx < 20 or pfx > 32 then
		return nil, nil, 'supported prefixes are /20.. /32'
	end
	local mask = mask_from_prefix(pfx)
	local net  = band(ip, mask)
	return net, pfx, nil
end

local function host_count_from_prefix(pfx)
	return 2 ^ (32 - pfx)
end

local function ip_in_subnet(ip_u, net_u, pfx)
	local mask = mask_from_prefix(pfx)
	return band(ip_u, mask) == band(net_u, mask)
end

local function host_offset(ip_u, net_u)
	local off = tonumber(ip_u) - tonumber(net_u)
	if off < 0 then return nil end
	return off
end

local function bool_flag(v, yes_name, no_name)
	if v == nil then return nil end
	return v and yes_name or no_name
end

------------------------------------------------------------------------
-- Stable signature (cache)
------------------------------------------------------------------------

local function stable_repr(v)
	local tv = type(v)

	if tv == 'nil' then
		return 'nil'
	elseif tv == 'boolean' then
		return v and 'true' or 'false'
	elseif tv == 'number' then
		return ('n:%s'):format(tostring(v))
	elseif tv == 'string' then
		return ('s:%d:%s'):format(#v, v)
	elseif tv == 'table' then
		local ks = sorted_keys(v)
		local parts = { 't{' }
		for i = 1, #ks do
			local k = ks[i]
			local vk = v[k]
			local tk = type(vk)
			-- Ignore functions/thread/userdata in signatures
			if tk ~= 'function' and tk ~= 'thread' and tk ~= 'userdata' then
				parts[#parts + 1] = stable_repr(k)
				parts[#parts + 1] = '='
				parts[#parts + 1] = stable_repr(vk)
				parts[#parts + 1] = ';'
			end
		end
		parts[#parts + 1] = '}'
		return table.concat(parts)
	end

	-- Fallback (should not be used for config data)
	return '<' .. tv .. '>'
end

local function direction_hash_payload(iface, kind, cidr, cfg, ids, ifb)
	return {
		iface = iface,
		kind  = kind,
		cidr  = cidr,
		ifb   = ifb,
		ids   = ids,
		cfg   = cfg or false,
	}
end

------------------------------------------------------------------------
-- fq_codel args
------------------------------------------------------------------------

local function append_fq_codel_args(argv, fq)
	fq = fq or {}
	argv[#argv + 1] = 'fq_codel'

	if fq.limit ~= nil then argv_push(argv, 'limit', tostring(fq.limit)) end
	if fq.flows ~= nil then argv_push(argv, 'flows', tostring(fq.flows)) end
	if fq.quantum ~= nil then argv_push(argv, 'quantum', tostring(fq.quantum)) end
	if fq.target ~= nil then argv_push(argv, 'target', tostring(fq.target)) end
	if fq.interval ~= nil then argv_push(argv, 'interval', tostring(fq.interval)) end
	if fq.memory_limit ~= nil then argv_push(argv, 'memory_limit', tostring(fq.memory_limit)) end
	if fq.drop_batch ~= nil then argv_push(argv, 'drop_batch', tostring(fq.drop_batch)) end
	if fq.ce_threshold ~= nil then argv_push(argv, 'ce_threshold', tostring(fq.ce_threshold)) end

	local ecn = bool_flag(fq.ecn, 'ecn', 'noecn')
	if ecn then argv[#argv + 1] = ecn end
end

------------------------------------------------------------------------
-- tc layout helpers
------------------------------------------------------------------------

local function default_ids()
	return {
		root_major        = 1,
		root_class_minor  = 1,
		pool_minor        = 20,
		inner_major       = 20,
		inner_root_minor  = 1,
		default_minor     = 100,
		base_minor        = 1000,
		host_table_handle = 1,
		outer_prio        = 100,
		link_prio         = 1,
		host_prio         = 99,
	}
end

local function classid(major, minor)
	return tostring(major) .. ':' .. tostring(minor)
end

local function qdisc_handle(major)
	return tostring(major) .. ':'
end

local function htb_class_replace(dev, parent, class_id, cfg, logger)
	cfg           = cfg or {}
	local rate    = tostring(cfg.rate or '1gbit')
	local ceil    = tostring(cfg.ceil or rate)
	local burst   = (cfg.burst ~= nil) and tostring(cfg.burst) or nil
	local cburst  = (cfg.cburst ~= nil) and tostring(cfg.cburst) or nil
	local prio    = (cfg.prio ~= nil) and tostring(cfg.prio) or nil
	local quantum = (cfg.quantum ~= nil) and tostring(cfg.quantum) or nil

	local argv    = {
		'tc', 'class', 'replace', 'dev', dev,
		'parent', parent,
		'classid', class_id,
		'htb',
		'rate', rate,
	}

	if burst then argv_push(argv, 'burst', burst) end
	argv_push(argv, 'ceil', ceil)
	if cburst then argv_push(argv, 'cburst', cburst) end
	if prio then argv_push(argv, 'prio', prio) end
	if quantum then argv_push(argv, 'quantum', quantum) end

	return must_cmd(argv, logger, 'htb class replace ' .. class_id)
end

local function fq_codel_qdisc_argv(op, dev, parent_classid, fq)
	local argv = { 'tc', 'qdisc', op, 'dev', dev, 'parent', parent_classid }
	append_fq_codel_args(argv, fq)
	return argv
end

local function fq_codel_qdisc_replace(dev, parent_classid, fq, logger)
	-- Avoid "tc qdisc replace" for fq_codel on HTB leaves: some OpenWrt/kernel
	-- combinations reject repeated replace with EINVAL. Use delete+add instead.
	try_cmd({ 'tc', 'qdisc', 'del', 'dev', dev, 'parent', parent_classid }, logger)

	local argv = fq_codel_qdisc_argv('add', dev, parent_classid, fq)
	return must_cmd(argv, logger, 'fq_codel qdisc add on ' .. parent_classid)
end

local function fq_codel_qdisc_remove(dev, parent_classid, logger)
	-- Declarative semantics: absent fq_codel means no leaf qdisc.
	try_cmd({ 'tc', 'qdisc', 'del', 'dev', dev, 'parent', parent_classid }, logger)
	return true, nil
end

------------------------------------------------------------------------
-- IFB ingress redirect
------------------------------------------------------------------------

local function ensure_ifb(ifb, logger)
	try_cmd({ 'ip', 'link', 'add', ifb, 'type', 'ifb' }, logger)
	return must_cmd({ 'ip', 'link', 'set', 'dev', ifb, 'up' }, logger, 'ifb up')
end

local function ensure_ingress_redirect(iface, ifb, logger)
	try_cmd({ 'tc', 'qdisc', 'del', 'dev', iface, 'ingress' }, logger)

	local ok, err = must_cmd({
		'tc', 'qdisc', 'add', 'dev', iface, 'handle', 'ffff:', 'ingress'
	}, logger, 'add ingress qdisc')
	if not ok then return nil, err end

	return must_cmd({
		'tc', 'filter', 'add', 'dev', iface, 'parent', 'ffff:',
		'protocol', 'ip', 'u32',
		'match', 'u32', '0', '0',
		'action', 'mirred', 'egress', 'redirect', 'dev', ifb,
	}, logger, 'add mirred redirect')
end

------------------------------------------------------------------------
-- Direction helpers
------------------------------------------------------------------------

local function direction_params(kind, cfg)
	if kind == 'egress' then
		local m = cfg.match or 'dst'
		return {
			match_field = m,
			hash_at     = (m == 'src') and 12 or 16,
		}
	else
		local m = cfg.match or 'src'
		return {
			match_field = m,
			hash_at     = (m == 'src') and 12 or 16,
		}
	end
end

local function clear_direction_kernel(iface, kind, ifb, logger, delete_ifb)
	if kind == 'egress' then
		try_cmd({ 'tc', 'qdisc', 'del', 'dev', iface, 'root' }, logger)
		return true, nil
	end

	ifb = ifb or sanitise_ifb_name(iface)

	try_cmd({ 'tc', 'qdisc', 'del', 'dev', iface, 'ingress' }, logger)
	try_cmd({ 'tc', 'qdisc', 'del', 'dev', ifb, 'root' }, logger)

	if delete_ifb then
		try_cmd({ 'ip', 'link', 'del', ifb }, logger)
	end

	return true, nil
end

------------------------------------------------------------------------
-- Host plan (validate + class mapping)
------------------------------------------------------------------------

local function resolve_host_fq(global_fq, host_fq)
	-- Declarative:
	--   nil  -> no fq_codel (remove)
	--   false -> no fq_codel (remove)
	--   table -> apply (host table merged over global table, if any)
	if host_fq == false then return nil end

	if is_plain_table(host_fq) then
		local out = {}
		if is_plain_table(global_fq) then
			for k, v in pairs(global_fq) do out[k] = v end
		end
		for k, v in pairs(host_fq) do out[k] = v end
		return out
	end

	if is_plain_table(global_fq) then
		local out = {}
		for k, v in pairs(global_fq) do out[k] = v end
		return out
	end

	return nil
end

local function build_host_plan(spec, cfg, ids)
	local hosts = cfg.hosts or {}
	if not is_plain_table(hosts) then
		return nil, 'hosts must be a table keyed by IPv4 string'
	end

	local out = {}
	local host_keys = sorted_keys(hosts)

	for i = 1, #host_keys do
		local ip_s = host_keys[i]
		local hcfg = hosts[ip_s]
		if not is_plain_table(hcfg) then
			return nil, 'host entry for ' .. tostring(ip_s) .. ' must be a table'
		end

		local ip_u = parse_ipv4(ip_s)
		if not ip_u then
			return nil, 'invalid host IP ' .. tostring(ip_s)
		end
		if not ip_in_subnet(ip_u, spec.net_u, spec.pfx) then
			return nil, 'host ' .. ip_s .. ' is outside subnet ' .. spec.cidr
		end

		local off = host_offset(ip_u, spec.net_u)
		if off == nil then
			return nil, 'failed to compute host offset for ' .. ip_s
		end
		if off >= host_count_from_prefix(spec.pfx) then
			return nil, 'host offset out of range for ' .. ip_s
		end

		local bucket = band(ip_u, 0xff)
		local minor  = ids.base_minor + off
		if minor == ids.default_minor then
			return nil, 'classid collision for host ' .. ip_s .. '; change base_minor/default_minor'
		end
		if minor > 65534 then
			return nil, 'class minor too large for host ' .. ip_s
		end

		local rec = {
			ip_s    = ip_s,
			ip_u    = ip_u,
			offset  = off,
			bucket  = bucket,
			minor   = minor,
			classid = classid(ids.inner_major, minor),
			htb     = {
				rate    = hcfg.rate or cfg.host_rate or '1mbit',
				ceil    = hcfg.ceil or cfg.host_ceil or hcfg.rate or cfg.host_rate or '1mbit',
				burst   = hcfg.burst or cfg.host_burst,
				cburst  = hcfg.cburst or cfg.host_cburst,
				prio    = hcfg.prio or cfg.host_prio,
				quantum = hcfg.quantum or cfg.host_quantum,
			},
			fq      = resolve_host_fq(cfg.fq_codel, hcfg.fq_codel),
		}

		out[#out + 1] = rec
	end

	return out, nil
end

------------------------------------------------------------------------
-- Full direction rebuild (declarative)
------------------------------------------------------------------------

local function build_scaffold(dev, kind, spec, cfg, ids, logger)
	local dp          = direction_params(kind, cfg)
	local match_field = dp.match_field
	local hash_at     = tostring(dp.hash_at)
	local net_s       = ipv4_to_string(spec.net_u) .. '/' .. tostring(spec.pfx)

	if ids.link_prio == ids.host_prio then
		return nil, 'link_prio and host_prio must differ'
	end

	-- Reset root on shaped device
	try_cmd({ 'tc', 'qdisc', 'del', 'dev', dev, 'root' }, logger)

	-- root htb qdisc
	local ok, err = must_cmd({
		'tc', 'qdisc', 'add', 'dev', dev, 'root',
		'handle', qdisc_handle(ids.root_major),
		'htb',
		'default', tostring(10),
	}, logger, 'root htb qdisc')
	if not ok then return nil, err end

	-- root class
	ok, err = htb_class_replace(
		dev,
		qdisc_handle(ids.root_major),
		classid(ids.root_major, ids.root_class_minor),
		cfg.root_class or {
			rate = (cfg.root_rate or '1gbit'),
			ceil = (cfg.root_ceil or cfg.root_rate or '1gbit'),
		},
		logger
	)
	if not ok then return nil, err end

	-- pool class
	ok, err = htb_class_replace(
		dev,
		classid(ids.root_major, ids.root_class_minor),
		classid(ids.root_major, ids.pool_minor),
		cfg.pool_class or {
			rate   = (cfg.pool_rate or cfg.rate or '1gbit'),
			ceil   = (cfg.pool_ceil or cfg.ceil or cfg.pool_rate or cfg.rate or '1gbit'),
			burst  = cfg.pool_burst,
			cburst = cfg.pool_cburst,
		},
		logger
	)
	if not ok then return nil, err end

	-- inner htb qdisc
	ok, err = must_cmd({
		'tc', 'qdisc', 'add', 'dev', dev,
		'parent', classid(ids.root_major, ids.pool_minor),
		'handle', qdisc_handle(ids.inner_major),
		'htb',
		'default', tostring(ids.default_minor),
	}, logger, 'inner htb qdisc')
	if not ok then return nil, err end

	-- inner root class
	ok, err = htb_class_replace(
		dev,
		qdisc_handle(ids.inner_major),
		classid(ids.inner_major, ids.inner_root_minor),
		{
			rate   = (cfg.pool_rate or cfg.rate or '1gbit'),
			ceil   = (cfg.pool_ceil or cfg.ceil or cfg.pool_rate or cfg.rate or '1gbit'),
			burst  = cfg.pool_burst,
			cburst = cfg.pool_cburst,
		},
		logger
	)
	if not ok then return nil, err end

	-- default inner class (unmatched hosts within subnet)
	ok, err = htb_class_replace(
		dev,
		classid(ids.inner_major, ids.inner_root_minor),
		classid(ids.inner_major, ids.default_minor),
		cfg.default_class or {
			rate   = (cfg.default_rate or cfg.host_rate or '1gbit'),
			ceil   = (cfg.default_ceil or cfg.host_ceil or cfg.default_rate or cfg.host_rate or '1gbit'),
			burst  = (cfg.default_burst or cfg.host_burst),
			cburst = (cfg.default_cburst or cfg.host_cburst),
		},
		logger
	)
	if not ok then return nil, err end

	-- Declarative default leaf qdisc
	if is_plain_table(cfg.default_fq_codel) then
		ok, err = fq_codel_qdisc_replace(dev, classid(ids.inner_major, ids.default_minor), cfg.default_fq_codel, logger)
		if not ok then return nil, err end
	else
		fq_codel_qdisc_remove(dev, classid(ids.inner_major, ids.default_minor), logger)
	end

	-- Outer prefix gate (root -> pool)
	ok, err = must_cmd({
		'tc', 'filter', 'add', 'dev', dev,
		'parent', qdisc_handle(ids.root_major),
		'protocol', 'ip',
		'prio', tostring(ids.outer_prio),
		'u32', 'match', 'ip', match_field, net_s,
		'flowid', classid(ids.root_major, ids.pool_minor),
	}, logger, 'outer prefix gate')
	if not ok then return nil, err end

	-- Host u32 hash table
	ok, err = must_cmd({
		'tc', 'filter', 'add', 'dev', dev,
		'parent', qdisc_handle(ids.inner_major),
		'protocol', 'ip',
		'prio', tostring(ids.host_prio),
		'handle', tostring(ids.host_table_handle) .. ':',
		'u32', 'divisor', '256',
	}, logger, 'host u32 table divisor 256')
	if not ok then return nil, err end

	-- Hash-link filter
	ok, err = must_cmd({
		'tc', 'filter', 'add', 'dev', dev,
		'parent', qdisc_handle(ids.inner_major),
		'protocol', 'ip',
		'prio', tostring(ids.link_prio),
		'u32',
		'link', tostring(ids.host_table_handle) .. ':',
		'hashkey', 'mask', '0x000000ff', 'at', hash_at,
		'match', 'ip', match_field, net_s,
	}, logger, 'inner link+hashkey')
	if not ok then return nil, err end

	return true, nil
end

local function build_hosts(dev, kind, spec, cfg, ids, logger)
	local dp = direction_params(kind, cfg)
	local match_field = dp.match_field
	local plan, err = build_host_plan(spec, cfg, ids)
	if not plan then return nil, err end

	-- Exact host rules
	for i = 1, #plan do
		local rec = plan[i]

		local ok, ferr = must_cmd({
			'tc', 'filter', 'add', 'dev', dev,
			'parent', qdisc_handle(ids.inner_major),
			'protocol', 'ip',
			'prio', tostring(ids.host_prio),
			'u32',
			'ht', tostring(ids.host_table_handle) .. ':' .. tostring(rec.bucket) .. ':',
			'match', 'ip', match_field, rec.ip_s .. '/32',
			'flowid', rec.classid,
		}, logger, 'host rule ' .. rec.ip_s)
		if not ok then return nil, ferr end
	end

	-- Host classes + leaf qdiscs
	for i = 1, #plan do
		local rec = plan[i]

		local ok, cerr = htb_class_replace(
			dev,
			classid(ids.inner_major, ids.inner_root_minor),
			rec.classid,
			rec.htb,
			logger
		)
		if not ok then return nil, cerr end

		if rec.fq then
			ok, cerr = fq_codel_qdisc_replace(dev, rec.classid, rec.fq, logger)
			if not ok then return nil, cerr end
		else
			-- Declarative: absent fq spec means remove
			fq_codel_qdisc_remove(dev, rec.classid, logger)
		end
	end

	return true, nil
end

local function apply_direction(iface, kind, spec, cfg, opts)
	local logger    = opts and opts.logger or nil
	local force     = opts and opts.force or false

	local per_iface = STATE[iface] or {}
	STATE[iface]    = per_iface

	-- Disabled or absent direction: clear and drop cache
	if not cfg or cfg.enabled == false then
		local cached = per_iface[kind]
		local ifb = (kind == 'ingress') and ((cfg and cfg.ifb) or (cached and cached.ifb) or sanitise_ifb_name(iface)) or
		nil
		local ok, err = clear_direction_kernel(
			iface, kind, ifb, logger,
			(kind == 'ingress' and cfg and cfg.delete_ifb == true) or false
		)
		if not ok then return nil, err end
		per_iface[kind] = nil
		if not per_iface.egress and not per_iface.ingress then
			STATE[iface] = nil
		end
		return true, nil
	end

	-- IDs are part of the declarative state
	local ids = shallow_copy(default_ids())
	for k, v in pairs(cfg.ids or {}) do ids[k] = v end

	local dev = iface
	local ifb = nil
	if kind == 'ingress' then
		ifb = cfg.ifb or sanitise_ifb_name(iface)
		dev = ifb
	end

	local hash = stable_repr(direction_hash_payload(iface, kind, spec.cidr, cfg, ids, ifb))
	local cached = per_iface[kind]

	if not force and cached and cached.hash == hash then
		return true, nil
	end

	-- Ingress IFB/redirect is always re-established on rebuild.
	if kind == 'ingress' then
		local ok, err = ensure_ifb(ifb, logger)
		if not ok then return nil, err end
		ok, err = ensure_ingress_redirect(iface, ifb, logger)
		if not ok then return nil, err end
	end

	-- Full declarative rebuild on the shaped device (iface for egress, IFB for ingress)
	local ok, err = build_scaffold(dev, kind, spec, cfg, ids, logger)
	if not ok then return nil, err end

	ok, err = build_hosts(dev, kind, spec, cfg, ids, logger)
	if not ok then return nil, err end

	per_iface[kind] = { hash = hash, ifb = ifb }
	return true, nil
end

------------------------------------------------------------------------
-- Public API
------------------------------------------------------------------------

--- Apply bi-directional per-host shaping declaratively.
---
--- spec = {
---   iface   = "eth2",
---   subnet  = "10.12.0.0/20",   -- or cidr
---   force   = false,            -- optional; true bypasses no-op cache
---   log     = function(level, payload) ... end, -- optional
---
---   egress = {
---     enabled = true,
---     match = "dst",            -- default "dst"
---     pool_rate = "100mbit",
---     pool_ceil = "100mbit",
---     host_rate = "2mbit",
---     host_ceil = "5mbit",
---     fq_codel = { flows=1024, limit=10240 },
---     default_fq_codel = { flows=1024 }, -- if omitted, no fq_codel on default class
---     hosts = {
---       ["10.12.0.2"] = { rate="1mbit", ceil="2mbit" },
---       ["10.12.0.3"] = { fq_codel=false }, -- explicitly no fq_codel
---     },
---   },
---
---   ingress = {
---     enabled = true,
---     ifb = "ifb_eth2",         -- optional
---     match = "src",            -- default "src"
---     pool_rate = "100mbit",
---     pool_ceil = "100mbit",
---     host_rate = "2mbit",
---     host_ceil = "5mbit",
---     fq_codel = { flows=1024, limit=10240 },
---     hosts = { ... },
---   }
--- }
function M.apply(spec)
	spec = spec or {}

	local iface = spec.iface
	if type(iface) ~= 'string' or iface == '' then
		return nil, 'iface is required'
	end

	local cidr = spec.subnet or spec.cidr
	local net_u, pfx, cerr = parse_cidr(cidr)
	if not net_u then
		return nil, cerr
	end

	local logger  = (type(spec.log) == 'function') and spec.log or nil
	local force   = (spec.force == true)

	local parsed  = {
		cidr  = cidr,
		net_u = net_u,
		pfx   = pfx,
	}

	local ok, err = apply_direction(iface, 'egress', parsed, spec.egress, { logger = logger, force = force })
	if not ok then return nil, 'egress: ' .. tostring(err) end

	ok, err = apply_direction(iface, 'ingress', parsed, spec.ingress, { logger = logger, force = force })
	if not ok then return nil, 'ingress: ' .. tostring(err) end

	return true, nil
end

--- Clear shaping on an interface (egress root + ingress redirect; IFB root if known).
function M.clear(iface, opts)
	opts = opts or {}
	if type(iface) ~= 'string' or iface == '' then
		return nil, 'iface is required'
	end

	local logger = (type(opts.log) == 'function') and opts.log or nil
	local st = STATE[iface]
	local ifb = opts.ifb or (st and st.ingress and st.ingress.ifb) or sanitise_ifb_name(iface)

	local ok, err = clear_direction_kernel(iface, 'egress', nil, logger, false)
	if not ok then return nil, err end

	ok, err = clear_direction_kernel(iface, 'ingress', ifb, logger, opts.delete_ifb == true)
	if not ok then return nil, err end

	STATE[iface] = nil
	return true, nil
end

--- Drop only the in-memory cache (does not touch kernel tc state).
function M.invalidate_cache(iface)
	if iface == nil then
		STATE = {}
		return true
	end
	STATE[iface] = nil
	return true
end

return M
