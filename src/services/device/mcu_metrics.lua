-- services/device/mcu_metrics.lua
--
-- Small bridge from the composed MCU component view to the transitional metrics
-- bus contract.

local projection = require 'services.device.projection'

local M = {}

local function table_or_empty(v)
	return type(v) == 'table' and v or {}
end

local function first_number(...)
	for i = 1, select('#', ...) do
		local n = tonumber(select(i, ...))
		if n ~= nil then return n end
	end
	return nil
end

local function first_boolean(t, names)
	if type(t) ~= 'table' then return nil end
	for i = 1, #names do
		local v = t[names[i]]
		if type(v) == 'boolean' then return v end
	end
	return nil
end

local function emit(out, name, value, namespace)
	if value == nil then return end
	out[#out + 1] = {
		name = name,
		value = value,
		namespace = namespace,
	}
end

local function emit_boolean_group(out, group, specs, namespace_prefix)
	for i = 1, #specs do
		local spec = specs[i]
		local value = first_boolean(group, spec.keys)
		emit(out, spec.metric, value, {
			namespace_prefix[1],
			namespace_prefix[2],
			namespace_prefix[3],
			namespace_prefix[4],
			namespace_prefix[5],
			spec.metric,
		})
	end
end

local system_flags = {
	{ metric = 'charger_enabled', keys = { 'charger_enabled' } },
	{ metric = 'mppt_en_pin', keys = { 'mppt_en_pin' } },
	{ metric = 'equalize_req', keys = { 'equalize_req' } },
	{ metric = 'drvcc_good', keys = { 'drvcc_good' } },
	{ metric = 'cell_count_error', keys = { 'cell_count_error' } },
	{ metric = 'ok_to_charge', keys = { 'ok_to_charge' } },
	{ metric = 'no_rt', keys = { 'no_rt' } },
	{ metric = 'thermal_shutdown', keys = { 'thermal_shutdown' } },
	{ metric = 'vin_ovlo', keys = { 'vin_ovlo' } },
	{ metric = 'vin_gt_vbat', keys = { 'vin_gt_vbat' } },
	{ metric = 'intvcc_gt_4p3v', keys = { 'intvcc_gt_4p3v' } },
	{ metric = 'intvcc_gt_2p8v', keys = { 'intvcc_gt_2p8v' } },
}

local status_flags = {
	{ metric = 'iin_limited', keys = { 'iin_limited', 'iin_limit_active' } },
	{ metric = 'uvcl_active', keys = { 'uvcl_active', 'vin_uvcl_active' } },
	{ metric = 'cc_phase', keys = { 'cc_phase', 'const_current' } },
	{ metric = 'cv_phase', keys = { 'cv_phase', 'const_voltage' } },
}

local state_flags = {
	{ metric = 'bat_short', keys = { 'bat_short', 'bat_short_fault' } },
	{ metric = 'bat_missing', keys = { 'bat_missing', 'bat_missing_fault' } },
	{ metric = 'max_charge_time_fault', keys = { 'max_charge_time_fault' } },
	{ metric = 'c_over_x_term', keys = { 'c_over_x_term' } },
	{ metric = 'timer_term', keys = { 'timer_term' } },
	{ metric = 'ntc_pause', keys = { 'ntc_pause' } },
	{ metric = 'precharge', keys = { 'precharge' } },
	{ metric = 'cccv', keys = { 'cccv', 'cccv_charge' } },
	{ metric = 'absorb', keys = { 'absorb', 'absorb_charge' } },
	{ metric = 'equalize', keys = { 'equalize', 'equalize_charge' } },
	{ metric = 'suspended', keys = { 'suspended', 'charger_suspended' } },
}

local function has_group(raw_charger, bits_name)
	return raw_charger[bits_name] ~= nil
end

function M.collect_component(rec)
	if type(rec) ~= 'table' then return {} end

	local view = projection.component_view('mcu', rec)
	local raw_facts = table_or_empty(rec.raw_facts)
	local out = {}

	local runtime = table_or_empty(view.runtime)
	local memory = table_or_empty(runtime.memory)
	emit(out, 'alloc', first_number(memory.alloc_bytes, memory.alloc), { 'mcu', 'sys', 'mem', 'alloc' })

	local environment = table_or_empty(view.environment)
	local temperature = table_or_empty(environment.temperature)
	local humidity = table_or_empty(environment.humidity)
	local deci_c = first_number(temperature.deci_c)
	if deci_c ~= nil then
		emit(out, 'core', deci_c / 10, { 'mcu', 'env', 'temperature', 'core' })
	end
	local rh_x100 = first_number(humidity.rh_x100)
	if rh_x100 ~= nil then
		emit(out, 'core', rh_x100 / 100, { 'mcu', 'env', 'humidity', 'core' })
	end

	local power = table_or_empty(view.power)
	local battery = table_or_empty(power.battery)
	local temp_mc = first_number(battery.temp_mC)
	if temp_mc ~= nil then
		emit(out, 'internal', temp_mc / 1000, { 'mcu', 'power', 'temperature', 'internal' })
	end
	emit(out, 'vbat',
		first_number(battery.pack_mV, battery.vbat_mV, battery.vbat),
		{ 'mcu', 'power', 'battery', 'internal', 'vbat' })
	emit(out, 'ibat',
		first_number(battery.ibat_mA, battery.ibat),
		{ 'mcu', 'power', 'battery', 'internal', 'ibat' })

	local charger = table_or_empty(power.charger)
	emit(out, 'vin', first_number(charger.vin_mV, charger.vin), { 'mcu', 'power', 'charger', 'internal', 'vin' })
	emit(out, 'vsys', first_number(charger.vsys_mV, charger.vsys), { 'mcu', 'power', 'charger', 'internal', 'vsys' })
	emit(out, 'iin', first_number(charger.iin_mA, charger.iin), { 'mcu', 'power', 'charger', 'internal', 'iin' })

	local raw_charger = table_or_empty(raw_facts.power_charger)
	if has_group(raw_charger, 'system_bits') then
		emit_boolean_group(out, table_or_empty(charger.system), system_flags,
			{ 'mcu', 'power', 'charger', 'internal', 'system' })
	end
	if has_group(raw_charger, 'status_bits') then
		emit_boolean_group(out, table_or_empty(charger.status), status_flags,
			{ 'mcu', 'power', 'charger', 'internal', 'status' })
	end
	if has_group(raw_charger, 'state_bits') then
		emit_boolean_group(out, table_or_empty(charger.state), state_flags,
			{ 'mcu', 'power', 'charger', 'internal', 'state' })
	end

	return out
end

function M.publish_component(svc, rec)
	if type(svc) ~= 'table' or type(svc.obs_metric) ~= 'function' then return true, nil, 0 end

	local metrics = M.collect_component(rec)
	for i = 1, #metrics do
		local metric = metrics[i]
		svc:obs_metric(metric.name, {
			value = metric.value,
			namespace = metric.namespace,
		})
	end

	return true, nil, #metrics
end

return M
