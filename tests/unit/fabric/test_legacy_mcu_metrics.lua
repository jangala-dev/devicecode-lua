local legacy = require 'services.fabric.profiles.legacy_mcu_metrics_v1.processor'
local cjson = require 'cjson.safe'
local tablex = require 'shared.table'
local T = {}

local function processor(args)
	return legacy.new_processor(args or { change_only = true, unsigned_underflow_compat = true })
end

local function feed(p, values, out)
	return legacy.process_line(p, assert(cjson.encode(values)), function(fact, payload)
		out[#out + 1] = { fact = fact, payload = payload }
		return true
	end)
end

function T.publishes_one_complete_fact_per_line_and_filters_unchanged_facts()
	local p, out = processor(), {}
	local values = {
		['power/charger/internal/vin'] = 24000,
		['power/charger/internal/vsys'] = 23900,
		['power/charger/internal/iin'] = 750,
		['power/charger/internal/system/vin_gt_vbat'] = 1,
	}
	assert(feed(p, values, out))
	assert(#out == 1 and out[1].fact == 'power/charger')
	assert(out[1].payload.vin_mV == 24000 and out[1].payload.iin_mA == 750)
	assert(out[1].payload.system_bits == 4)
	assert(feed(p, values, out))
	assert(#out == 1 and p.unchanged == 1)
	values['power/charger/internal/iin'] = 500
	assert(feed(p, values, out))
	assert(#out == 2 and out[2].payload.iin_mA == 500)
	assert(out[1].payload.iin_mA == 750, 'previous retained payload was mutated')
end

function T.preserves_large_unsigned_measurements_and_only_unwraps_signed_fields()
	local p, out = processor(), {}
	assert(feed(p, { ['sys/mem/alloc'] = 2000000 }, out))
	assert(out[1].payload.alloc_bytes == 2000000)
	assert(feed(p, { ['power/charger/internal/iin'] = 4294967176 }, out))
	assert(out[2].payload.iin_mA == -120)
	assert(feed(p, { ['power/charger/internal/iin'] = -120 }, out))
	assert(#out == 2, 'signed and wrapped representations must compare equal')
	p = processor({ unsigned_underflow_compat = false })
	assert(feed(p, { ['power/charger/internal/iin'] = 4294967176 }, out))
	assert(out[3].payload.iin_mA == 4294967176)
end

function T.retries_failed_publication_without_committing_the_line()
	local p, out = processor(), {}
	local line = '{"sys/mem/alloc":100}'
	assert(not legacy.process_line(p, line, function() return nil, 'rejected' end))
	assert(next(p.model.facts) == nil and next(p.cache) == nil)
	assert(feed(p, { ['sys/mem/alloc'] = 100 }, out))
	assert(#out == 1 and out[1].payload.alloc_bytes == 100)
end

function T.rejects_bad_lines_atomically_and_ignores_unknown_keys()
	local p, out = processor(), {}
	assert(feed(p, { ['sys/mem/alloc'] = 100 }, out))
	local before = tablex.deep_copy(p.model)
	for _, line in ipairs({ '{bad', '42', '[]', 'null',
		'{"sys/mem/alloc":200,"power/charger/internal/iin":"bad"}',
		'{"power/charger/internal/state/bat_missing":2}',
	}) do
		assert(not legacy.process_line(p, line, function() error('invalid input published') end))
		assert(tablex.deep_equal(p.model, before))
	end
	assert(p.decode_errors == 6)
	assert(feed(p, { unknown = 42 }, out))
	assert(#out == 1)
end

function T.can_republish_unchanged_facts_without_republishing_unrelated_facts()
	local p, out = processor({ change_only = false }), {}
	assert(feed(p, { ['sys/mem/alloc'] = 100 }, out))
	assert(feed(p, { ['env/temperature/core'] = 243 }, out))
	assert(feed(p, { ['env/temperature/core'] = 243 }, out))
	assert(#out == 3 and out[3].fact == 'environment/temperature')
end

return T
