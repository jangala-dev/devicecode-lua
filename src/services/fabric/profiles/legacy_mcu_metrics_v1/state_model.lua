-- Translate dc-go-10-4 scalar JSON into the retained fact shape exported by
-- dc-go-11-0. Only measurements actually emitted by the legacy peer are used.
local bit = rawget(_G, 'bit') or require 'bit32'
local tablex = require 'shared.table'

local M = {}

local ROUTES = {
	['power/battery/internal/vbat'] = { fact = 'power/battery', field = 'pack_mV' },
	['power/battery/internal/ibat'] = { fact = 'power/battery', field = 'ibat_mA', signed = true },
	['power/battery/internal/bsr'] = { fact = 'power/battery', field = 'bsr_uohm_per_cell' },
	['power/temperature/internal'] = { fact = 'power/battery', field = 'temp_mC', scale = 100, signed = true },
	['power/charger/internal/vin'] = { fact = 'power/charger', field = 'vin_mV' },
	['power/charger/internal/vsys'] = { fact = 'power/charger', field = 'vsys_mV' },
	['power/charger/internal/iin'] = { fact = 'power/charger', field = 'iin_mA', signed = true },
	['env/temperature/core'] = { fact = 'environment/temperature', field = 'deci_c', signed = true },
	['env/humidity/core'] = { fact = 'environment/humidity', field = 'rh_x100' },
	['sys/mem/alloc'] = { fact = 'runtime/memory', field = 'alloc_bytes' },
}

local FLAGS = {
	state = {
		bat_short = 0x0001, bat_missing = 0x0002, max_charge_time_fault = 0x0004,
		c_over_x_term = 0x0008, timer_term = 0x0010, ntc_pause = 0x0020,
		cccv = 0x0040, precharge = 0x0080, suspended = 0x0100,
		absorb = 0x0200, equalize = 0x0400,
	},
	status = { cv_phase = 0x0001, cc_phase = 0x0002, iin_limited = 0x0004, uvcl_active = 0x0008 },
	system = {
		intvcc_gt_2p8v = 0x0001, intvcc_gt_4p3v = 0x0002, vin_gt_vbat = 0x0004,
		vin_ovlo = 0x0008, thermal_shutdown = 0x0010, no_rt = 0x0020,
		ok_to_charge = 0x0040, cell_count_error = 0x0100, drvcc_good = 0x0200,
		equalize_req = 0x0400, mppt_en_pin = 0x0800, charger_enabled = 0x2000,
	},
}

for group, flags in pairs(FLAGS) do
	for name, mask in pairs(flags) do
		ROUTES['power/charger/internal/' .. group .. '/' .. name] = {
			fact = 'power/charger', field = group .. '_bits', mask = mask,
		}
	end
end

function M.new()
	return { facts = {}, state_seen = 0 }
end

-- Work on a copy: invalid input or a failed publication must not consume a
-- partial update. All fields in a JSON line reach the publisher together.
function M.update(model, decoded, underflow_compat)
	local next_model = tablex.deep_copy(model)
	local touched = {}
	for key, value in pairs(decoded) do
		local route = ROUTES[key]
		if route then
			if route.mask then
				if value ~= true and value ~= false and value ~= 0 and value ~= 1 then
					return nil, 'invalid legacy MCU flag: ' .. key
				end
			elseif type(value) ~= 'number' or value ~= value or math.abs(value) == math.huge
				or value % 1 ~= 0 then
				return nil, 'invalid legacy MCU measurement: ' .. key
			end
			local fact = next_model.facts[route.fact] or {}
			next_model.facts[route.fact] = fact
			touched[route.fact] = true
			if route.mask then
				local bits = fact[route.field] or 0
				fact[route.field] = (value == true or value == 1)
					and bit.bor(bits, route.mask) or bit.band(bits, bit.bnot(route.mask))
				if route.field == 'state_bits' then
					next_model.state_seen = bit.bor(next_model.state_seen, route.mask)
					touched['power/battery'] = true
				end
			else
				if underflow_compat and route.signed and value >= 2147483648 and value < 4294967296 then
					value = value - 4294967296
				end
				fact[route.field] = value * (route.scale or 1)
			end
		end
	end
	return next_model, touched
end

function M.project(model)
	local out = tablex.deep_copy(model.facts)
	if out['power/battery'] or model.state_seen ~= 0 then
		local battery = out['power/battery'] or {}
		local charger = out['power/charger'] or {}
		local state = charger.state_bits or 0
		local presence, reason = 'present', nil
		if bit.band(state, 0x0001) ~= 0 then
			presence, reason = 'fault', 'bat_short_fault'
		elseif bit.band(state, 0x0002) ~= 0 then
			presence, reason = 'absent', 'bat_missing_fault'
		elseif bit.band(model.state_seen, 0x0003) ~= 0x0003 then
			presence, reason = 'unknown', 'charger_state_unknown'
		elseif battery.pack_mV == nil or battery.ibat_mA == nil then
			reason = 'battery_measurement_unavailable'
		end
		local valid = presence == 'present' and reason == nil
		-- Keep cached samples internally, as the new MCU does, but never expose
		-- floating battery measurements while presence is absent/unknown/faulted.
		if not valid then battery = {} end
		battery.presence, battery.measurements_valid, battery.reason = presence, valid, reason
		out['power/battery'] = battery
	end
	return out
end

function M.topic(member, fact)
	local topic = { 'raw', 'member', member, 'state' }
	for part in fact:gmatch('[^/]+') do topic[#topic + 1] = part end
	return topic
end

return M
