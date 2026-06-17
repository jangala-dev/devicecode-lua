local config = require 'services.device.config'
local topics = require 'services.device.topics'
local deps = require 'services.device.dependencies'

local T = {}

function T.derives_explicit_action_dependency()
	local cat = assert(config.to_catalogue({
		schema = config.SCHEMA,
		components = {
			mcu = {
				class = 'member', subtype = 'mcu', member = 'mcu',
				facts = { software = topics.raw_member_state('mcu', 'software') },
				actions = {
					restart = {
						kind = 'rpc',
						call_topic = topics.raw_member_cap_rpc('mcu', 'control', 'main', 'restart'),
						dependency = { raw_kind = 'member', source = 'mcu', class = 'control', id = 'main' },
					},
				},
			},
		},
	}))
	local specs, map, err = deps.catalogue_dependencies(cat)
	assert(err == nil)
	assert(#specs == 1)
	assert(specs[1].key == 'action:mcu:restart')
	assert(specs[1].raw_kind == 'member')
	assert(specs[1].source == 'mcu')
	assert(specs[1].class == 'control')
	assert(map.mcu.restart == specs[1].key)
end

function T.actions_without_metadata_have_no_dependency()
	local cat = assert(config.to_catalogue({
		schema = config.SCHEMA,
		components = {
			mcu = {
				class = 'member', subtype = 'mcu', member = 'mcu',
				facts = { software = topics.raw_member_state('mcu', 'software') },
				actions = { restart = { kind = 'rpc', call_topic = topics.raw_member_cap_rpc('mcu', 'control', 'main', 'restart') } },
			},
		},
	}))
	local specs = assert(deps.catalogue_dependencies(cat))
	assert(#specs == 0)
end

return T
