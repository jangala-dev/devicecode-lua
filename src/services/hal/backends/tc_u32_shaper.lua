-- services/hal/backends/tc_u32_shaper.lua
--
-- Strict per-host HTB shaper using u32 hashing + exact /32 rules.
--
-- Features
--   * Egress shaping on iface (match dst by default)
--   * Ingress shaping via IFB (mirror ingress -> shape IFB egress)
--   * Prefix support: /20 .. /32 (up to 4096 addresses; /20 practical ceiling)
--   * Declarative host set:
--       - all_hosts=true expands to every address in the subnet
--       - hosts={} becomes an override table in all_hosts mode
--       - by default, network/broadcast are skipped for /0.. /30
--         (include_network/include_broadcast to include them)
--   * True deltas:
--       - host filters updated only when membership changes
--       - host HTB classes updated only when changed/new
--       - per-host fq_codel leaves updated only when changed/new (removed when deleted)
--   * Bulk programming via tc -batch for filters, HTB classes, and fq_codel add/del
--
-- Notes
--   * fq_codel leaves are applied via delete+add (no qdisc replace) for compatibility.
--   * Bucket-local filter deletes are attempted; if unsupported, the filter table is rebuilt.
--   * Lua 5.1 / LuaJIT compatible.

local fibers   = require 'fibers'
local file_mod = require 'fibers.io.file'
local exec_mod = require 'fibers.io.exec'

local bit = require 'bit'

local perform  = fibers.perform
local unpack  = _G.unpack or rawget(table, 'unpack')


local band, bor, bxor, lshift, rshift = bit.band, bit.bor, bit.bxor, bit.lshift, bit.rshift

local M = {}

local TC_BATCH_CHUNK = 512

-- STATE[iface] = { egress = st, ingress = st }
-- st = { sig=..., dev=..., ifb?=..., ids=..., hosts=plan, dirty?=true }
local STATE = {}

--------------------------------------------------------------------------------
-- Small helpers
--------------------------------------------------------------------------------

local function is_plain_table(x) return type(x) == 'table' and getmetatable(x) == nil end

