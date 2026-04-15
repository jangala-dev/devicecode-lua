-- tests/net_model_spec.lua

local model = require 'services.net.model'

local T = {}

local function bundle(rev, gen, weight)
	return {
		rev = rev,
		gen = gen,
		desired = {},
		runtime = {
			timings = {},
			links = {
				wan = {
					link_id = 'wan',
					health = {},
					shaping = {},
					multipath = {
						base_weight = weight or 7,
					},
				},
			},
		},
	}
end

function T.new_runtime_link_uses_multipath_base_weight()
	local m = model.build_runtime_model(bundle(1, 1, 9))
	assert(m.links.wan.multipath.live_weight == 9)
end

function T.merge_bundle_preserves_runtime_counters()
	local m = model.build_runtime_model(bundle(1, 1, 5))
	m.links.wan.counters.rx_bps = 123
	m.links.wan.health.state = 'online'

	model.merge_bundle_into_model(m, bundle(2, 2, 8))

	assert(m.bundle.rev == 2)
	assert(m.bundle.gen == 2)
	assert(m.links.wan.counters.rx_bps == 123)
	assert(m.links.wan.health.state == 'online')
	assert(m.links.wan.multipath.live_weight == 5)
end

return T
