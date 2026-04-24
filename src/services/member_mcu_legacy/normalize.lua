-- services/member_mcu_legacy/normalize.lua
--
-- Compatibility normalisation for old BBV1 MCU UART JSON samples.
-- New firmware should publish the canonical member facts directly.  This
-- module is for legacy line-delimited path-keyed JSON only.

local M = {}

local function is_num(v) return type(v) == 'number' end
local function round(n) return math.floor(n + 0.5) end

local function centi_c_to_deci_c(v)
	return is_num(v) and round(v / 10) or nil
end

local function centi_c_to_milli_c(v)
	return is_num(v) and (v * 10) or nil
end

local function maybe_set(t, k, v)
	if v ~= nil then t[k] = v end
end

local function has_any(t)
	return type(t) == 'table' and next(t) ~= nil
end

--- Convert one legacy sample into canonical raw member facts.
---
--- Returns a table keyed by device component fact names, suitable for
--- publishing under state/member/mcu/<...> via member_adapter.runtime.
function M.to_member_facts(sample)
	if type(sample) ~= 'table' then return nil end

	local facts = {}

	local battery = {}
	maybe_set(battery, 'pack_mV', sample['power/battery/internal/vbat'])
	maybe_set(battery, 'ibat_mA', sample['power/battery/internal/ibat'])
	maybe_set(battery, 'bsr_uohm_per_cell', sample['power/battery/internal/bsr'])
	maybe_set(battery, 'temp_mC', centi_c_to_milli_c(sample['power/temperature/internal']))
	if has_any(battery) then facts.power_battery = battery end

	local charger = {}
	maybe_set(charger, 'vin_mV', sample['power/charger/internal/vin'])
	maybe_set(charger, 'vsys_mV', sample['power/charger/internal/vsys'])
	maybe_set(charger, 'iin_mA', sample['power/charger/internal/iin'])

	local system = {}
	maybe_set(system, 'charger_enabled', sample['power/charger/internal/system/charger_enabled'])
	maybe_set(system, 'mppt_en_pin', sample['power/charger/internal/system/mppt_en_pin'])
	maybe_set(system, 'equalize_req', sample['power/charger/internal/system/equalize_req'])
	maybe_set(system, 'drvcc_good', sample['power/charger/internal/system/drvcc_good'])
	maybe_set(system, 'cell_count_error', sample['power/charger/internal/system/cell_count_error'])
	maybe_set(system, 'ok_to_charge', sample['power/charger/internal/system/ok_to_charge'])
	maybe_set(system, 'no_rt', sample['power/charger/internal/system/no_rt'])
	maybe_set(system, 'thermal_shutdown', sample['power/charger/internal/system/thermal_shutdown'])
	maybe_set(system, 'vin_ovlo', sample['power/charger/internal/system/vin_ovlo'])
	maybe_set(system, 'vin_gt_vbat', sample['power/charger/internal/system/vin_gt_vbat'])
	maybe_set(system, 'intvcc_gt_4p3v', sample['power/charger/internal/system/intvcc_gt_4p3v'])
	maybe_set(system, 'intvcc_gt_2p8v', sample['power/charger/internal/system/intvcc_gt_2p8v'])
	if has_any(system) then charger.system = system end

	local status = {}
	maybe_set(status, 'iin_limit_active', sample['power/charger/internal/status/iin_limited'])
	maybe_set(status, 'vin_uvcl_active', sample['power/charger/internal/status/uvcl_active'])
	maybe_set(status, 'const_current', sample['power/charger/internal/status/cc_phase'])
	maybe_set(status, 'const_voltage', sample['power/charger/internal/status/cv_phase'])
	if has_any(status) then charger.status = status end

	local state = {}
	maybe_set(state, 'bat_short_fault', sample['power/charger/internal/state/bat_short'])
	maybe_set(state, 'bat_missing_fault', sample['power/charger/internal/state/bat_missing'])
	maybe_set(state, 'max_charge_time_fault', sample['power/charger/internal/state/max_charge_time_fault'])
	maybe_set(state, 'c_over_x_term', sample['power/charger/internal/state/c_over_x_term'])
	maybe_set(state, 'timer_term', sample['power/charger/internal/state/timer_term'])
	maybe_set(state, 'ntc_pause', sample['power/charger/internal/state/ntc_pause'])
	maybe_set(state, 'precharge', sample['power/charger/internal/state/precharge'])
	maybe_set(state, 'cccv_charge', sample['power/charger/internal/state/cccv'])
	maybe_set(state, 'absorb_charge', sample['power/charger/internal/state/absorb'])
	maybe_set(state, 'equalize_charge', sample['power/charger/internal/state/equalize'])
	maybe_set(state, 'charger_suspended', sample['power/charger/internal/state/suspended'])
	if has_any(state) then charger.state = state end

	if has_any(charger) then facts.power_charger = charger end

	if sample['env/temperature/core'] ~= nil then
		facts.environment_temperature = { deci_c = centi_c_to_deci_c(sample['env/temperature/core']) }
	end

	if sample['env/humidity/core'] ~= nil then
		facts.environment_humidity = { rh_x100 = sample['env/humidity/core'] }
	end

	if sample['sys/mem/alloc'] ~= nil then
		facts.runtime_memory = { alloc_bytes = sample['sys/mem/alloc'] }
	end

	-- Legacy boards have no updater/updateable MCU surface.  These facts let
	-- device compose a visible read-only component if the profile chooses to
	-- feed them into the standard MCU component.
	facts.software = facts.software or { version = sample['sys/fw/version'] or 'legacy' }
	facts.updater = facts.updater or { state = 'unavailable' }
	facts.health = facts.health or { state = 'ok' }

	return facts
end

-- Backwards-compatible helper retained for older callers/tests.  Prefer
-- to_member_facts for new compatibility code.
function M.from_legacy_sample(sample)
	local facts = M.to_member_facts(sample)
	if not facts then return nil end
	return {
		available = true,
		ready = true,
		software = facts.software or {},
		updater = facts.updater or {},
		health = 'ok',
		power = {
			battery = facts.power_battery,
			charger = facts.power_charger,
		},
		environment = {
			temperature = facts.environment_temperature,
			humidity = facts.environment_humidity,
		},
		runtime = {
			memory = facts.runtime_memory,
		},
		source = { kind = 'legacy_uart_json' },
		raw = sample,
	}
end

return M
