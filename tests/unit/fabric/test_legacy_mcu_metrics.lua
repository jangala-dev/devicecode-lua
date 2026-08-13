local legacy = require 'services.fabric.profiles.legacy_mcu_metrics_v1.processor'

local T = {}

local function eq(a, b, msg)
	if a ~= b then error(msg or ('expected ' .. tostring(b) .. ', got ' .. tostring(a)), 2) end
end

local function protocol(overrides)
	local out = {
		kind = 'legacy_mcu_metrics_v1',
		namespace_prefix = { 'mcu' },
		publish_service = 'mcu',
		change_only = true,
		unsigned_underflow_compat = true,
		error_log_initial_s = 1,
		error_log_max_s = 60,
	}
	for k, v in pairs(overrides or {}) do out[k] = v end
	return out
end

function T.processes_slash_keys_as_current_metrics_with_namespace()
	local p = legacy.new_processor(protocol())
	local emitted = {}
	local ok, err = legacy.process_line(p,
		'  {"power/battery/internal/vbat":12740,"env/temperature/core":24.3}  ',
		function(name, value, namespace)
			emitted[name] = { value = value, namespace = table.concat(namespace, '.') }
			return true
		end)
	assert(ok, tostring(err))
	eq(emitted.vbat.value, 12740)
	eq(emitted.vbat.namespace, 'mcu.power.battery.internal.vbat')
	eq(emitted.core.value, 24.3)
	eq(emitted.core.namespace, 'mcu.env.temperature.core')
	eq(p.lines, 1)
	eq(p.decoded, 1)
	eq(p.published, 2)
end

function T.suppresses_unchanged_values_and_publishes_changes()
	local p = legacy.new_processor(protocol())
	local emitted = {}
	local function emit(name, value)
		emitted[#emitted + 1] = { name = name, value = value }
		return true
	end
	assert(legacy.process_line(p, '{"sys/mem/alloc":100}', emit))
	assert(legacy.process_line(p, '{"sys/mem/alloc":100}', emit))
	assert(legacy.process_line(p, '{"sys/mem/alloc":101}', emit))
	eq(#emitted, 2)
	eq(emitted[1].value, 100)
	eq(emitted[2].value, 101)
	eq(p.unchanged, 1)
end

function T.reproduces_legacy_unsigned_underflow_conversion()
	local p = legacy.new_processor(protocol())
	local value
	assert(legacy.process_line(p, '{"power/battery/internal/ibat":4294967176}', function(_, v)
		value = v
		return true
	end))
	eq(value, -120)
end

function T.can_disable_underflow_compatibility()
	local p = legacy.new_processor(protocol({ unsigned_underflow_compat = false }))
	local value
	assert(legacy.process_line(p, '{"counter":4294967176}', function(_, v)
		value = v
		return true
	end))
	eq(value, 4294967176)
end

function T.rejects_malformed_and_non_object_json_without_emitting()
	local p = legacy.new_processor(protocol())
	local calls = 0
	local function emit() calls = calls + 1; return true end
	local ok1 = legacy.process_line(p, '{bad', emit)
	local ok2 = legacy.process_line(p, '42', emit)
	eq(ok1, nil)
	eq(ok2, nil)
	eq(calls, 0)
	eq(p.decode_errors, 2)
end

return T
