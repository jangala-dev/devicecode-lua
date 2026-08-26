local binser = require "shared.binser"
local tablex = require "shared.table"

local copy = tablex.deep_copy

local g_authtypes = {}
g_authtypes["0"] = "none"
g_authtypes["1"] = "pap"
g_authtypes["2"] = "chap"
g_authtypes["3"] = "pap|chap"

local function normalise_mnc(mnc)
	if mnc == nil then return nil end
	mnc = tostring(mnc)
	if #mnc == 1 then return "0" .. mnc end
	return mnc
end

-- deserialise the bundled APN database and return APNs for the SIM.
local function get_apns(mcc, mnc)
	local ok, apndb = pcall(function () return binser.r("etc/apns")[1] end)
	if not ok or type(apndb) ~= 'table' then return {} end
	local by_mcc = apndb[tostring(mcc or '')]
	if type(by_mcc) ~= 'table' then return {} end
	local apns = by_mcc[normalise_mnc(mnc) or tostring(mnc or '')]
	if type(apns) ~= 'table' then return {} end
	return copy(apns)
end

local function build_connection_string(apn, roaming_allow)
	if not apn or next(apn) == nil then return nil, "apn table empty" end
	local a = {}
	for k,v in pairs(apn) do
		if k == "apn" then table.insert(a, "apn="..v)
		elseif k == "user" then table.insert(a, "user="..v)
		elseif k == "password" then table.insert(a, "password="..v)
		elseif k == "authtype" and g_authtypes[tostring(v)] then table.insert(a, "allowed-auth="..g_authtypes[tostring(v)])
		end
	end
	if roaming_allow then table.insert(a, "allow-roaming=true") end
	local conn_string = table.concat(a,",")
	return conn_string, nil
end

local function mvno_rank(apn, imsi, spn, gid1, ranks)
	ranks = ranks or { match = 1, plain = 2, mismatch = 4 }
	if apn.mvno_type then
		local match_data = tostring(apn.mvno_match_data or '')
		if apn.mvno_type == "spn" and spn and string.find(tostring(spn), match_data, 1, true) then
			return ranks.match
		elseif apn.mvno_type == "gid" and gid1 and string.find(tostring(gid1), match_data, 1, true) then
			return ranks.match
		elseif apn.mvno_type == "imsi" and imsi and string.find(tostring(imsi), match_data, 1, true) then
			return ranks.match
		else
			return ranks.mismatch
		end
	end
	return ranks.plain
end

local function rank(apns, imsi, spn, gid1, prefix, ranks)
	local out_apns = {}
	local rankings = {}
	prefix = prefix or ''
	for k, v in pairs(apns or {}) do
		if type(v) == 'table' then
			local name = prefix .. tostring(k)
			out_apns[name] = copy(v)
			table.insert(rankings, { name = name, rank = mvno_rank(v, imsi, spn, gid1, ranks) })
		end
	end
	return out_apns, rankings
end

local function custom_matches(apn, mcc, mnc)
	if type(apn) ~= 'table' then return false end
	return tostring(apn.mcc or '') == tostring(mcc or '')
		and normalise_mnc(apn.mnc) == normalise_mnc(mnc)
end

local function custom_apns_for(custom_records, mcc, mnc)
	local out = {}
	if type(custom_records) ~= 'table' then return out end
	for i, apn in ipairs(custom_records) do
		if custom_matches(apn, mcc, mnc) then
			out['custom-' .. tostring(i)] = apn
		end
	end
	return out
end

local function add_default(apns, rankings)
	apns.default = { apn = 'internet' }
	table.insert(rankings, { name = 'default', rank = 4 })
end

local function merge_into(dst_apns, dst_rankings, src_apns, src_rankings)
	for name, apn in pairs(src_apns or {}) do dst_apns[name] = apn end
	for _, r in ipairs(src_rankings or {}) do dst_rankings[#dst_rankings + 1] = r end
end

local function get_ranked_apns(mcc, mnc, imsi, spn, gid1, custom_records)
	if mnc == nil then return {}, {} end
	mnc = normalise_mnc(mnc)

	local ranked_apns, rankings = {}, {}

	local custom_map = custom_apns_for(custom_records, mcc, mnc)
	local custom_apns, custom_rankings = rank(custom_map, imsi, spn, gid1, '', {
		match = 1,
		plain = 1,
		mismatch = 5,
	})
	merge_into(ranked_apns, rankings, custom_apns, custom_rankings)

	local builtin = get_apns(mcc, mnc)
	local builtin_apns, builtin_rankings = rank(builtin, imsi, spn, gid1, 'builtin-', {
		match = 2,
		plain = 3,
		mismatch = 5,
	})
	merge_into(ranked_apns, rankings, builtin_apns, builtin_rankings)

	add_default(ranked_apns, rankings)
	table.sort(rankings, function (k1, k2)
		if k1.rank == k2.rank then return tostring(k1.name) < tostring(k2.name) end
		return k1.rank < k2.rank
	end)
	return ranked_apns, rankings
end

return {
	get_ranked_apns = get_ranked_apns,
	build_connection_string = build_connection_string,
	get_apns = get_apns,
}
