local safe = require 'coxpcall'
local pulse = require 'fibers.pulse'
local cache = require 'shared.cache'
local runfibers = require 'tests.support.run_fibers'
local driver = require 'services.hal.drivers.modem'
local args = require 'services.hal.types.capability_args'

local tests = {}

---@param actual any
---@param expected any
---@return nil
local function eq(actual, expected)
	assert(actual == expected, 'expected ' .. tostring(expected) .. ', got ' .. tostring(actual))
end

---@return Modem
local function modem()
	return setmetatable({ cache = cache.new(), state_pulse = pulse.new(),
		log = { debug = function() end } }, driver._test.Modem)
end

---@return table<string, ModemInfoGroup>
local function groups()
	local index = 1
	while true do
		local name, value = debug.getupvalue(driver._test.Modem.emitter, index)
		assert(name, 'Emitter group definitions not found')
		if name == 'GROUP_FIELDS' then return value end
		index = index + 1
	end
end

---@param group string
---@param observed_at number
---@return table<string, number>
local function timestamps_for(group, observed_at)
	local timestamps = {}
	for _, field in ipairs(groups()[group].fields) do
		timestamps[field] = observed_at
	end
	return timestamps
end

---@return nil
function tests.test_modem_group_normalisation_maps_fields_and_valid_groups()
	local fields, valid = driver._test.normalise_groups({
		first = { fields = { 'a', 'b' }, does_emit = true },
		second = { fields = { 'c' }, does_emit = false },
	})
	eq(fields.a, 'first')
	eq(fields.b, 'first')
	eq(fields.c, 'second')
	eq(valid.first, true)
	eq(valid.second, true)
	eq(valid.missing, nil)
end

---@return nil
function tests.test_modem_default_groups_emit_existing_fields()
	runfibers.run(function()
		local fetched, emitted, count = {}, nil, 0
		local snapshots = {
			identity = { imei = 'test' },
			ports = { device = 'test-device' },
			sim = { sim = 'test-sim' },
			network = { operator = 'test-operator' },
			signal = { values = { lte = { rssi = -80 } } },
			traffic = { rx_bytes = 123 },
		}
		local observed_at = {
			identity = 101,
			ports = 102,
			sim = 103,
			network = 104,
			signal = 105,
			traffic = 106,
		}
		local m = modem()
		m._get_group = function(_, group)
			fetched[group] = true
			count = count + 1
			if count == 6 then m.state_pulse:close() end
			return snapshots[group], '', timestamps_for(group, observed_at[group])
		end
		m._emit_meta = function() return true end
		m._emit_state = function(_, key, payload)
			eq(key, 'info')
			emitted = payload
			return true
		end
		m.state_pulse:signal()
		m:emitter()
		eq(count, 6)
		assert(fetched.identity and fetched.ports and fetched.sim)
		assert(fetched.network and fetched.signal and fetched.traffic)
		eq(emitted.schema, 'devicecode.hal.modem.info/1')
		eq(emitted.values.imei, 'test')
		eq(emitted.values.operator, 'test-operator')
		eq(emitted.values.signal.lte.rssi, -80)
		eq(emitted.values.rx_bytes, 123)
		eq(emitted.observed_at.imei, 101)
		eq(emitted.observed_at.operator, 104)
		eq(emitted.observed_at.signal, 105)
		eq(emitted.observed_at.rx_bytes, 106)
	end)
end

---@return nil
function tests.test_modem_non_emitting_group_remains_requestable()
	local network = groups().network
	local original = network.does_emit
	network.does_emit = false
	local ok, err = safe.pcall(function()
		runfibers.run(function()
			local emitted, count, network_reads = nil, 0, 0
			local snapshots = {
				identity = { imei = 'test' },
				ports = { device = 'test-device' },
				sim = { sim = 'test-sim' },
				network = { operator = 'test-operator' },
				signal = { values = {} },
				traffic = { rx_bytes = 123 },
			}
			local observed_at = {
				identity = 201,
				ports = 202,
				sim = 203,
				network = 204,
				signal = 205,
				traffic = 206,
			}
			local m = modem()
			m._get_group = function(_, group)
				count = count + 1
				if group == 'network' then network_reads = network_reads + 1 end
				if count == 6 then m.state_pulse:close() end
				return snapshots[group], '', timestamps_for(group, observed_at[group])
			end
			local got, operator = m:get(assert(args.new.ModemGetOpts('operator')))
			eq(got, true)
			eq(operator, 'test-operator')
			m._emit_meta = function() return true end
			m._emit_state = function(_, key, payload)
				eq(key, 'info')
				emitted = payload
				return true
			end
			m.state_pulse:signal()
			m:emitter()
			eq(count, 6)
			eq(network_reads, 1)
			eq(emitted.values.operator, nil)
			eq(emitted.observed_at.operator, nil)
			eq(emitted.values.imei, 'test')
			eq(emitted.observed_at.imei, 201)
		end)
	end)
	network.does_emit = original
	assert(ok, err)
end

return tests
