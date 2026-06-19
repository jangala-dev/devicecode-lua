local config = require 'services.wired.config'
local deps = require 'services.wired.dependencies'

local T = {}

function T.semantic_surfaces_have_no_capability_dependencies()
	local intent = assert(config.normalise({
		schema = config.SCHEMA,
		surfaces = {
			lan1 = { attachment = { mode = 'access', segment = 'lan' } },
			lan2 = { attachment = { mode = 'access', segment = 'lan' } },
		},
	}))
	local specs = deps.observation_dependencies(intent)
	assert(#specs == 0)
end

function T.provider_mapping_is_no_longer_accepted_in_cfg_wired()
	local intent, err = config.normalise({
		schema = config.SCHEMA,
		surfaces = {
			lan1 = {
				provider = { capability_id = 'switch-main', provider_surface_id = 'port1' },
				attachment = { mode = 'access', segment = 'lan' },
			},
		},
	})
	assert(intent == nil)
	assert(type(err) == 'string' and err:find('provider', 1, true))
end

return T
