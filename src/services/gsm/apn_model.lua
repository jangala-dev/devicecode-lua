-- services/gsm/apn_model.lua
--
-- Pure validation/normalisation for user-supplied APN records.

local tablex = require 'shared.table'

local M = {}

local copy = tablex.deep_copy

local ALLOWED_KEYS = {
	carrier = true,
	mcc = true,
	mnc = true,
	apn = true,
	type = true,
	protocol = true,
	roaming_protocol = true,
	user_visible = true,
	authtype = true,
	mmsc = true,
	mmsproxy = true,
	mmsport = true,
	proxy = true,
	port = true,
	bearer_bitmask = true,
	read_only = true,
	user = true,
	password = true,
	mvno_type = true,
	mvno_match_data = true,
	mtu = true,
	ppp_number = true,
	vivoentry = true,
	server = true,
	localized_name = true,
	visit_area = true,
	bearer = true,
	profile_id = true,
	modem_cognitive = true,
	max_conns = true,
	max_conns_time = true,
	skip_464xlat = true,
	carrier_enabled = true,
	mtusize = true,
	auth = true,
}

local function trim(s)
	return tostring(s or ''):gsub('^%s+', ''):gsub('%s+$', '')
end

local function is_digits(s, n1, n2)
	if type(s) ~= 'string' then return false end
	if not s:match('^%d+$') then return false end
	return #s >= n1 and #s <= n2
end

local function normalise_string(v)
	if v == nil then return nil end
	if type(v) ~= 'string' and type(v) ~= 'number' and type(v) ~= 'boolean' then return nil, 'field must be scalar' end
	local s = trim(v)
	if s == '' then return nil end
	return s
end

function M.normalise_record(rec)
	if type(rec) ~= 'table' then return nil, 'apn record must be a table' end
	local out = {}
	for k, v in pairs(rec) do
		if type(k) == 'string' and ALLOWED_KEYS[k] then
			local nv, err = normalise_string(v)
			if err then return nil, k .. ': ' .. err end
			if nv ~= nil then out[k] = nv end
		end
	end
	if type(out.carrier) ~= 'string' or out.carrier == '' then return nil, 'carrier is required' end
	if not is_digits(out.mcc, 3, 3) then return nil, 'mcc must be three digits' end
	if not is_digits(out.mnc, 1, 3) then return nil, 'mnc must be one to three digits' end
	if type(out.apn) ~= 'string' or out.apn == '' then return nil, 'apn is required' end
	if out.mvno_type ~= nil then
		local mt = out.mvno_type:lower()
		if mt ~= 'spn' and mt ~= 'gid' and mt ~= 'imsi' then return nil, 'mvno_type must be spn, gid or imsi' end
		out.mvno_type = mt
		if type(out.mvno_match_data) ~= 'string' or out.mvno_match_data == '' then
			return nil, 'mvno_match_data is required when mvno_type is set'
		end
	end
	return out, nil
end

function M.normalise_list(records)
	if records == nil then return {}, nil end
	if type(records) ~= 'table' then return nil, 'apns must be a list' end
	local out = {}
	local seen = {}
	for i, rec in ipairs(records) do
		local item, err = M.normalise_record(rec)
		if not item then return nil, 'apns[' .. tostring(i) .. ']: ' .. tostring(err) end
		local key = table.concat({ item.carrier, item.mcc, item.mnc, item.apn }, '\0')
		if seen[key] then return nil, 'duplicate APN: ' .. item.carrier .. '/' .. item.mcc .. '/' .. item.mnc .. '/' .. item.apn end
		seen[key] = true
		out[#out + 1] = item
	end
	return out, nil
end

function M.list_from_payload(payload)
	if type(payload) ~= 'table' then return nil, 'payload must be a table' end
	if payload.records ~= nil then return M.normalise_list(payload.records) end
	return M.normalise_list(payload)
end

local SECRET_KEYS = {
	user = true,
	password = true,
	auth = true,
}

function M.redact_record(record)
	local out = copy(record or {})
	for key in pairs(SECRET_KEYS) do
		if out[key] ~= nil then
			out[key] = nil
			out['has_' .. key] = true
		end
	end
	return out
end

function M.redact_list(records)
	local out = {}
	for i, record in ipairs(records or {}) do
		out[i] = M.redact_record(record)
	end
	return out
end

return M
