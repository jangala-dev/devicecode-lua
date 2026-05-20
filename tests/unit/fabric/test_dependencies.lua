local deps = require 'services.fabric.dependencies'
local cfg = require 'services.fabric.config'

local T = {}

function T.derives_raw_host_transport_dependency_for_hal_link()
	local compiled = assert(cfg.compile({
		schema = 'devicecode.config/fabric/1',
		links = {{ id = 'uart0', peer_id = 'peer', transport = { source = 'uart', class = 'uart', id = 'main' }, bridge = {}, transfer = {} }},
	}))
	local specs = deps.transport_dependencies(compiled)
	assert(#specs == 1)
	assert(specs[1].key == 'transport:uart0')
	assert(specs[1].raw_kind == 'host')
	assert(specs[1].source == 'uart')
	assert(specs[1].class == 'uart')
	assert(specs[1].id == 'main')
end

function T.override_transport_bypasses_dependency()
	local compiled = assert(cfg.compile({
		schema = 'devicecode.config/fabric/1',
		links = {{ id = 'uart0', peer_id = 'peer', transport = { source = 'uart', class = 'uart', id = 'main' }, bridge = {}, transfer = {} }},
	}))
	local specs = deps.transport_dependencies(compiled, { uart0 = { open_transport_op = function () end } })
	assert(#specs == 0)
end

return T