local function argv_push(argv, ...)
	local n = select('#', ...)
	for i = 1, n do argv[#argv + 1] = select(i, ...) end
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

-- 32-bit multiply mod 2^32 without relying on 64-bit integer arithmetic.
local function mul32(a, b)
	a = tonumber(a) or 0
	b = tonumber(b) or 0
	local a_lo = band(a, 0xffff)
	local a_hi = rshift(a, 16)
	local b_lo = band(b, 0xffff)
	local b_hi = rshift(b, 16)

	local lo  = a_lo * b_lo
	local mid = a_hi * b_lo + a_lo * b_hi
	return band(lo + lshift(mid, 16), 0xffffffff)
end

-- 32-bit FNV-1a (stable across runs; used for IFB suffixes).
local function fnv1a32(s)
	s = tostring(s or '')
	local h = 2166136261
	for i = 1, #s do
		h = bxor(h, s:byte(i))
		h = mul32(h, 16777619)
	end
	return band(h, 0xffffffff)
end

local function ifb_suffix_hex4(iface)
	return string.format('%04x', band(fnv1a32(iface), 0xffff))
end

local function sanitise_ifb_name(iface)
	-- Linux ifname max is 15 chars. "ifb_" + iface may overflow.
	local raw = tostring(iface or '')

	-- Keep conservative characters for IFB device names.
	local clean = raw:gsub('[^%w]', '_')
	if clean == '' then clean = '_' end

	local base = 'ifb_' .. clean
	if #base <= 15 then
		return base
	end

	-- Collision-avoiding truncation: ifb_<prefix>_<hash>
	-- Must be <= 15 chars.
	local suf = ifb_suffix_hex4(raw)          -- 4 chars
	local prefix_len = 15 - 4 - 1 - #suf      -- "ifb_" + "_" + suf
	if prefix_len < 1 then prefix_len = 1 end
	return 'ifb_' .. clean:sub(1, prefix_len) .. '_' .. suf
end

local function str_contains(hay, needle)
	return type(hay) == 'string' and hay:find(needle, 1, true) ~= nil
end

local function log(logger, level, payload)
	if type(logger) == 'function' then logger(level, payload) end
end

--------------------------------------------------------------------------------
-- Command runners (single + tc -batch)
--------------------------------------------------------------------------------

local function run_cmd(argv)
	local cmd = exec_mod.command(unpack(argv))
	local out, st, code, sig, err = perform(cmd:combined_output_op())
	local ok = (st == 'exited' and code == 0)
	return ok, out or '', err, code, st, sig
end

local function is_benign_try_error(argv, out, err, _code)
	local a1, a2, a3 = argv[1], argv[2], argv[3]
	local msg = (out or '') .. '\n' .. tostring(err or '')

	if a1 == 'tc' and a2 == 'qdisc' and a3 == 'del' then
		if str_contains(msg, 'Cannot delete qdisc with handle of zero.') then return true end
		if str_contains(msg, 'Cannot find specified qdisc on specified device.') then return true end
		if str_contains(msg, 'Error: Invalid handle.') then return true end
	end

	if a1 == 'tc' and a2 == 'filter' and a3 == 'del' then
		if str_contains(msg, 'Cannot find specified filter chain.') then return true end
		if str_contains(msg, 'RTNETLINK answers: No such file or directory') then return true end
	end

	if a1 == 'ip' and a2 == 'link' and a3 == 'add' then
		if str_contains(msg, 'File exists') then return true end
	end

	return false
end

local function try_cmd(argv, logger)
	local ok, out, err, code = run_cmd(argv)
	if not ok and not is_benign_try_error(argv, out, err, code) then
		log(logger, 'warn', {
			what = 'cmd_failed',
			cmd  = table.concat(argv, ' '),
			out  = out ~= '' and out or nil,
			err  = err and tostring(err) or nil,
			code = code,
		})
	end
	return ok, out, err, code
end

local function must_cmd(argv, logger, label)
	local ok, out, err, code = run_cmd(argv)
	if not ok then
		log(logger, 'error', {
			what  = 'cmd_failed_fatal',
			label = label,
			cmd   = table.concat(argv, ' '),
			out   = out ~= '' and out or nil,
			err   = err and tostring(err) or nil,
			code  = code,
		})
		return nil, (label or table.concat(argv, ' ')) .. ': ' .. tostring(err or out or ('exit ' .. tostring(code)))
	end
	return true, nil
end

local function tc_batch_line(argv)
	-- tc -batch lines omit the leading "tc".
	if type(argv) ~= 'table' or argv[1] ~= 'tc' then
		return nil, 'argv must begin with "tc"'
	end
	local parts = {}
	for i = 2, #argv do
		local s = tostring(argv[i])
		if s:find('[\r\n]') then return nil, 'newline in token' end
		if s:find('%s') then return nil, 'whitespace in token: ' .. s end
		parts[#parts + 1] = s
	end
	return table.concat(parts, ' '), nil
end

local function run_tc_batch(cmds)
	if type(cmds) ~= 'table' or #cmds == 0 then
		return true, '', nil, 0
	end

	local lines = {}
	for i = 1, #cmds do
		local line, lerr = tc_batch_line(cmds[i])
		if not line then
			return nil, '', 'batch encode failed: ' .. tostring(lerr), 255
		end
		lines[#lines + 1] = line
	end

	-- Use fibers.io.file tmpfile to avoid blocking Lua I/O. Keep the file open
	-- (and flushed) while tc reads it; close afterwards to unlink.
	local tmp, terr = file_mod.tmpfile('rw-r--r--')
	if not tmp then
		return nil, '', 'tmpfile failed: ' .. tostring(terr), 255
	end

	local path = tmp:filename()
	if not path or path == '' then
		tmp:close()
		return nil, '', 'tmpfile has no filename', 255
	end

	local content = table.concat(lines, '\n') .. '\n'
	local n, werr = tmp:write(content)
	if not n then
		tmp:close()
		return nil, '', 'write batch file failed: ' .. tostring(werr), 255
	end

	local fok, ferr = tmp:flush()
	if not fok then
		tmp:close()
		return nil, '', 'flush batch file failed: ' .. tostring(ferr), 255
	end

	local ok, out, err, code = run_cmd({ 'tc', '-batch', path })
	tmp:close() -- unlink-on-close
	return ok, out, err, code
end

local function must_tc_batch_chunked(cmds, logger, label, chunk_size)
	chunk_size = tonumber(chunk_size) or TC_BATCH_CHUNK
	if chunk_size < 1 then chunk_size = TC_BATCH_CHUNK end
	if #cmds == 0 then return true, nil end

	local i, chunk_no = 1, 0
	while i <= #cmds do
		chunk_no = chunk_no + 1
		local j = math.min(i + chunk_size - 1, #cmds)
		local chunk = {}
		for k = i, j do chunk[#chunk + 1] = cmds[k] end

		local ok, out, err, code = run_tc_batch(chunk)
		if not ok then
			log(logger, 'error', {
				what  = 'batch_failed_fatal',
				label = label,
				chunk = chunk_no,
				count = #chunk,
				out   = out ~= '' and out or nil,
				err   = err and tostring(err) or nil,
				code  = code,
			})
			return nil, (label or 'tc -batch') .. ': ' .. tostring(err or out or ('exit ' .. tostring(code)))
		end

		i = j + 1
	end

	return true, nil
end

--------------------------------------------------------------------------------
-- IPv4 helpers
--------------------------------------------------------------------------------

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
	return string.format('%d.%d.%d.%d',
		band(rshift(u, 24), 0xff),
		band(rshift(u, 16), 0xff),
		band(rshift(u, 8), 0xff),
		band(u, 0xff))
end

local function mask_from_prefix(pfx)
	pfx = tonumber(pfx)
	if not pfx or pfx < 0 or pfx > 32 then return nil end
	if pfx == 0 then return 0 end
	local m = 0
	for i = 1, pfx do m = bor(m, lshift(1, 32 - i)) end
	return m
end

local function parse_cidr(cidr)
	if type(cidr) ~= 'string' then return nil, nil, 'cidr must be a string' end
	local ip_s, pfx_s = cidr:match('^([^/]+)/(%d+)$')
	if not ip_s then return nil, nil, 'bad cidr format' end
	local ip = parse_ipv4(ip_s)
	local pfx = tonumber(pfx_s)
	if not ip or not pfx then return nil, nil, 'bad cidr value' end
	if pfx < 20 or pfx > 32 then return nil, nil, 'supported prefixes are /20.. /32' end
	local mask = mask_from_prefix(pfx)
	return band(ip, mask), pfx, nil
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
	return (off >= 0) and off or nil
end

local function should_skip_specials(pfx, off, total, cfg)
	if pfx >= 31 then return false end
	if off == 0 and not (cfg and cfg.include_network) then return true end
	if off == total - 1 and not (cfg and cfg.include_broadcast) then return true end
	return false
end

--------------------------------------------------------------------------------
-- u32 helpers
--------------------------------------------------------------------------------

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

--------------------------------------------------------------------------------
-- Signatures (per-host only; built once when planning)
--------------------------------------------------------------------------------

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

local function htb_signature(htb)
	if not is_plain_table(htb) then return '' end
	return table.concat({
		'r=' .. tostring(htb.rate),
		'c=' .. tostring(htb.ceil),
		'b=' .. tostring(htb.burst),
		'cb=' .. tostring(htb.cburst),
		'p=' .. tostring(htb.prio),
		'q=' .. tostring(htb.quantum),
	}, '|')
end

--------------------------------------------------------------------------------
-- tc layout helpers
--------------------------------------------------------------------------------

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

local function classid(major, minor) return tostring(major) .. ':' .. tostring(minor) end
local function qdisc_handle(major) return tostring(major) .. ':' end

local function bool_flag(v, yes, no)
	if v == nil then return nil end
	return v and yes or no
end

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

local function fq_qdisc_argv(op, dev, parent_classid, fq)
	local argv = { 'tc', 'qdisc', op, 'dev', dev, 'parent', parent_classid }
	append_fq_codel_args(argv, fq)
	return argv
end

--------------------------------------------------------------------------------
-- IFB ingress redirect
--------------------------------------------------------------------------------

local function ensure_ifb(ifb, logger)
	try_cmd({ 'ip', 'link', 'add', ifb, 'type', 'ifb' }, logger)
	return must_cmd({ 'ip', 'link', 'set', 'dev', ifb, 'up' }, logger, 'ifb up')
end

local function ensure_ingress_redirect(iface, ifb, logger)
	try_cmd({ 'tc', 'qdisc', 'del', 'dev', iface, 'ingress' }, logger)
	local ok, err = must_cmd({ 'tc', 'qdisc', 'add', 'dev', iface, 'handle', 'ffff:', 'ingress' }, logger,
		'add ingress qdisc')
	if not ok then return nil, err end

	return must_cmd({
		'tc', 'filter', 'add', 'dev', iface, 'parent', 'ffff:',
		'protocol', 'ip', 'u32',
		'match', 'u32', '0', '0',
		'action', 'mirred', 'egress', 'redirect', 'dev', ifb,
	}, logger, 'add mirred redirect')
end

--------------------------------------------------------------------------------
-- Scaffold + top-level maintenance
--------------------------------------------------------------------------------

local function direction_params(kind, cfg)
	if kind == 'egress' then
		local m = cfg.match or 'dst'
		return { match_field = m, hash_at = (m == 'src') and 12 or 16 }
	end
	local m = cfg.match or 'src'
	return { match_field = m, hash_at = (m == 'src') and 12 or 16 }
end

local function scaffold_signature(kind, spec, cfg, ids, dev)
	local dp = direction_params(kind, cfg)
	return table.concat({
		kind, dev, spec.cidr, dp.match_field, tostring(dp.hash_at),
		tostring(ids.root_major), tostring(ids.pool_minor),
		tostring(ids.inner_major), tostring(ids.inner_root_minor),
		tostring(ids.default_minor), tostring(ids.base_minor),
		tostring(ids.host_table_handle),
		tostring(ids.outer_prio), tostring(ids.link_prio), tostring(ids.host_prio),
	}, '|')
end

local function reconcile_default_fq(dev, ids, fq_cfg, logger)
	local parent = classid(ids.inner_major, ids.default_minor)
	if fq_cfg == nil or fq_cfg == false then
		try_cmd({ 'tc', 'qdisc', 'del', 'dev', dev, 'parent', parent }, logger)
		return true, nil
	end
	-- delete+add (no replace)
	try_cmd({ 'tc', 'qdisc', 'del', 'dev', dev, 'parent', parent }, logger)
	return must_cmd(fq_qdisc_argv('add', dev, parent, fq_cfg), logger, 'default fq_codel add')
end

local function rebuild_scaffold(kind, spec, cfg, dev, ids, logger)
	local dp = direction_params(kind, cfg)
	local net_s = ipv4_to_string(spec.net_u) .. '/' .. tostring(spec.pfx)

	try_cmd({ 'tc', 'qdisc', 'del', 'dev', dev, 'root' }, logger)

	local cmds = {
		{ 'tc', 'qdisc', 'add', 'dev', dev, 'root',
			'handle', qdisc_handle(ids.root_major),
			'htb', 'default', tostring(ids.root_class_minor) },

		htb_class_replace_argv(dev, qdisc_handle(ids.root_major),
			classid(ids.root_major, ids.root_class_minor),
			cfg.root_class or { rate = (cfg.root_rate or '1gbit'), ceil = (cfg.root_ceil or cfg.root_rate or '1gbit') }),
		htb_class_replace_argv(dev, classid(ids.root_major, ids.root_class_minor),
			classid(ids.root_major, ids.pool_minor),
			cfg.pool_class or {
				rate   = (cfg.pool_rate or cfg.rate or '1gbit'),
				ceil   = (cfg.pool_ceil or cfg.ceil or cfg.pool_rate or cfg.rate or '1gbit'),
				burst  = cfg.pool_burst,
				cburst = cfg.pool_cburst,
			}),

		{ 'tc', 'qdisc', 'add', 'dev', dev,
			'parent', classid(ids.root_major, ids.pool_minor),
			'handle', qdisc_handle(ids.inner_major),
			'htb', 'default', tostring(ids.default_minor) },

		htb_class_replace_argv(dev, qdisc_handle(ids.inner_major),
			classid(ids.inner_major, ids.inner_root_minor),
			{
				rate   = (cfg.pool_rate or cfg.rate or '1gbit'),
				ceil   = (cfg.pool_ceil or cfg.ceil or cfg.pool_rate or cfg.rate or '1gbit'),
				burst  = cfg.pool_burst,
				cburst = cfg.pool_cburst,
			}),

		htb_class_replace_argv(dev, classid(ids.inner_major, ids.inner_root_minor),
			classid(ids.inner_major, ids.default_minor),
			cfg.default_class or {
				rate   = (cfg.default_rate or cfg.host_rate or '1gbit'),
				ceil   = (cfg.default_ceil or cfg.host_ceil or cfg.default_rate or cfg.host_rate or '1gbit'),
				burst  = (cfg.default_burst or cfg.host_burst),
				cburst = (cfg.default_cburst or cfg.host_cburst),
			}),

		{ 'tc', 'filter', 'add', 'dev', dev,
			'parent', qdisc_handle(ids.root_major),
			'protocol', 'ip',
			'prio', tostring(ids.outer_prio),
			'u32', 'match', 'ip', dp.match_field, net_s,
			'flowid', classid(ids.root_major, ids.pool_minor) },
	}

	local ok, err = must_tc_batch_chunked(cmds, logger, 'rebuild scaffold', 128)
	if not ok then return nil, err end
	return reconcile_default_fq(dev, ids, cfg.default_fq_codel, logger)
end

local function apply_top_classes(dev, ids, cfg, logger)
	local cmds = {
		-- Refresh root class as well; otherwise root_rate/root_ceil changes only
		-- take effect on a full scaffold rebuild.
		htb_class_replace_argv(dev, qdisc_handle(ids.root_major),
			classid(ids.root_major, ids.root_class_minor),
			cfg.root_class or {
				rate = (cfg.root_rate or '1gbit'),
				ceil = (cfg.root_ceil or cfg.root_rate or '1gbit'),
			}),
		htb_class_replace_argv(dev, classid(ids.root_major, ids.root_class_minor),
			classid(ids.root_major, ids.pool_minor),
			cfg.pool_class or {
				rate   = (cfg.pool_rate or cfg.rate or '1gbit'),
				ceil   = (cfg.pool_ceil or cfg.ceil or cfg.pool_rate or cfg.rate or '1gbit'),
				burst  = cfg.pool_burst,
				cburst = cfg.pool_cburst,
			}),
		htb_class_replace_argv(dev, qdisc_handle(ids.inner_major),
			classid(ids.inner_major, ids.inner_root_minor),
			{
				rate   = (cfg.pool_rate or cfg.rate or '1gbit'),
				ceil   = (cfg.pool_ceil or cfg.ceil or cfg.pool_rate or cfg.rate or '1gbit'),
				burst  = cfg.pool_burst,
				cburst = cfg.pool_cburst,
			}),
		htb_class_replace_argv(dev, classid(ids.inner_major, ids.inner_root_minor),
			classid(ids.inner_major, ids.default_minor),
			cfg.default_class or {
				rate   = (cfg.default_rate or cfg.host_rate or '1gbit'),
				ceil   = (cfg.default_ceil or cfg.host_ceil or cfg.default_rate or cfg.host_rate or '1gbit'),
				burst  = (cfg.default_burst or cfg.host_burst),
				cburst = (cfg.default_cburst or cfg.host_cburst),
			}),
	}
	local ok, err = must_tc_batch_chunked(cmds, logger, 'top class refresh', 128)
	if not ok then return nil, err end
	return reconcile_default_fq(dev, ids, cfg.default_fq_codel, logger)
end

--------------------------------------------------------------------------------
-- Host plan
--------------------------------------------------------------------------------

local function build_host_plan(spec, cfg, ids)
	local hosts_raw = cfg.hosts
	if hosts_raw == nil then hosts_raw = {} end
	if not is_plain_table(hosts_raw) then
		return nil, 'hosts must be a table keyed by IPv4 string'
	end

	local overrides = {}
	local ok_keys = sorted_keys(hosts_raw)
	for i = 1, #ok_keys do
		local ip_s = ok_keys[i]
		local hcfg = hosts_raw[ip_s]
		if not is_plain_table(hcfg) then
			return nil, 'host entry for ' .. tostring(ip_s) .. ' must be a table'
		end
		local ip_u = parse_ipv4(ip_s)
		if not ip_u then return nil, 'invalid host IP ' .. tostring(ip_s) end
		if not ip_in_subnet(ip_u, spec.net_u, spec.pfx) then
			return nil, 'host ' .. ip_s .. ' is outside subnet ' .. spec.cidr
		end
		overrides[ip_s] = hcfg
	end

	local function make_rec(ip_s, hcfg)
		local ip_u = parse_ipv4(ip_s)
		if not ip_u then return nil, 'invalid host IP ' .. tostring(ip_s) end
		if not ip_in_subnet(ip_u, spec.net_u, spec.pfx) then
			return nil, 'host ' .. ip_s .. ' is outside subnet ' .. spec.cidr
		end

		local off = host_offset(ip_u, spec.net_u)
		if off == nil then return nil, 'failed host offset for ' .. ip_s end
		if off >= host_count_from_prefix(spec.pfx) then return nil, 'host offset out of range for ' .. ip_s end

		local bucket = band(ip_u, 0xff)
		local minor  = ids.base_minor + off
		if minor == ids.default_minor then
			return nil, 'classid collision for host ' .. ip_s .. '; change base_minor/default_minor'
		end
		if minor > 65534 then
			return nil, 'class minor too large for host ' .. ip_s
		end

		local htb = {
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
			htb     = htb,
			fq      = fq,
			htb_sig = htb_signature(htb),
			fq_sig  = fq_signature(fq),
		}, nil
	end

	local out = {}
	if cfg.all_hosts == true then
		local total = host_count_from_prefix(spec.pfx)
		for off = 0, total - 1 do
			if not should_skip_specials(spec.pfx, off, total, cfg) then
				local ip_s = ipv4_to_string((tonumber(spec.net_u) or 0) + off)
				local rec, err = make_rec(ip_s, overrides[ip_s] or {})
				if not rec then return nil, err end
				out[ip_s] = rec
			end
		end
	else
		for i = 1, #ok_keys do
			local ip_s = ok_keys[i]
			local rec, err = make_rec(ip_s, overrides[ip_s] or {})
			if not rec then return nil, err end
			out[ip_s] = rec
		end
	end

	return out, nil
end

--------------------------------------------------------------------------------
-- Deltas (membership + per-host)
--------------------------------------------------------------------------------

local function host_htb_changed(old, new_)
	if not old then return true end
	if old.classid ~= new_.classid then return true end
	return old.htb_sig ~= new_.htb_sig
end

local function host_fq_changed(old, new_)
	if not old then
		return is_plain_table(new_.fq) or (new_.fq == false)
	end
	if old.classid ~= new_.classid then return true end

	local okind = (old.fq == false) and 'false' or (is_plain_table(old.fq) and 'table' or 'nil')
	local nkind = (new_.fq == false) and 'false' or (is_plain_table(new_.fq) and 'table' or 'nil')
	if okind ~= nkind then return true end

	return old.fq_sig ~= new_.fq_sig
end

local function membership_delta(prev_plan, new_plan)
	prev_plan, new_plan = prev_plan or {}, new_plan or {}

	local affected      = {}
	local changed       = false

	-- additions + bucket/class changes
	for ip_s, nrec in pairs(new_plan) do
		local orec = prev_plan[ip_s]
		if not orec then
			affected[nrec.bucket] = true
			changed = true
		else
			if orec.bucket ~= nrec.bucket or orec.classid ~= nrec.classid then
				affected[orec.bucket] = true
				affected[nrec.bucket] = true
				changed = true
			end
		end
	end

	-- removals
	for ip_s, orec in pairs(prev_plan) do
		if not new_plan[ip_s] then
			affected[orec.bucket] = true
			changed = true
		end
	end

	return changed, affected
end

--------------------------------------------------------------------------------
-- Host filters (full + delta)
--------------------------------------------------------------------------------

local function host_rule_argv(dev, ids, match_field, rec)
	return {
		'tc', 'filter', 'add', 'dev', dev,
		'parent', qdisc_handle(ids.inner_major),
		'protocol', 'ip',
		'prio', tostring(ids.host_prio),
		'u32',
		'ht', u32_bucket_ref(ids.host_table_handle, rec.bucket),
		'match', 'ip', match_field, rec.ip_s .. '/32',
		'flowid', rec.classid,
	}
end

local function rebuild_host_filters_full(kind, spec, cfg, dev, ids, plan, logger)
	local dp = direction_params(kind, cfg)
	local net_s = ipv4_to_string(spec.net_u) .. '/' .. tostring(spec.pfx)

	if ids.link_prio == ids.host_prio then
		return nil, 'link_prio and host_prio must differ'
	end

	-- best-effort clear the filter priorities we own
	try_cmd(
		{ 'tc', 'filter', 'del', 'dev', dev, 'parent', qdisc_handle(ids.inner_major), 'protocol', 'ip', 'prio', tostring(
			ids
			.link_prio) }, logger)
	try_cmd(
		{ 'tc', 'filter', 'del', 'dev', dev, 'parent', qdisc_handle(ids.inner_major), 'protocol', 'ip', 'prio', tostring(
			ids
			.host_prio) }, logger)

	local batch = {
		{
			'tc', 'filter', 'add', 'dev', dev,
			'parent', qdisc_handle(ids.inner_major),
			'protocol', 'ip',
			'prio', tostring(ids.host_prio),
			'handle', u32_table_ref(ids.host_table_handle),
			'u32', 'divisor', '256',
		},
		{
			'tc', 'filter', 'add', 'dev', dev,
			'parent', qdisc_handle(ids.inner_major),
			'protocol', 'ip',
			'prio', tostring(ids.link_prio),
			'u32',
			'link', u32_table_ref(ids.host_table_handle),
			'hashkey', 'mask', '0x000000ff', 'at', tostring(dp.hash_at),
			'match', 'ip', dp.match_field, net_s,
		},
	}

	local ips = sorted_keys(plan)
	for i = 1, #ips do
		batch[#batch + 1] = host_rule_argv(dev, ids, dp.match_field, plan[ips[i]])
	end

	return must_tc_batch_chunked(batch, logger, 'rebuild host filters')
end

local function delete_bucket_rules(dev, ids, bucket, logger)
	local argv = {
		'tc', 'filter', 'del', 'dev', dev,
		'parent', qdisc_handle(ids.inner_major),
		'protocol', 'ip',
		'prio', tostring(ids.host_prio),
		'u32',
		'ht', u32_bucket_ref(ids.host_table_handle, bucket),
	}

	local ok, out, err, code = run_cmd(argv)
	if ok or is_benign_try_error(argv, out, err, code) then
		return true, nil
	end

	local msg = tostring(err or out or ('exit ' .. tostring(code)))
	if str_contains(msg, 'Illegal "ht"') or str_contains(msg, 'Illegal \"ht\"') then
		return nil, 'bucket_delete_unsupported'
	end

	log(logger, 'warn', {
		what = 'cmd_failed',
		cmd  = table.concat(argv, ' '),
		out  = out ~= '' and out or nil,
		err  = err and tostring(err) or nil,
		code = code,
	})

	return nil, 'bucket_delete_failed'
end

local function reconcile_host_filters_delta(kind, spec, cfg, dev, ids, prev_plan, new_plan, logger)
	local changed, affected = membership_delta(prev_plan, new_plan)
	if not changed then return true, nil end

	-- Attempt bucket-local delete; fall back to full rebuild if unsupported.
	local buckets = sorted_keys(affected)
	for i = 1, #buckets do
		local b = tonumber(buckets[i])
		local ok, _ = delete_bucket_rules(dev, ids, b, logger)
		if not ok then
			return rebuild_host_filters_full(kind, spec, cfg, dev, ids, new_plan, logger)
		end
	end

	local match_field = direction_params(kind, cfg).match_field
	local batch = {}
	local ips = sorted_keys(new_plan)
	for i = 1, #ips do
		local rec = new_plan[ips[i]]
		if affected[rec.bucket] then
			batch[#batch + 1] = host_rule_argv(dev, ids, match_field, rec)
		end
	end

	return must_tc_batch_chunked(batch, logger, 'reconcile host filters delta')
end

--------------------------------------------------------------------------------
-- Host classes + fq_codel leaves (true deltas; batched)
--------------------------------------------------------------------------------

local function reconcile_host_classes_and_fq(dev, ids, prev_plan, new_plan, logger)
	prev_plan = prev_plan or {}

	local qdisc_del, class_del, class_upd, qdisc_add = {}, {}, {}, {}

	-- stale removals
	for ip_s, old in pairs(prev_plan) do
		if not new_plan[ip_s] then
			if is_plain_table(old.fq) then
				qdisc_del[#qdisc_del + 1] = { 'tc', 'qdisc', 'del', 'dev', dev, 'parent', old.classid }
			end
			class_del[#class_del + 1] = { 'tc', 'class', 'del', 'dev', dev, 'classid', old.classid }
		end
	end

	-- changes/additions
	local ips = sorted_keys(new_plan)
	for i = 1, #ips do
		local rec = new_plan[ips[i]]
		local old = prev_plan[rec.ip_s]

		-- If the host remains present but its classid changes, remove the old class.
		-- (Any old per-host qdisc is handled in host_fq_changed().)
		if old and old.classid ~= rec.classid then
			class_del[#class_del + 1] = { 'tc', 'class', 'del', 'dev', dev, 'classid', old.classid }
		end

		if host_htb_changed(old, rec) then
			class_upd[#class_upd + 1] =
				htb_class_replace_argv(dev, classid(ids.inner_major, ids.inner_root_minor), rec.classid, rec.htb)
		end

		if host_fq_changed(old, rec) then
			if old and is_plain_table(old.fq) then
				-- Delete the qdisc attached to the *old* classid (it may differ from rec.classid).
				qdisc_del[#qdisc_del + 1] = { 'tc', 'qdisc', 'del', 'dev', dev, 'parent', old.classid }
			end
			if is_plain_table(rec.fq) then
				qdisc_add[#qdisc_add + 1] = fq_qdisc_argv('add', dev, rec.classid, rec.fq)
			end
		end
	end

	-- Phase 1: qdisc deletes (batch, with best-effort fallback)
	if #qdisc_del > 0 then
		local ok, _ = must_tc_batch_chunked(qdisc_del, logger, 'fq qdisc deletes', 256)
		if not ok then
			for i = 1, #qdisc_del do try_cmd(qdisc_del[i], logger) end
		end
	end

	-- Phase 2: class deletes
	if #class_del > 0 then
		local ok, err = must_tc_batch_chunked(class_del, logger, 'class deletes', 512)
		if not ok then return nil, err end
	end

	-- Phase 3: class updates
	if #class_upd > 0 then
		local ok, err = must_tc_batch_chunked(class_upd, logger, 'class updates', 512)
		if not ok then return nil, err end
	end

	-- Phase 4: qdisc adds
	if #qdisc_add > 0 then
		local ok, err = must_tc_batch_chunked(qdisc_add, logger, 'fq qdisc adds', 256)
		if not ok then return nil, err end
	end

	return true, nil
end

--------------------------------------------------------------------------------
-- Per-direction apply/clear
--------------------------------------------------------------------------------

local function prune_iface_state(iface)
	local st = STATE[iface]
	if st and st.egress == nil and st.ingress == nil then
		STATE[iface] = nil
	end
end

local function mark_dirty(st)
	-- Force a full rebuild next run (scaffold + filters), to avoid state drift
	-- after partial kernel programming.
	if not st then return end
	st.dirty = true
	st.sig   = nil
	st.hosts = nil
	st.redirect_ready = nil
end

local function fail_dirty(st, err)
	mark_dirty(st)
	return nil, err
end

local function clear_direction(iface, kind, cfg, logger)
	local per_iface = STATE[iface]
	local prev = per_iface and per_iface[kind] or nil

	if kind == 'egress' then
		try_cmd({ 'tc', 'qdisc', 'del', 'dev', iface, 'root' }, logger)
		if per_iface then per_iface.egress = nil end
		prune_iface_state(iface)
		return true, nil
	end

	local ifb
	if is_plain_table(cfg) and type(cfg.ifb) == 'string' and cfg.ifb ~= '' then
		ifb = cfg.ifb
	elseif prev and type(prev.ifb) == 'string' and prev.ifb ~= '' then
		ifb = prev.ifb
	else
		ifb = sanitise_ifb_name(iface)
	end

	try_cmd({ 'tc', 'qdisc', 'del', 'dev', iface, 'ingress' }, logger)
	try_cmd({ 'tc', 'qdisc', 'del', 'dev', ifb, 'root' }, logger)

	if per_iface then per_iface.ingress = nil end
	prune_iface_state(iface)
	return true, nil
end

local function apply_direction(iface, kind, spec, cfg, logger)
	if cfg == nil or cfg.enabled == false then
		return clear_direction(iface, kind, cfg, logger)
	end

	local ids = shallow_copy(default_ids())
	for k, v in pairs(cfg.ids or {}) do ids[k] = v end

	-- Ensure we always have a state record we can mark dirty on error.
	local per_iface = STATE[iface] or {}
	STATE[iface] = per_iface
	local st = per_iface[kind] or {}
	per_iface[kind] = st

	local dev, ifb = iface, nil
	if kind == 'ingress' then
		-- Prefer explicit config; otherwise reuse previous IFB if known; otherwise derive.
		ifb = cfg.ifb or st.ifb or sanitise_ifb_name(iface)

		local ok, err = ensure_ifb(ifb, logger)
		if not ok then return fail_dirty(st, err) end

		-- The ingress redirect (ingress qdisc + mirred filter) is disruptive to rebuild.
		-- Under the assumption that nothing else mutates tc state, we only need to
		-- program it once per iface/ifb pair, and again after an internal failure
		-- (mark_dirty clears redirect_ready) or if the IFB name changes.
		if st.redirect_ready ~= true or st.ifb ~= ifb then
			ok, err = ensure_ingress_redirect(iface, ifb, logger)
			if not ok then return fail_dirty(st, err) end
			st.redirect_ready = true
			st.ifb = ifb
		end

		dev = ifb
	end

	local sig = scaffold_signature(kind, spec, cfg, ids, dev)
	local need_scaffold = (st.dirty == true) or (st.sig ~= sig) or (st.dev ~= dev)

	if need_scaffold then
		local ok, err = rebuild_scaffold(kind, spec, cfg, dev, ids, logger)
		if not ok then return fail_dirty(st, err) end
		st.sig, st.dev, st.ifb, st.ids, st.hosts = sig, dev, ifb, shallow_copy(ids), nil
		st.dirty = nil
	else
		local ok, err = apply_top_classes(dev, ids, cfg, logger)
		if not ok then return fail_dirty(st, err) end
	end

	local plan, perr = build_host_plan(spec, cfg, ids)
	if not plan then return fail_dirty(st, perr) end

	local prev_plan = st.hosts or {}

	-- Membership drives filter work; limits drive class/fq work.
	local mem_changed, _affected = membership_delta(prev_plan, plan)
	local lim_changed = false

	if mem_changed then
		local ok, err
		if need_scaffold or not st.hosts then
			ok, err = rebuild_host_filters_full(kind, spec, cfg, dev, ids, plan, logger)
		else
			ok, err = reconcile_host_filters_delta(kind, spec, cfg, dev, ids, prev_plan, plan, logger)
		end
		if not ok then return fail_dirty(st, err) end
		lim_changed = true -- membership implies class/fq reconciliation work may be needed
	else
		-- Check per-host deltas only when membership is stable.
		for ip_s, rec in pairs(plan) do
			local old = prev_plan[ip_s]
			if host_htb_changed(old, rec) or host_fq_changed(old, rec) then
				lim_changed = true
				break
			end
		end
	end

	-- Always reconcile when membership changed (stale removals), otherwise only if limits changed.
	if mem_changed or lim_changed then
		local ok, err = reconcile_host_classes_and_fq(dev, ids, prev_plan, plan, logger)
		if not ok then return fail_dirty(st, err) end
	end

	st.hosts = plan
	st.ids   = shallow_copy(ids)
	st.dev   = dev
	st.ifb   = ifb
	st.dirty = nil

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
---
--- Reconciliation behaviour:
---   * Host filters are updated only when membership changes (adds/removes).
---   * Host HTB classes are updated only for changed/new hosts.
---   * Per-host fq_codel leaves are updated only for changed/new hosts (and removed for deleted hosts).
function M.apply(spec)
	spec = spec or {}
	local iface = spec.iface
	if type(iface) ~= 'string' or iface == '' then
		return nil, 'iface is required'
	end

	local cidr = spec.subnet or spec.cidr
	local net_u, pfx, cerr = parse_cidr(cidr)
	if not net_u then return nil, cerr end

	local logger = (type(spec.log) == 'function') and spec.log or nil
	local parsed = { cidr = cidr, net_u = net_u, pfx = pfx }

	local ok, err = apply_direction(iface, 'egress', parsed, spec.egress, logger)
	if not ok then return nil, 'egress: ' .. tostring(err) end

	ok, err = apply_direction(iface, 'ingress', parsed, spec.ingress, logger)
	if not ok then return nil, 'ingress: ' .. tostring(err) end

	return true, nil
end

function M.clear(iface, opts)
	opts = opts or {}
	if type(iface) ~= 'string' or iface == '' then
		return nil, 'iface is required'
	end

	local logger = (type(opts.log) == 'function') and opts.log or nil
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
