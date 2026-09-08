local model = require 'services.fabric.profiles.legacy_mcu_metrics_v1.state_model'
local device = require 'services.device.component_mcu'
local tablex = require 'shared.table'
local T = {}

local function update(state, values)
	local next_state, err = model.update(state, values, true)
	assert(next_state, tostring(err))
	return next_state, model.project(next_state)
end

function T.matches_new_mcu_charger_payload_and_device_projection()
	local _, facts = update(model.new(), {
		['power/charger/internal/vin'] = 24000,
		['power/charger/internal/vsys'] = 23900,
		['power/charger/internal/iin'] = 750,
		['power/charger/internal/state/bat_missing'] = 0,
		['power/charger/internal/state/bat_short'] = 0,
		['power/charger/internal/state/cccv'] = 1,
		['power/charger/internal/state/absorb'] = 1,
		['power/charger/internal/status/iin_limited'] = 1,
		['power/charger/internal/status/cv_phase'] = 1,
		['power/charger/internal/system/charger_enabled'] = 1,
		['power/charger/internal/system/vin_gt_vbat'] = 1,
	})
	local new_mcu = { vin_mV = 24000, vsys_mV = 23900, iin_mA = 750,
		state_bits = 0x0240, status_bits = 0x0005, system_bits = 0x2004 }
	assert(tablex.deep_equal(facts['power/charger'], new_mcu))
	assert(tablex.deep_equal(device.compose({ power_charger = new_mcu }),
		device.compose({ power_charger = facts['power/charger'] })))
	assert(table.concat(model.topic('other-mcu', 'power/charger'), '/') == 'raw/member/other-mcu/state/power/charger')
end

function T.derives_battery_presence_and_suppresses_invalid_measurements()
	local state, facts = update(model.new(), {
		['power/battery/internal/vbat'] = 12400,
		['power/battery/internal/ibat'] = 4294966796,
		['power/battery/internal/bsr'] = 2000000,
	})
	assert(facts['power/battery'].presence == 'unknown')
	assert(facts['power/battery'].pack_mV == nil)
	state, facts = update(state, { ['power/charger/internal/state/bat_missing'] = 0 })
	assert(facts['power/battery'].presence == 'unknown')
	state, facts = update(state, { ['power/charger/internal/state/bat_short'] = 0 })
	local battery = facts['power/battery']
	assert(battery.presence == 'present' and battery.measurements_valid)
	assert(battery.pack_mV == 12400 and battery.ibat_mA == -500)
	assert(battery.bsr_uohm_per_cell == 2000000)
	assert(battery.seq == nil and battery.uptime_ms == nil and battery.per_cell_mV == nil)
	local composed = device.compose({ power_battery = battery }).power.battery
	assert(tablex.deep_equal(composed, battery))
	state, facts = update(state, { ['power/charger/internal/state/bat_missing'] = 1 })
	assert(facts['power/battery'].presence == 'absent')
	assert(not facts['power/battery'].measurements_valid and facts['power/battery'].ibat_mA == nil)
	state, facts = update(state, { ['power/charger/internal/state/bat_short'] = 1 })
	assert(facts['power/battery'].presence == 'fault' and facts['power/battery'].reason == 'bat_short_fault')
	state, facts = update(state, {
		['power/charger/internal/state/bat_missing'] = 0,
		['power/charger/internal/state/bat_short'] = 0,
	})
	assert(state.state_seen == 3)
	assert(facts['power/charger'].state_bits == 0)
	assert(facts['power/battery'].presence == 'present' and facts['power/battery'].ibat_mA == -500)
end

function T.waits_for_battery_measurement_and_maps_actual_legacy_sensor_units()
	local state, facts = update(model.new(), {
		['power/charger/internal/state/bat_missing'] = 0,
		['power/charger/internal/state/bat_short'] = 0,
		['env/temperature/core'] = 243,
		['env/humidity/core'] = 4567,
		['power/temperature/internal'] = -15,
	})
	assert(facts['power/battery'].presence == 'present')
	assert(facts['power/battery'].reason == 'battery_measurement_unavailable')
	assert(facts['environment/temperature'].deci_c == 243)
	assert(facts['environment/humidity'].rh_x100 == 4567)
	state, facts = update(state, { ['power/battery/internal/vbat'] = 12400, ['power/battery/internal/ibat'] = -500 })
	assert(state.facts['power/battery'].ibat_mA == -500)
	assert(facts['power/battery'].temp_mC == -1500)
end

return T
