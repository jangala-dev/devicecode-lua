local config = require 'services.wired.config'
local deps = require 'services.wired.dependencies'

local T = {}

function T.derives_unique_provider_dependencies_from_surfaces()
	local intent = assert(config.normalise({
		schema = config.SCHEMA,
		surfaces = {
			lan1 = { provider = { capability_id = 'switch-main', provider_surface_id = 'port1' }, attachment = { mode = 'access', segment = 'lan' } },
			lan2 = { provider = { capability_id = 'switch-main', provider_surface_id = 'port2' }, attachment = { mode = 'access', segment = 'lan' } },
		},
	}))
	local specs = deps.provider_dependencies(intent)
	assert(#specs == 1)
	assert(specs[1].key == 'provider:switch-main')
	assert(specs[1].class == 'wired-provider')
	assert(specs[1].id == 'switch-main')
	assert(specs[1].required == false)
end

return T
