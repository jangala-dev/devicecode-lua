-- services/http/config.lua
--
-- Pure HTTP capability-service configuration normaliser.
-- This module performs no I/O and starts no Fibres.

local M = {}

M.SCHEMA = 'devicecode.config/http/1'

local DEFAULTS = {
	enabled = true,
	id = 'main',
	policy = {
		allowed_schemes = { http = true, https = true, ws = true, wss = true },
		allowed_response_parsers = { strict = true },
		allow_loopback = true,
		max_request_body = 16 * 1024 * 1024,
		max_response_body = 16 * 1024 * 1024,
		legacy_http1_close_max_response_bytes = 1024 * 1024,
	},
	observability = {
		status_interval_s = 30,
		request_trace = false,
		success_events = false,
		failure_rate_limit_s = 60,
	},
}

local ROOT_KEYS = {
	schema = true,
	enabled = true,
	id = true,
	policy = true,
	observability = true,
}

local OBSERVABILITY_KEYS = {
	status_interval_s = true,
	request_trace = true,
	success_events = true,
	failure_rate_limit_s = true,
}

local POLICY_KEYS = {
	allowed_schemes = true,
	allowed_hosts = true,
	denied_hosts = true,
	allowed_response_parsers = true,
	allow_loopback = true,
	max_request_body = true,
	max_response_body = true,
	legacy_http1_close_max_response_bytes = true,
}

local function fail(msg) return nil, msg end

local function copy_plain(v)
	if type(v) ~= 'table' then return v end
	local out = {}
	for k, subv in pairs(v) do out[k] = copy_plain(subv) end
	return out
end

local function allowed(t, keys, path)
	for k in pairs(t or {}) do
		if not keys[k] then return nil, path .. ' has unknown field: ' .. tostring(k) end
	end
	return true, nil
end

local function bool_or_nil(v, path)
	if v == nil then return nil, nil end
	if type(v) ~= 'boolean' then return nil, path .. ' must be boolean' end
	return v, nil
end

local function non_empty_string_or_nil(v, path)
	if v == nil then return nil, nil end
	if type(v) ~= 'string' or v == '' then return nil, path .. ' must be a non-empty string' end
	return v, nil
end

local function positive_number_or_nil(v, path)
	if v == nil then return nil, nil end
	if type(v) ~= 'number' or v < 0 then return nil, path .. ' must be a non-negative number' end
	return v, nil
end

local function string_bool_map_or_nil(v, path)
	if v == nil then return nil, nil end
	if type(v) ~= 'table' then return nil, path .. ' must be a table' end
	local out = {}
	for k, allowed_value in pairs(v) do
		if type(k) ~= 'string' or k == '' then return nil, path .. ' keys must be non-empty strings' end
		if type(allowed_value) ~= 'boolean' then return nil, path .. ' values must be boolean' end
		out[k] = allowed_value
	end
	return out, nil
end

local function normalise_policy(raw)
	if raw == nil then raw = {} end
	if type(raw) ~= 'table' then return fail('policy must be a table') end
	local ok, err = allowed(raw, POLICY_KEYS, 'policy')
	if not ok then return nil, err end

	local out = copy_plain(DEFAULTS.policy)
	local v

	v, err = string_bool_map_or_nil(raw.allowed_schemes, 'policy.allowed_schemes')
	if err then return nil, err end
	if v ~= nil then out.allowed_schemes = v end

	v, err = string_bool_map_or_nil(raw.allowed_hosts, 'policy.allowed_hosts')
	if err then return nil, err end
	if v ~= nil then out.allowed_hosts = v end

	v, err = string_bool_map_or_nil(raw.allowed_response_parsers, 'policy.allowed_response_parsers')
	if err then return nil, err end
	if v ~= nil then out.allowed_response_parsers = v end

	v, err = string_bool_map_or_nil(raw.denied_hosts, 'policy.denied_hosts')
	if err then return nil, err end
	if v ~= nil then out.denied_hosts = v end

	v, err = bool_or_nil(raw.allow_loopback, 'policy.allow_loopback')
	if err then return nil, err end
	if v ~= nil then out.allow_loopback = v end

	v, err = positive_number_or_nil(raw.max_request_body, 'policy.max_request_body')
	if err then return nil, err end
	if v ~= nil then out.max_request_body = v end

	v, err = positive_number_or_nil(raw.max_response_body, 'policy.max_response_body')
	if err then return nil, err end
	if v ~= nil then out.max_response_body = v end

	v, err = positive_number_or_nil(raw.legacy_http1_close_max_response_bytes, 'policy.legacy_http1_close_max_response_bytes')
	if err then return nil, err end
	if v ~= nil then out.legacy_http1_close_max_response_bytes = v end

	return out, nil
end


local function normalise_observability(raw)
	if raw == nil then raw = {} end
	if type(raw) ~= 'table' then return fail('observability must be a table') end
	local ok, err = allowed(raw, OBSERVABILITY_KEYS, 'observability')
	if not ok then return nil, err end

	local out = copy_plain(DEFAULTS.observability)
	local v

	v, err = positive_number_or_nil(raw.status_interval_s, 'observability.status_interval_s')
	if err then return nil, err end
	if v ~= nil then out.status_interval_s = v end

	v, err = bool_or_nil(raw.request_trace, 'observability.request_trace')
	if err then return nil, err end
	if v ~= nil then out.request_trace = v end

	v, err = bool_or_nil(raw.success_events, 'observability.success_events')
	if err then return nil, err end
	if v ~= nil then out.success_events = v end

	v, err = positive_number_or_nil(raw.failure_rate_limit_s, 'observability.failure_rate_limit_s')
	if err then return nil, err end
	if v ~= nil then out.failure_rate_limit_s = v end

	return out, nil
end

function M.normalise(raw)
	if raw == nil then raw = {} end
	if type(raw) ~= 'table' then return fail('http config must be a table') end
	local ok, err = allowed(raw, ROOT_KEYS, 'http config')
	if not ok then return nil, err end

	if raw.schema ~= nil and raw.schema ~= M.SCHEMA then
		return nil, 'http config schema must be ' .. M.SCHEMA
	end

	local enabled, eerr = bool_or_nil(raw.enabled, 'enabled')
	if eerr then return nil, eerr end

	local id, ierr = non_empty_string_or_nil(raw.id, 'id')
	if ierr then return nil, ierr end

	local policy, perr = normalise_policy(raw.policy)
	if not policy then return nil, perr end

	local observability, oerr = normalise_observability(raw.observability)
	if not observability then return nil, oerr end

	return {
		schema = M.SCHEMA,
		enabled = enabled ~= false,
		id = id or DEFAULTS.id,
		policy = policy,
		observability = observability,
	}, nil
end

M.DEFAULTS = DEFAULTS
return M
