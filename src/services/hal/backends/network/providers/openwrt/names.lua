-- services/hal/backends/network/providers/openwrt/names.lua
-- Bounded OpenWrt name allocation.
--
-- Product ids are semantic names.  OpenWrt names are provider artefacts with
-- small hard limits; generate them centrally so long or hostile config ids can
-- never leak into netifd, Linux device, firewall, dnsmasq or mwan3 namespaces.

local M = {}
local Ctx = {}
Ctx.__index = Ctx

local MAX = {
	logical_interface = 8,
	linux_device = 14,
	bridge_device = 14,
	firewall_zone = 11,
	mwan_name = 15,
	dnsmasq_instance = 15,
	uci_section = 32,
}

local function is_plain_table(v)
	return type(v) == 'table' and getmetatable(v) == nil
end

local function sorted_keys(t)
	local ks = {}
	for k in pairs(t or {}) do ks[#ks + 1] = k end
	table.sort(ks, function(a, b) return tostring(a) < tostring(b) end)
	return ks
end

local function clean(s)
	s = tostring(s or ''):lower():gsub('[^a-z0-9]', '')
	return s
end

local function uci_clean(s)
	s = tostring(s or ''):gsub('[^%w_]', '_')
	if s == '' then s = 'x' end
	if not s:match('^[A-Za-z_]') then s = 'x_' .. s end
	return s
end

local function safe_plain_name(s, max_len)
	s = tostring(s or '')
	if #s == 0 or #s > max_len then return nil end
	if not s:match('^[A-Za-z][A-Za-z0-9_]*$') then return nil end
	return s
end

local function readable_prefix(seed, fallback, n)
	local s = clean(seed)
	if s == '' then s = clean(fallback) end
	if s == '' then s = 'x' end
	while #s < n do s = s .. 'x' end
	if not s:sub(1, 1):match('%a') then s = 'x' .. s end
	return s:sub(1, n)
end

local function uint32_to_hex(n)
	-- Avoid string.format('%x', n).  On some Lua 5.3/5.4 builds, values
	-- that have passed through floating-point arithmetic are tagged as
	-- numbers rather than integers and '%x' raises "integer expected".
	-- This pure arithmetic formatter works on Lua 5.1/LuaJIT/5.3+.
	local hex = '0123456789abcdef'
	n = math.floor(tonumber(n) or 0) % 4294967296
	local out = {}
	for i = 8, 1, -1 do
		local d = n % 16
		out[i] = hex:sub(d + 1, d + 1)
		n = (n - d) / 16
	end
	return table.concat(out)
end

local function hash_hex(seed, len)
	-- Small deterministic FNV-1a-like hash using only double-safe arithmetic.
	local h = 2166136261
	seed = tostring(seed or '')
	for i = 1, #seed do
		h = (h + seed:byte(i)) % 4294967296
		h = (h * 16777619) % 4294967296
	end
	local s = uint32_to_hex(h)
	while #s < len do s = s .. s end
	return s:sub(1, len)
end

local function make_name(seed, fallback, class, max_len, used)
	local prefix_len = math.min(2, math.max(1, max_len - 1))
	local p = readable_prefix(seed, fallback or class, prefix_len)
	for attempt = 0, 64 do
		local material = class .. ':' .. tostring(seed or '') .. ':' .. tostring(attempt)
		local hash_len = math.max(1, max_len - #p)
		local name = p .. hash_hex(material, hash_len)
		if #name > max_len then name = name:sub(1, max_len) end
		local prior = used[name]
		if prior == nil or prior == material then
			used[name] = material
			return name
		end
	end
	error('OpenWrt name collision for ' .. tostring(class) .. ':' .. tostring(seed), 2)
end

local function make_uci_section(kind, seed, used)
	local base = uci_clean(kind .. '_' .. tostring(seed or 'x'))
	if #base > MAX.uci_section then
		base = base:sub(1, 22) .. '_' .. hash_hex(kind .. ':' .. tostring(seed), 8)
	end
	local name = base
	local i = 0
	while used[name] and used[name] ~= kind .. ':' .. tostring(seed) do
		i = i + 1
		local suffix = '_' .. tostring(i)
		name = base:sub(1, MAX.uci_section - #suffix) .. suffix
	end
	used[name] = kind .. ':' .. tostring(seed)
	return name
end

local function remember(self, class, key, name)
	key = tostring(key)
	self._cache[class] = self._cache[class] or {}
	self._cache[class][key] = self._cache[class][key] or name
	self._reverse[class] = self._reverse[class] or {}
	self._reverse[class][name] = key
	return name
end

local function memo(self, class, key, max_len, fallback)
	self._cache[class] = self._cache[class] or {}
	if self._cache[class][key] then return self._cache[class][key] end
	self._used[class] = self._used[class] or {}
	local name = make_name(key, fallback, class, max_len, self._used[class])
	self._cache[class][key] = name
	self._reverse[class] = self._reverse[class] or {}
	self._reverse[class][name] = key
	return name
end

local function reserve(self, class, name, reason)
	self._used[class] = self._used[class] or {}
	if self._used[class][name] and self._used[class][name] ~= 'reserved:' .. tostring(reason) then
		error('OpenWrt reserved-name collision for ' .. tostring(class) .. ':' .. tostring(name), 2)
	end
	self._used[class][name] = 'reserved:' .. tostring(reason)
end

local function remember_if_available(self, class, key, name)
	key = tostring(key)
	local material = class .. ':' .. key
	self._used[class] = self._used[class] or {}
	local prior = self._used[class][name]
	if prior ~= nil and prior ~= material then return nil end
	self._used[class][name] = material
	return remember(self, class, key, name)
end

local function safe_or_memo(self, class, key, max_len, fallback)
	local safe = safe_plain_name(key, max_len)
	if safe then
		local name = remember_if_available(self, class, key, safe)
		if name then return name end
	end
	return memo(self, class, tostring(key), max_len, fallback)
end

local function remember_prefixed_if_available(self, class, key, prefix, safe_stem)
	if not safe_stem then return nil end
	local name = prefix .. safe_stem
	return remember_if_available(self, class, key, name)
end

local function memo_prefixed(self, class, key, max_len, prefix, fallback)
	key = tostring(key)
	self._cache[class] = self._cache[class] or {}
	if self._cache[class][key] then return self._cache[class][key] end
	self._used[class] = self._used[class] or {}
	local stem_len = max_len - #prefix
	if stem_len < 1 then error('prefix too long for OpenWrt name class ' .. tostring(class), 2) end
	local stem_prefix_len = math.min(2, stem_len)
	local stem_prefix = readable_prefix(key, fallback or prefix, stem_prefix_len)
	for attempt = 0, 64 do
		local material = class .. ':' .. key .. ':' .. tostring(attempt)
		local hash_len = math.max(1, stem_len - #stem_prefix)
		local name = prefix .. stem_prefix .. hash_hex(material, hash_len)
		if #name > max_len then name = name:sub(1, max_len) end
		local prior = self._used[class][name]
		if prior == nil or prior == material then
			self._used[class][name] = material
			self._cache[class][key] = name
			self._reverse[class] = self._reverse[class] or {}
			self._reverse[class][name] = key
			return name
		end
	end
	error('OpenWrt name collision for ' .. tostring(class) .. ':' .. tostring(key), 2)
end

local function memo_mwan(self, role, id)
	-- All MWAN3 UCI section names share one package namespace.  Allocate
	-- interface/member/policy/rule names from the same used-name set and
	-- always role-prefix them, even when the semantic id itself is short.
	local prefix = ({ iface = 'mi', member = 'mm', policy = 'mp', rule = 'mr' })[role]
	local name = memo_prefixed(self, 'mwan', role .. ':' .. tostring(id), MAX.mwan_name, prefix, role)
	-- Preserve role-specific diagnostic maps in snapshots while the allocator
	-- itself enforces one shared MWAN3 package namespace.
	local cache_class = 'mwan_' .. role
	self._cache[cache_class] = self._cache[cache_class] or {}
	self._cache[cache_class][tostring(id)] = name
	self._reverse[cache_class] = self._reverse[cache_class] or {}
	self._reverse[cache_class][name] = tostring(id)
	return name
end

function Ctx:iface(id)
	return safe_or_memo(self, 'logical_interface', tostring(id), MAX.logical_interface, 'if')
end

function Ctx:bridge(id)
	local safe = safe_plain_name(id, MAX.bridge_device - 3)
	local name = remember_prefixed_if_available(self, 'bridge_device', id, 'br-', safe)
	if name then return name end
	return memo_prefixed(self, 'bridge_device', tostring(id), MAX.bridge_device, 'br', 'br')
end

function Ctx:vlan(id)
	local safe = safe_plain_name(id, MAX.linux_device - 3)
	local name = remember_prefixed_if_available(self, 'linux_device', id, 'vl-', safe)
	if name then return name end
	return memo_prefixed(self, 'linux_device', tostring(id), MAX.linux_device, 'vl', 'vl')
end

function Ctx:zone(id)
	return safe_or_memo(self, 'firewall_zone', tostring(id), MAX.firewall_zone, 'zn')
end

function Ctx:mwan_iface(id)
	return memo_mwan(self, 'iface', id)
end

function Ctx:mwan_member(id)
	return memo_mwan(self, 'member', id)
end

function Ctx:mwan_policy(id)
	return memo_mwan(self, 'policy', id or 'balanced')
end

function Ctx:mwan_rule(id)
	return memo_mwan(self, 'rule', id)
end

function Ctx:dns_instance(id)
	return safe_or_memo(self, 'dnsmasq_instance', tostring(id), MAX.dnsmasq_instance, 'dn')
end

function Ctx:section(kind, id)
	self._used.uci_section = self._used.uci_section or {}
	return make_uci_section(kind, tostring(id), self._used.uci_section)
end

function Ctx:semantic_for(class, generated)
	return self._reverse[class] and self._reverse[class][generated] or nil
end

function Ctx:snapshot()
	local out = { max = {}, names = {} }
	for k, v in pairs(MAX) do out.max[k] = v end
	for class, map in pairs(self._cache) do
		out.names[class] = {}
		for semantic, generated in pairs(map) do out.names[class][semantic] = generated end
	end
	return out
end

function Ctx:limits()
	local out = {}
	for k, v in pairs(MAX) do out[k] = v end
	return out
end

function M.allocate(intent, _provider_config)
	local ctx = setmetatable({ _cache = {}, _used = {}, _reverse = {} }, Ctx)
	-- Reserve baseline UCI names produced by the provider.  Product ids that
	-- would otherwise map directly to these names must be generated instead.
	reserve(ctx, 'logical_interface', 'loopback', 'network.loopback')
	reserve(ctx, 'logical_interface', 'globals', 'network.globals')
	reserve(ctx, 'firewall_zone', 'defaults', 'firewall.defaults')
	reserve(ctx, 'mwan', 'globals', 'mwan3.globals')
	-- Pre-allocate common names to catch deterministic collisions before apply.
	for _, seg_id in ipairs(sorted_keys((intent or {}).segments)) do
		ctx:iface(seg_id); ctx:bridge(seg_id); ctx:vlan(seg_id)
		local seg = intent.segments[seg_id]
		local fw = is_plain_table(seg and seg.firewall) and seg.firewall or {}
		ctx:zone(fw.zone or seg_id)
	end
	for _, if_id in ipairs(sorted_keys((intent or {}).interfaces)) do
		ctx:iface(if_id); ctx:bridge(if_id); ctx:vlan(if_id)
	end
	local fw = is_plain_table((intent or {}).firewall) and intent.firewall or {}
	for _, z in ipairs(sorted_keys(fw.zones or {})) do ctx:zone(z) end
	local wan = is_plain_table((intent or {}).wan) and intent.wan or {}
	local members = is_plain_table(wan.members) and wan.members or {}
	for _, mid in ipairs(sorted_keys(members)) do
		ctx:mwan_iface((members[mid] and (members[mid].interface or members[mid].iface)) or mid)
		ctx:mwan_member(mid)
	end
	return ctx, nil
end

M.MAX = MAX
return M
