-- Original Big Box MCU newline-JSON to canonical retained-state profile.
-- The historical profile name is kept for link configuration compatibility.
--
-- This module is deliberately pure. Its Fiber-backed runtime is loaded only
-- when a link runs, keeping configuration compilation dependency-free.

local M = {
	kind = 'legacy_mcu_metrics_v1',
	capabilities = {
		session = false,
		publish = true,
		rpc = false,
		transfer = false,
		write = false,
	},
	link_sections = {},
}

local DEFAULTS = {
	change_only = true,
	unsigned_underflow_compat = true,
	member = 'mcu',
	error_log_initial_s = 1.0,
	error_log_max_s = 60.0,
}

local ALLOWED_ARGS = {
	change_only = true,
	unsigned_underflow_compat = true,
	member = true,
	error_log_initial_s = true,
	error_log_max_s = true,
}

local function positive_number(value, path, default)
	if value == nil then value = default end
	if type(value) ~= 'number' or value ~= value or value <= 0
		or value == math.huge or value == -math.huge
	then
		return nil, path .. ' must be a positive finite number'
	end
	return value, nil
end

local function boolean(value, path, default)
	if value == nil then return default, nil end
	if type(value) ~= 'boolean' then return nil, path .. ' must be boolean' end
	return value, nil
end

local function non_empty_string(value, path, default)
	if value == nil then value = default end
	if type(value) ~= 'string' or value == '' then
		return nil, path .. ' must be a non-empty string'
	end
	return value, nil
end

function M.compile(args)
	if args == nil then args = {} end
	if type(args) ~= 'table' then return nil, 'protocol.args must be a table' end
	for key in pairs(args) do
		if not ALLOWED_ARGS[key] then
			return nil, 'protocol.args has unknown field for legacy_mcu_metrics_v1: ' .. tostring(key)
		end
	end

	local change_only, e3 = boolean(args.change_only,
		'protocol.args.change_only', DEFAULTS.change_only)
	if e3 then return nil, e3 end
	local underflow, e4 = boolean(args.unsigned_underflow_compat,
		'protocol.args.unsigned_underflow_compat', DEFAULTS.unsigned_underflow_compat)
	if e4 then return nil, e4 end
	local initial_s, e5 = positive_number(args.error_log_initial_s,
		'protocol.args.error_log_initial_s', DEFAULTS.error_log_initial_s)
	if e5 then return nil, e5 end
	local max_s, e6 = positive_number(args.error_log_max_s,
		'protocol.args.error_log_max_s', DEFAULTS.error_log_max_s)
	if e6 then return nil, e6 end
	if max_s < initial_s then
		return nil, 'protocol.args.error_log_max_s must be >= error_log_initial_s'
	end
	local member, e7 = non_empty_string(args.member, 'protocol.args.member', DEFAULTS.member)
	if e7 then return nil, e7 end

	return {
		change_only = change_only,
		unsigned_underflow_compat = underflow,
		member = member,
		error_log_initial_s = initial_s,
		error_log_max_s = max_s,
	}, nil
end

function M.run(scope, params, service_caps)
	return require('services.fabric.profiles.legacy_mcu_metrics_v1.runtime')
		.run(scope, params, service_caps)
end

M.DEFAULTS = DEFAULTS
return M
