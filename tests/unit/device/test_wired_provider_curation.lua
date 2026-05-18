local projection = require 'services.device.projection'
local wired_provider = require 'services.device.component_wired_provider'

local tests = {}
local function assert_not_nil(v,msg) if v == nil then error(msg or 'expected non-nil',2) end end
local function assert_eq(a,b,msg) if a ~= b then error(msg or ('expected '..tostring(b)..', got '..tostring(a)),2) end end

function tests.test_device_projects_wired_provider_capability_from_component_facts()
	local rec = {
		class = 'host',
		subtype = 'wired-provider',
		role = 'local-wired-provider',
		member = 'local',
		module = wired_provider,
		raw_facts = {
			wired_provider_status = { state = 'available', available = true, mode = 'read_only' },
			wired_provider_surfaces = { surfaces = { eth0 = { provider_surface_id = 'eth0' } } },
			wired_provider_topology = { trunks = {} },
		},
		facts = {
			wired_provider_status = { watch_topic = { 'raw', 'host', 'wired', 'cap', 'wired-provider', 'cm5-local-wired', 'status' } },
		},
	}
	local payloads = projection.component_payloads('cm5-local-wired', rec, 123)
	assert_not_nil(payloads.wired_provider, 'expected curated wired-provider cap payloads')
	assert_eq(payloads.wired_provider.id, 'cm5-local-wired')
	assert_eq(payloads.wired_provider.status.state, 'available')
	assert_not_nil(payloads.wired_provider.surfaces.surfaces.eth0)
end

return tests
