-- services/hal/backends/tc_u32_shaper.lua
--
-- Strict per-host HTB shaper using u32 hashing + exact /32 rules.
--
-- Supports:
--   * egress shaping on iface (typically match dst)
--   * ingress shaping via IFB (mirror ingress -> shape IFB egress)
--   * /20 max subnet size (4096 hosts)
--   * incremental class updates (tc class replace)
--   * bulk programming acceleration via tc -batch (host filters + HTB host classes)
--   * per-host fq_codel parameters
--   * declarative "all_hosts" expansion for every IP in the subnet
--     (with optional per-host overrides)
--
-- Notes:
--   * When all_hosts=true, hosts={} is treated as an override table.
--   * By default, network and broadcast addresses are skipped for /0.. /30.
--     Use include_network/include_broadcast to include them explicitly.
--   * Lua 5.1 / LuaJIT compatible.

local exec_mod  = require 'fibers.io.exec'
local performer = require 'fibers.performer'
local perform   = performer.perform
local unpack_   = (table and table.unpack) or _G.unpack

local bit       = rawget(_G, 'bit32')
if not bit then
	local ok, b = pcall(require, 'bit')
	if ok then bit = b end
end
assert(bit, 'tc_shaper: requires bit32 or bit')

local band           = bit.band
local bor            = bit.bor
local lshift         = bit.lshift
local rshift         = bit.rshift

local M              = {}

-- Chunk size for tc batch application (kept moderate for memory/error locality).
local TC_BATCH_CHUNK = 512

