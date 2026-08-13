-- Original Big Box MCU newline-JSON metric profile.
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
	namespace_prefix = { 'mcu' },
	publish_service = 'mcu',
	change_only = true,
	unsigned_underflow_compat = true,
	error_log_initial_s = 1.0,
	error_log_max_s = 60.0,
}

local ALLOWED_ARGS = {
	namespace_prefix = true,
	publish_service = true,
	change_only = true,
	unsigned_underflow_compat = true,
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

local function namespace(value)
	value = value or DEFAULTS.namespace_prefix
	if type(value) ~= 'table' then
		return nil, 'protocol.args.namespace_prefix must be a dense topic array'
	end
	local out, count = {}, #value
	for i = 1, count do
		local token = value[i]
		if (type(token) ~= 'string' or token == '') and type(token) ~= 'number' then
			return nil, 'protocol.args.namespace_prefix[' .. tostring(i) .. '] must be string or number'
		end
		out[i] = token
	end
	for key in pairs(value) do
		if type(key) ~= 'number' or key < 1 or key % 1 ~= 0 or key > count then
			return nil, 'protocol.args.namespace_prefix must be a dense topic array'
		end
	end
	return out, nil
end

function M.compile(args)
	if args == nil then args = {} end
	if type(args) ~= 'table' then return nil, 'protocol.args must be a table' end
	for key in pairs(args) do
		if not ALLOWED_ARGS[key] then
			return nil, 'protocol.args has unknown field for legacy_mcu_metrics_v1: ' .. tostring(key)
		end
	end

	local prefix, e1 = namespace(args.namespace_prefix)
	if e1 then return nil, e1 end
	local service, e2 = non_empty_string(args.publish_service,
		'protocol.args.publish_service', DEFAULTS.publish_service)
	if e2 then return nil, e2 end
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

	return {
		namespace_prefix = prefix,
		publish_service = service,
		change_only = change_only,
		unsigned_underflow_compat = underflow,
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