-- Lua 5.1/LuaJIT-safe argv appender.
-- Do not use: argv[#argv+1], argv[#argv+1] = k, v
-- (both indices are evaluated before assignment, so they target the same slot)
local function argv_push(argv, ...)
	local n = select('#', ...)
	for i = 1, n do
		argv[#argv + 1] = select(i, ...)
	end
end

-- In-memory state for incremental updates (per process)
-- STATE[iface] = {
--   egress = { sig=..., dev=..., hosts_membership_sig=..., hosts_limits_sig=..., hosts=..., ids=... },
--   ingress = { sig=..., dev=..., hosts_membership_sig=..., hosts_limits_sig=..., hosts=..., ids=..., ifb=... },
-- }
local STATE = {}

------------------------------------------------------------------------
-- Command runner helpers
------------------------------------------------------------------------

local function run_cmd(argv)
	local cmd = exec_mod.command(unpack_(argv))
	local out, st, code, sig, err = perform(cmd:combined_output_op())
	local ok = (st == 'exited' and code == 0)
	return ok, out or '', err, code, st, sig
end

------------------------------------------------------------------------
-- tc -batch helpers (bulk apply)
------------------------------------------------------------------------

local function tc_batch_line(argv)
	-- tc -batch input lines are tc subcommands, i.e. omit argv[1] == "tc".
	-- We only support whitespace-free tokens here (which matches our generated args).
	if type(argv) ~= 'table' or argv[1] ~= 'tc' then
		return nil, 'tc batch expects argv beginning with "tc"'
	end

	local parts = {}
	for i = 2, #argv do
		local s = tostring(argv[i])
		if s:find('[\r\n]') then
			return nil, 'tc batch token contains newline'
		end
		if s:find('%s') then
			-- tc batch parser is token-based, not shell-quoted; keep this strict.
			return nil, 'tc batch token contains whitespace: ' .. s
		end
		parts[#parts + 1] = s
	end
	return table.concat(parts, ' '), nil
end

local function write_file_all(path, text)
	local f, err = io.open(path, 'wb')
	if not f then return nil, err end
	local okw, werr = f:write(text)
	if not okw then
		f:close()
		return nil, werr
	end
	local okc, cerr = f:close()
	if not okc then return nil, cerr end
	return true, nil
end

local function run_tc_batch(cmds)
	-- cmds: array of argv tables, each beginning with "tc"
	if type(cmds) ~= 'table' or #cmds == 0 then
		return true, '', nil, 0, 'exited', 0
	end

	local lines = {}
	for i = 1, #cmds do
		local line, lerr = tc_batch_line(cmds[i])
		if not line then
			return nil, '', 'batch line encode failed: ' .. tostring(lerr), 255, 'exited', 0
		end
		lines[#lines + 1] = line
	end

	local path = os.tmpname()
	if not path or path == '' then
		return nil, '', 'os.tmpname failed', 255, 'exited', 0
	end

	local okf, ferr = write_file_all(path, table.concat(lines, '\n') .. '\n')
	if not okf then
		pcall(os.remove, path)
		return nil, '', 'failed to write tc batch file: ' .. tostring(ferr), 255, 'exited', 0
	end

	local ok, out, err, code, st, sig = run_cmd({ 'tc', '-batch', path })
	pcall(os.remove, path)
	return ok, out, err, code, st, sig
end

local function must_tc_batch(cmds, logger, label)
	local ok, out, err, code = run_tc_batch(cmds)
	if not ok then
		local msg = (label or 'tc -batch') .. ': ' .. tostring(err or out or ('exit ' .. tostring(code)))
		if logger then
			logger('error', {
				what = 'tc_batch_failed_fatal',
				label = label,
				count = #cmds,
				out = out ~= '' and out or nil,
				err = err and tostring(err) or nil,
				code = code,
			})
		end
		return nil, msg
	end
	return true, nil
end

local function must_tc_batch_chunked(cmds, logger, label, chunk_size)
	chunk_size = tonumber(chunk_size) or TC_BATCH_CHUNK
	if chunk_size < 1 then chunk_size = TC_BATCH_CHUNK end

	local n = #cmds
	if n == 0 then return true, nil end

	local i = 1
	local chunk_no = 0
	while i <= n do
		chunk_no = chunk_no + 1
		local j = math.min(i + chunk_size - 1, n)
		local chunk = {}
		for k = i, j do
			chunk[#chunk + 1] = cmds[k]
		end
		local ok, err = must_tc_batch(chunk, logger, (label or 'tc-batch') .. ' (chunk ' .. tostring(chunk_no) .. ')')
		if not ok then return nil, err end
		i = j + 1
	end
	return true, nil
end

------------------------------------------------------------------------
-- Benign-error suppression for best-effort cleanup
------------------------------------------------------------------------

local function str_contains(haystack, needle)
	return type(haystack) == 'string' and haystack:find(needle, 1, true) ~= nil
end

local function is_benign_try_error(argv, out, err, code)
	-- Only used for try_cmd() (best-effort cleanup/idempotent setup), never for must_cmd().
	-- We suppress known "nothing to delete / already exists" cases.
	local a1, a2, a3 = argv[1], argv[2], argv[3]
	local msg = (out or '') .. '\n' .. tostring(err or '')

	-- tc qdisc del ... on interfaces that still have only the default qdisc
	if a1 == 'tc' and a2 == 'qdisc' and a3 == 'del' then
		if str_contains(msg, 'Cannot delete qdisc with handle of zero.') then
			return true
		end
		if str_contains(msg, 'Cannot find specified qdisc on specified device.') then
			return true
		end
		-- OpenWrt/iproute2 sometimes reports this for missing/invalid parent handles
		if str_contains(msg, 'Error: Invalid handle.') then
			return true
		end
	end

	-- tc filter del ... when the chain/prio is not present yet
	if a1 == 'tc' and a2 == 'filter' and a3 == 'del' then
		if str_contains(msg, 'Cannot find specified filter chain.') then
			return true
		end
		-- Some builds report a generic rtnetlink "not found" for missing filters
		if str_contains(msg, 'RTNETLINK answers: No such file or directory') then
			return true
		end
	end

	-- ip link add ifb... when IFB already exists
	if a1 == 'ip' and a2 == 'link' and a3 == 'add' then
		if str_contains(msg, 'File exists') then
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
		local msg = (label or table.concat(argv, ' ')) .. ': ' .. tostring(err or out or ('exit ' .. tostring(code)))
		if logger then
			logger('error', {
				what = 'tc_cmd_failed_fatal',
				label = label,
				cmd = table.concat(argv, ' '),
				out = out ~= '' and out or nil,
				err = err and tostring(err) or nil,
				code = code,
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
	table.sort(ks, function(a, b) return tostring(a) < tostring(b) end)
	return ks
end

local function shallow_copy(t)
	local o = {}
	for k, v in pairs(t or {}) do o[k] = v end
	return o
end

local function sanitise_ifb_name(iface)
	-- Linux ifname max is 15 chars. "ifb_" + iface may overflow.
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
	-- Build mask without relying on unsigned literals.
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
	-- safe for /20..32 (<= 4095)
	local off = tonumber(ip_u) - tonumber(net_u)
	if off < 0 then return nil end
	return off
end

local function bool_flag(v, yes_name, no_name)
	if v == nil then return nil end
	return v and yes_name or no_name
end

local function should_skip_specials(pfx, off, total, cfg)
	-- By default skip network+broadcast for /0.. /30.
	-- For /31 and /32, keep both endpoints.
	if pfx >= 31 then
		return false
	end

	local include_net   = (cfg and cfg.include_network == true)
	local include_bcast = (cfg and cfg.include_broadcast == true)

	if off == 0 and not include_net then
		return true
	end
	if off == (total - 1) and not include_bcast then
		return true
	end
	return false
end

local function u32_handle_hex(n)
	n = tonumber(n) or 0
	if n < 0 then n = 0 end
	return string.format('%x', n)
end

local function u32_table_ref(handle_num)
	return u32_handle_hex(handle_num) .. ':'
end

local function u32_bucket_ref(handle_num, bucket_num)
	return u32_handle_hex(handle_num) .. ':' .. u32_handle_hex(bucket_num) .. ':'
end

------------------------------------------------------------------------
-- fq_codel args
------------------------------------------------------------------------

local function append_fq_codel_args(argv, fq)
	fq = fq or {}
	argv[#argv + 1] = 'fq_codel'

	-- Common, useful knobs
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

local function fq_signature(fq)
	if not is_plain_table(fq) then return '' end
	local ks = sorted_keys(fq)
	local parts = {}
	for i = 1, #ks do
		local k = ks[i]
		parts[#parts + 1] = tostring(k) .. '=' .. tostring(fq[k])
	end
	return table.concat(parts, ';')
end

------------------------------------------------------------------------
-- tc layout helpers
------------------------------------------------------------------------

local function default_ids()
	return {
		root_major        = 1, -- root htb qdisc handle 1:
		root_class_minor  = 1, -- class 1:1
		pool_minor        = 20, -- class 1:20 (subnet pool)
		inner_major       = 20, -- child htb qdisc handle 20:
		inner_root_minor  = 1, -- class 20:1
		default_minor     = 100, -- class 20:100 default unmatched-in-subnet
		base_minor        = 1000, -- per-host classes 20:(base+offset)
		host_table_handle = 1, -- u32 table handle 1:
		outer_prio        = 100, -- outer gate priority
		link_prio         = 1, -- hash-link filter priority
		host_prio         = 99, -- host rules + table priority
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

	-- Safe ordering for HTB class args.
	if burst then argv_push(argv, 'burst', burst) end
	argv_push(argv, 'ceil', ceil)
	if cburst then argv_push(argv, 'cburst', cburst) end
	if prio then argv_push(argv, 'prio', prio) end
	if quantum then argv_push(argv, 'quantum', quantum) end

	return must_cmd(argv, logger, 'htb class replace ' .. class_id)
end

local function htb_class_replace_argv(dev, parent, class_id, cfg)
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

	return argv
end

local function fq_codel_qdisc_argv(op, dev, parent_classid, fq)
	local argv = { 'tc', 'qdisc', op, 'dev', dev, 'parent', parent_classid }
	append_fq_codel_args(argv, fq)
	return argv
end

local function fq_codel_qdisc_replace(dev, parent_classid, fq, logger)
	-- Deliberately avoid "tc qdisc replace" for fq_codel on HTB leaves.
	-- Some OpenWrt/iproute2/kernel combinations reject repeated replace with EINVAL.
	-- Use a deterministic delete+add path everywhere.
	try_cmd({ 'tc', 'qdisc', 'del', 'dev', dev, 'parent', parent_classid }, logger)

	local argv = fq_codel_qdisc_argv('add', dev, parent_classid, fq)
	return must_cmd(argv, logger, 'fq_codel qdisc add on ' .. parent_classid)
end

local function reconcile_default_fq_codel(dev, ids, fq_cfg, logger)
	local parent = classid(ids.inner_major, ids.default_minor)

	-- Declarative semantics:
	--   * table  => ensure fq_codel exists with those settings
	--   * false/nil => ensure no leaf qdisc is attached
	if fq_cfg == nil or fq_cfg == false then
		try_cmd({ 'tc', 'qdisc', 'del', 'dev', dev, 'parent', parent }, logger)
		return true, nil
	end

	return fq_codel_qdisc_replace(dev, parent, fq_cfg, logger)
end

------------------------------------------------------------------------
-- IFB ingress redirect
------------------------------------------------------------------------

local function ensure_ifb(ifb, logger)
	try_cmd({ 'ip', 'link', 'add', ifb, 'type', 'ifb' }, logger) -- may already exist
	return must_cmd({ 'ip', 'link', 'set', 'dev', ifb, 'up' }, logger, 'ifb up')
end

local function ensure_ingress_redirect(iface, ifb, logger)
	-- Reset ingress qdisc/filter on the real interface to ensure idempotent redirect
	try_cmd({ 'tc', 'qdisc', 'del', 'dev', iface, 'ingress' }, logger)
	local ok, err = must_cmd({ 'tc', 'qdisc', 'add', 'dev', iface, 'handle', 'ffff:', 'ingress' }, logger,
		'add ingress qdisc')
	if not ok then return nil, err end

	-- Redirect all IPv4 ingress to IFB
	return must_cmd({
		'tc', 'filter', 'add', 'dev', iface, 'parent', 'ffff:',
		'protocol', 'ip', 'u32',
		'match', 'u32', '0', '0',
		'action', 'mirred', 'egress', 'redirect', 'dev', ifb,
	}, logger, 'add mirred redirect')
end

------------------------------------------------------------------------
-- Base scaffold (root/pool/inner qdisc + hash link)
------------------------------------------------------------------------

local function direction_params(kind, cfg)
	-- Defaults are opinionated, but overrideable.
	if kind == 'egress' then
		local m = cfg.match or 'dst'
		return {
			match_field = m, -- 'dst' usually correct for egress shaping per destination host on that subnet
			hash_at     = (m == 'src') and 12 or 16,
		}
	else
		local m = cfg.match or 'src'
		return {
			match_field = m, -- often 'src' for lab tests; use 'dst' if shaping downloads to LAN hosts on WAN IFB
			hash_at     = (m == 'src') and 12 or 16,
		}
	end
end

local function scaffold_signature(kind, spec, cfg, ids, dev)
	local dp = direction_params(kind, cfg)
	return table.concat({
		kind,
		dev,
		spec.cidr,
		dp.match_field,
		tostring(dp.hash_at),
		tostring(ids.root_major), tostring(ids.pool_minor),
		tostring(ids.inner_major), tostring(ids.inner_root_minor),
		tostring(ids.default_minor), tostring(ids.base_minor),
		tostring(ids.host_table_handle),
		tostring(ids.outer_prio), tostring(ids.link_prio), tostring(ids.host_prio),
	}, '|')
end

local function rebuild_scaffold(kind, spec, cfg, dev, ids, logger)
	local net_u, pfx  = spec.net_u, spec.pfx
	local dp          = direction_params(kind, cfg)
	local match_field = dp.match_field
	local hash_at     = tostring(dp.hash_at)

	local net_s       = ipv4_to_string(net_u) .. '/' .. tostring(pfx)

	-- Clear root qdisc on shaped device and recreate
	try_cmd({ 'tc', 'qdisc', 'del', 'dev', dev, 'root' }, logger)

	-- root htb
	local ok, err = must_cmd({
		'tc', 'qdisc', 'add', 'dev', dev, 'root',
		'handle', qdisc_handle(ids.root_major),
		'htb',
		-- Root qdisc default must point to a real class under 1: .
		-- Use the root class so non-matching traffic falls back safely.
		'default', tostring(ids.root_class_minor),
	}, logger, 'root htb qdisc')
	if not ok then return nil, err end

	-- root + pool classes
	ok, err = htb_class_replace(
		dev,
		qdisc_handle(ids.root_major), -- IMPORTANT: root class hangs off qdisc handle "1:", not "1:0"
		classid(ids.root_major, ids.root_class_minor),
		cfg.root_class or {
			rate = (cfg.root_rate or '1gbit'),
			ceil = (cfg.root_ceil or cfg.root_rate or '1gbit'),
		},
		logger
	)
	if not ok then return nil, err end

	ok, err = htb_class_replace(dev, classid(ids.root_major, ids.root_class_minor),
		classid(ids.root_major, ids.pool_minor),
		cfg.pool_class or {
			rate   = (cfg.pool_rate or cfg.rate or '1gbit'),
			ceil   = (cfg.pool_ceil or cfg.ceil or cfg.pool_rate or cfg.rate or '1gbit'),
			burst  = cfg.pool_burst,
			cburst = cfg.pool_cburst,
		}, logger)
	if not ok then return nil, err end

	-- inner htb under pool class
	ok, err = must_cmd({
		'tc', 'qdisc', 'add', 'dev', dev,
		'parent', classid(ids.root_major, ids.pool_minor),
		'handle', qdisc_handle(ids.inner_major),
		'htb',
		'default', tostring(ids.default_minor),
	}, logger, 'inner htb qdisc')
	if not ok then return nil, err end

	ok, err = htb_class_replace(dev, qdisc_handle(ids.inner_major), classid(ids.inner_major, ids.inner_root_minor),
		{
			rate   = (cfg.pool_rate or cfg.rate or '1gbit'),
			ceil   = (cfg.pool_ceil or cfg.ceil or cfg.pool_rate or cfg.rate or '1gbit'),
			burst  = cfg.pool_burst,
			cburst = cfg.pool_cburst,
		}, logger)
	if not ok then return nil, err end

	-- default inner class for unmatched hosts in subnet
	ok, err = htb_class_replace(dev, classid(ids.inner_major, ids.inner_root_minor),
		classid(ids.inner_major, ids.default_minor),
		cfg.default_class or {
			rate   = (cfg.default_rate or cfg.host_rate or '1gbit'),
			ceil   = (cfg.default_ceil or cfg.host_ceil or cfg.default_rate or cfg.host_rate or '1gbit'),
			burst  = (cfg.default_burst or cfg.host_burst),
			cburst = (cfg.default_cburst or cfg.host_cburst),
		}, logger)
	if not ok then return nil, err end

	ok, err = reconcile_default_fq_codel(dev, ids, cfg.default_fq_codel, logger)
	if not ok then return nil, err end

	-- Outer prefix gate: root -> pool
	ok, err = must_cmd({
		'tc', 'filter', 'add', 'dev', dev,
		'parent', qdisc_handle(ids.root_major),
		'protocol', 'ip',
		'prio', tostring(ids.outer_prio),
		'u32', 'match', 'ip', match_field, net_s,
		'flowid', classid(ids.root_major, ids.pool_minor),
	}, logger, 'outer prefix gate')
	if not ok then return nil, err end

	return true, nil
end

------------------------------------------------------------------------
-- Host plan (validate + class id mapping)
------------------------------------------------------------------------

local function build_host_plan(spec, cfg, ids)
	local hosts_raw = cfg.hosts
	if hosts_raw == nil then
		hosts_raw = {}
	end
	if not is_plain_table(hosts_raw) then
		return nil, 'hosts must be a table keyed by IPv4 string'
	end

	-- Validate override entries first. In all_hosts mode, this catches typos/out-of-subnet
	-- addresses even if they would not be generated naturally.
	local overrides = {}
	local override_keys = sorted_keys(hosts_raw)
	for i = 1, #override_keys do
		local ip_s = override_keys[i]
		local hcfg = hosts_raw[ip_s]

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

		overrides[ip_s] = hcfg
	end

	local function make_host_record(ip_s, hcfg)
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

		local bucket = band(ip_u, 0xff) -- last octet bucket, matches hash mask 0x000000ff at {12|16}
		local minor  = ids.base_minor + off
		if minor == ids.default_minor then
			return nil, 'classid collision for host ' .. ip_s .. '; change base_minor/default_minor'
		end
		if minor > 65534 then
			return nil, 'class minor too large for host ' .. ip_s
		end

		local eff = {
			rate    = hcfg.rate or cfg.host_rate or '1mbit',
			ceil    = hcfg.ceil or cfg.host_ceil or hcfg.rate or cfg.host_rate or '1mbit',
			burst   = hcfg.burst or cfg.host_burst,
			cburst  = hcfg.cburst or cfg.host_cburst,
			prio    = hcfg.prio or cfg.host_prio,
			quantum = hcfg.quantum or cfg.host_quantum,
		}

		local fq = nil
		if hcfg.fq_codel == false then
			fq = false
		elseif is_plain_table(hcfg.fq_codel) or is_plain_table(cfg.fq_codel) then
			fq = shallow_copy(cfg.fq_codel or {})
			if is_plain_table(hcfg.fq_codel) then
				for k, v in pairs(hcfg.fq_codel) do fq[k] = v end
			end
		end

		return {
			ip_s    = ip_s,
			ip_u    = ip_u,
			offset  = off,
			bucket  = bucket,
			minor   = minor,
			classid = classid(ids.inner_major, minor),
			htb     = eff,
			fq      = fq,
		}, nil
	end

	local out = {}
	local all_hosts = (cfg.all_hosts == true)

	if all_hosts then
		local total = host_count_from_prefix(spec.pfx)
		for off = 0, total - 1 do
			if not should_skip_specials(spec.pfx, off, total, cfg) then
				local ip_s = ipv4_to_string((tonumber(spec.net_u) or 0) + off)
				local hcfg = overrides[ip_s] or {}
				local rec, err = make_host_record(ip_s, hcfg)
				if not rec then return nil, err end
				out[ip_s] = rec
			end
		end
	else
		for i = 1, #override_keys do
			local ip_s = override_keys[i]
			local rec, err = make_host_record(ip_s, overrides[ip_s] or {})
			if not rec then return nil, err end
			out[ip_s] = rec
		end
	end

	return out, nil
end

local function host_membership_signature(plan)
	local ks = sorted_keys(plan)
	local parts = {}
	for i = 1, #ks do
		local p = plan[ks[i]]
		parts[#parts + 1] = p.ip_s .. '>' .. tostring(p.minor) .. '@' .. tostring(p.bucket)
	end
	return table.concat(parts, '|')
end

------------------------------------------------------------------------
-- Host filter table reconcile (rebuild only host rules/table)
------------------------------------------------------------------------

local function rebuild_host_filters(kind, spec, cfg, dev, ids, plan, logger)
	local dp          = direction_params(kind, cfg)
	local match_field = dp.match_field
	local hash_at     = tostring(dp.hash_at)
	local net_s       = ipv4_to_string(spec.net_u) .. '/' .. tostring(spec.pfx)

	if ids.link_prio == ids.host_prio then
		return nil, 'link_prio and host_prio must differ'
	end

	-- Clear both filter priorities on the inner HTB parent.
	-- link_prio owns the hash-link rule; host_prio owns the u32 table + exact host rules.
	try_cmd({
		'tc', 'filter', 'del', 'dev', dev,
		'parent', qdisc_handle(ids.inner_major),
		'protocol', 'ip',
		'prio', tostring(ids.link_prio),
	}, logger)

	try_cmd({
		'tc', 'filter', 'del', 'dev', dev,
		'parent', qdisc_handle(ids.inner_major),
		'protocol', 'ip',
		'prio', tostring(ids.host_prio),
	}, logger)

	-- Rebuild the inner host filter structure in one (chunked) tc -batch sequence:
	--   1) hash table
	--   2) hash-link filter
	--   3) exact /32 host rules
	local batch_cmds = {}

	batch_cmds[#batch_cmds + 1] = {
		'tc', 'filter', 'add', 'dev', dev,
		'parent', qdisc_handle(ids.inner_major),
		'protocol', 'ip',
		'prio', tostring(ids.host_prio),
		'handle', tostring(ids.host_table_handle) .. ':', -- e.g. "1:"
		'u32', 'divisor', '256',
	}

	batch_cmds[#batch_cmds + 1] = {
		'tc', 'filter', 'add', 'dev', dev,
		'parent', qdisc_handle(ids.inner_major),
		'protocol', 'ip',
		'prio', tostring(ids.link_prio),
		'u32',
		'link', tostring(ids.host_table_handle) .. ':',
		'hashkey', 'mask', '0x000000ff', 'at', hash_at,
		'match', 'ip', match_field, net_s,
	}

	-- Add exact /32 rules into the appropriate bucket, one per host
	local ips = sorted_keys(plan)
	for i = 1, #ips do
		local rec = plan[ips[i]]
		batch_cmds[#batch_cmds + 1] = {
			'tc', 'filter', 'add', 'dev', dev,
			'parent', qdisc_handle(ids.inner_major),
			'protocol', 'ip',
			'prio', tostring(ids.host_prio),
			'u32',
			'ht', u32_bucket_ref(ids.host_table_handle, rec.bucket), -- bucket is hex
			'match', 'ip', match_field, rec.ip_s .. '/32',
			'flowid', rec.classid,
		}
	end

	local ok, err = must_tc_batch_chunked(batch_cmds, logger, 'rebuild host filters')
	if not ok then return nil, err end

	return true, nil
end

------------------------------------------------------------------------
-- Class/qdisc reconcile (incremental)
------------------------------------------------------------------------

local function reconcile_host_classes(dev, ids, prev_plan, new_plan, logger)
	prev_plan = prev_plan or {}

	-- Remove stale classes first (leaf qdisc then class)
	for ip_s, old in pairs(prev_plan) do
		if not new_plan[ip_s] then
			try_cmd({ 'tc', 'qdisc', 'del', 'dev', dev, 'parent', old.classid }, logger)
			try_cmd({ 'tc', 'class', 'del', 'dev', dev, 'classid', old.classid }, logger)
		end
	end

	-- Upsert current classes in bulk (tc -batch), then handle per-host fq_codel leaves.
	-- fq_codel leaf qdiscs remain on the per-command path for safety across older iproute2/kernel combos.
	local class_cmds = {}
	local ips = sorted_keys(new_plan)
	for i = 1, #ips do
		local rec = new_plan[ips[i]]
		class_cmds[#class_cmds + 1] =
			htb_class_replace_argv(dev, classid(ids.inner_major, ids.inner_root_minor), rec.classid, rec.htb)
	end

	local ok, err = must_tc_batch_chunked(class_cmds, logger, 'reconcile host htb classes')
	if not ok then return nil, err end

	for i = 1, #ips do
		local rec = new_plan[ips[i]]

		if rec.fq == false then
			-- Explicitly remove leaf qdisc
			try_cmd({ 'tc', 'qdisc', 'del', 'dev', dev, 'parent', rec.classid }, logger)
		elseif is_plain_table(rec.fq) then
			ok, err = fq_codel_qdisc_replace(dev, rec.classid, rec.fq, logger)
			if not ok then return nil, err end
		end
	end

	return true, nil
end

local function host_limits_signature(plan)
	local ks = sorted_keys(plan)
	local parts = {}
	for i = 1, #ks do
		local p = plan[ks[i]]
		parts[#parts + 1] =
			p.ip_s ..
			'|r=' .. tostring(p.htb.rate) ..
			'|c=' .. tostring(p.htb.ceil) ..
			'|b=' .. tostring(p.htb.burst) ..
			'|cb=' .. tostring(p.htb.cburst) ..
			'|p=' .. tostring(p.htb.prio) ..
			'|q=' .. tostring(p.htb.quantum) ..
			'|fq=' .. fq_signature(p.fq)
	end
	return table.concat(parts, '||')
end

local function prune_iface_state(iface)
	local st = STATE[iface]
	if not st then return end
	if st.egress == nil and st.ingress == nil then
		STATE[iface] = nil
	end
end

local function clear_direction(iface, kind, cfg, logger)
	local per_iface = STATE[iface]
	local prev      = per_iface and per_iface[kind] or nil

	if kind == 'egress' then
		-- This module owns the tc root hierarchy on the interface.
		try_cmd({ 'tc', 'qdisc', 'del', 'dev', iface, 'root' }, logger)
		if per_iface then per_iface.egress = nil end
		prune_iface_state(iface)
		return true, nil
	end

	-- kind == 'ingress'
	local ifb = nil
	if is_plain_table(cfg) and type(cfg.ifb) == 'string' and cfg.ifb ~= '' then
		ifb = cfg.ifb
	elseif prev and type(prev.ifb) == 'string' and prev.ifb ~= '' then
		ifb = prev.ifb
	else
		ifb = sanitise_ifb_name(iface)
	end

	-- Remove ingress redirect on the real interface and shaped qdisc on the IFB.
	try_cmd({ 'tc', 'qdisc', 'del', 'dev', iface, 'ingress' }, logger)
	try_cmd({ 'tc', 'qdisc', 'del', 'dev', ifb, 'root' }, logger)

	if per_iface then per_iface.ingress = nil end
	prune_iface_state(iface)
	return true, nil
end

------------------------------------------------------------------------
-- Per-direction apply
------------------------------------------------------------------------

local function apply_direction(iface, kind, spec, cfg, logger)
	-- Declarative semantics:
	--   * missing cfg        => ensure direction is absent
	--   * cfg.enabled=false  => ensure direction is absent
	if cfg == nil or cfg.enabled == false then
		return clear_direction(iface, kind, cfg, logger)
	end

	local ids = shallow_copy(default_ids())
	for k, v in pairs(cfg.ids or {}) do ids[k] = v end

	local dev = iface
	local ifb = nil
	if kind == 'ingress' then
		ifb = cfg.ifb or sanitise_ifb_name(iface)
		local ok, err = ensure_ifb(ifb, logger)
		if not ok then return nil, err end
		ok, err = ensure_ingress_redirect(iface, ifb, logger)
		if not ok then return nil, err end
		dev = ifb
	end

	local per_iface = STATE[iface] or {}
	STATE[iface] = per_iface
	local st = per_iface[kind] or {}
	per_iface[kind] = st

	local sig = scaffold_signature(kind, spec, cfg, ids, dev)
	local need_rebuild_scaffold = (st.sig ~= sig) or (st.dev ~= dev)

	if need_rebuild_scaffold then
		local ok, err = rebuild_scaffold(kind, spec, cfg, dev, ids, logger)
		if not ok then return nil, err end
		st.sig = sig
		st.dev = dev
		st.ifb = ifb
		st.ids = shallow_copy(ids)
		st.hosts = nil
		st.hosts_membership_sig = nil
		st.hosts_limits_sig = nil
	end

	-- Keep top-level pool/default classes up to date incrementally even without scaffold rebuild
	local ok, err
	ok, err = htb_class_replace(dev, classid(ids.root_major, ids.root_class_minor),
		classid(ids.root_major, ids.pool_minor),
		cfg.pool_class or {
			rate   = (cfg.pool_rate or cfg.rate or '1gbit'),
			ceil   = (cfg.pool_ceil or cfg.ceil or cfg.pool_rate or cfg.rate or '1gbit'),
			burst  = cfg.pool_burst,
			cburst = cfg.pool_cburst,
		}, logger)
	if not ok then return nil, err end

	ok, err = htb_class_replace(dev, qdisc_handle(ids.inner_major), classid(ids.inner_major, ids.inner_root_minor),
		{
			rate   = (cfg.pool_rate or cfg.rate or '1gbit'),
			ceil   = (cfg.pool_ceil or cfg.ceil or cfg.pool_rate or cfg.rate or '1gbit'),
			burst  = cfg.pool_burst,
			cburst = cfg.pool_cburst,
		}, logger)
	if not ok then return nil, err end

	ok, err = htb_class_replace(dev, classid(ids.inner_major, ids.inner_root_minor),
		classid(ids.inner_major, ids.default_minor),
		cfg.default_class or {
			rate   = (cfg.default_rate or cfg.host_rate or '1gbit'),
			ceil   = (cfg.default_ceil or cfg.host_ceil or cfg.default_rate or cfg.host_rate or '1gbit'),
			burst  = (cfg.default_burst or cfg.host_burst),
			cburst = (cfg.default_cburst or cfg.host_cburst),
		}, logger)
	if not ok then return nil, err end

	ok, err = reconcile_default_fq_codel(dev, ids, cfg.default_fq_codel, logger)
	if not ok then return nil, err end

	local plan, perr = build_host_plan(spec, cfg, ids)
	if not plan then return nil, perr end

	local membership_sig     = host_membership_signature(plan)
	local limits_sig         = host_limits_signature(plan)

	local membership_changed = need_rebuild_scaffold or (st.hosts_membership_sig ~= membership_sig)
	local limits_changed     = need_rebuild_scaffold or (st.hosts_limits_sig ~= limits_sig)

	-- Rebuild host filter rules only if membership changed (or scaffold rebuilt)
	if membership_changed then
		ok, err = rebuild_host_filters(kind, spec, cfg, dev, ids, plan, logger)
		if not ok then return nil, err end
		st.hosts_membership_sig = membership_sig
	end

	-- Reconcile host classes/qdiscs if membership or limits changed
	if membership_changed or limits_changed then
		ok, err = reconcile_host_classes(dev, ids, st.hosts or {}, plan, logger)
		if not ok then return nil, err end
		st.hosts_limits_sig = limits_sig
	end

	st.hosts = plan
	st.ids   = shallow_copy(ids)
	st.dev   = dev
	st.ifb   = ifb

	return true, nil
end

------------------------------------------------------------------------
-- Public API
------------------------------------------------------------------------

--- Apply bi-directional per-host shaping.
---
--- spec = {
---   iface = "eth2",
---   subnet = "10.12.0.0/20",
---   log = function(level, payload) ... end, -- optional
---
---   egress = {
---     enabled = true,
---     match = "dst",              -- default "dst"
---     pool_rate = "100mbit",
---     pool_ceil = "100mbit",
---     pool_burst = "64kb",
---     host_rate = "2mbit",        -- defaults for hosts
---     host_ceil = "5mbit",
---     host_burst = "32kb",
---     host_cburst = "32kb",
---     fq_codel = { flows=1024, limit=10240, memory_limit="16Mb", target="5ms", interval="100ms" },
---     default_rate = "100mbit",   -- unmatched hosts in subnet (optional)
---     default_ceil = "100mbit",
---
---     -- Expand to every host in the subnet (except network/broadcast by default for /0../30)
---     all_hosts = true,
---     include_network = false,    -- optional; default false
---     include_broadcast = false,  -- optional; default false
---
---     -- Optional per-host overrides (also the full host set when all_hosts=false)
---     hosts = {
---       ["10.12.0.2"]  = { rate="1mbit", ceil="2mbit", burst="16kb" },
---       ["10.12.15.2"] = { rate="3mbit", ceil="4mbit", fq_codel={ flows=2048, memory_limit="32Mb" } },
---     },
---   },
---
---   ingress = {
---     enabled = true,
---     ifb = "ifb_eth2",           -- optional (auto if omitted)
---     match = "src",              -- choose "dst" if shaping downloads to LAN hosts on WAN IFB
---     pool_rate = "100mbit",
---     pool_ceil = "100mbit",
---     host_rate = "2mbit",
---     host_ceil = "5mbit",
---     host_burst = "32kb",
---     fq_codel = { flows=1024, limit=10240, memory_limit="16Mb" },
---     all_hosts = true,
---     hosts = { ... same shape (overrides) ... }
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

	local logger
	if type(spec.log) == 'function' then
		logger = spec.log
	end

	local parsed = {
		cidr  = cidr,
		net_u = net_u,
		pfx   = pfx,
	}

	local ok, err = apply_direction(iface, 'egress', parsed, spec.egress, logger)
	if not ok then return nil, 'egress: ' .. tostring(err) end

	ok, err = apply_direction(iface, 'ingress', parsed, spec.ingress, logger)
	if not ok then return nil, 'ingress: ' .. tostring(err) end

	return true, nil
end

--- Clear shaping on an interface (egress root + ingress redirect; IFB root if known).
function M.clear(iface, opts)
	opts = opts or {}
	if type(iface) ~= 'string' or iface == '' then
		return nil, 'iface is required'
	end
	local logger = type(opts.log) == 'function' and opts.log or nil

	local st = STATE[iface]
	local ifb = opts.ifb or (st and st.ingress and st.ingress.ifb) or sanitise_ifb_name(iface)

	try_cmd({ 'tc', 'qdisc', 'del', 'dev', iface, 'root' }, logger)
	try_cmd({ 'tc', 'qdisc', 'del', 'dev', iface, 'ingress' }, logger)
	try_cmd({ 'tc', 'qdisc', 'del', 'dev', ifb, 'root' }, logger)

	if opts.delete_ifb then
		try_cmd({ 'ip', 'link', 'del', ifb }, logger)
	end

	STATE[iface] = nil
	return true, nil
end

return M
