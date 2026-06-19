local projection = require 'services.device.projection'
local catalogue = require 'services.device.catalogue'

local tests = {}
local function assert_not_nil(v,msg) if v == nil then error(msg or 'expected non-nil',2) end end
local function assert_eq(a,b,msg) if a ~= b then error(msg or ('expected '..tostring(b)..', got '..tostring(a)),2) end end

function tests.test_device_projects_physical_assembly_not_wired_observation_capability()
	local cat = catalogue.build({
		assembly = {
			product = 'big-box',
			components = {
				['switch-main'] = { kind = 'switch', role = 'wired-fabric' },
			},
			surfaces = {
				['lan-1'] = {
					component = 'switch-main',
					observed_surface = 'GE2',
					exposure = 'external',
				},
			},
		},
		components = {
			['switch-main'] = {
				kind = 'switch',
				module = 'switch',
				class = 'host',
				role = 'switch-fabric',
				member = 'switch-main',
				facts = {
					wired_observation_status = { 'raw', 'host', 'wired', 'provider', 'switch-main', 'status' },
				},
			},
		},
	})
	local snap = { generation = 7, catalogue = cat, components = cat.components }
	local assembly = projection.assembly_payload(snap, 123)
	assert_eq(assembly.kind, 'device.assembly')
	assert_eq(assembly.product, 'big-box')
	assert_eq(assembly.generation, 7)
	assert_eq(assembly.surfaces['lan-1'].component, 'switch-main')
	assert_eq(assembly.surfaces['lan-1'].observed_surface, 'GE2')

	local payloads = projection.component_payloads('switch-main', cat.components['switch-main'], 123)
	assert_eq(payloads.wired_observation, nil, 'Device must not publish state/wired payloads')
	assert_not_nil(payloads.component, 'component payload should still be projected')
	assert_not_nil(payloads.component.observed, 'component retains observed facts locally')
end


function tests.test_device_assembly_rejects_provider_surface_aliases()
	local ok, err = pcall(function ()
		catalogue.build({
			assembly = {
				surfaces = {
					['lan-1'] = {
						provider = 'switch-main',
						provider_surface_id = 'GE2',
					},
				},
			},
		})
	end)
	assert_eq(ok, false)
	assert_not_nil(tostring(err):find('component and observed_surface only', 1, true))
end

function tests.test_device_assembly_rejects_link_surface_alias()
	local ok, err = pcall(function ()
		catalogue.build({
			assembly = {
				links = {
					['cm5-switch'] = {
						a = { component = 'cm5-local-wired', surface = 'eth0' },
						b = { component = 'switch-main', observed_surface = 'GE8' },
					},
				},
			},
		})
	end)
	assert_eq(ok, false)
	assert_not_nil(tostring(err):find('component and observed_surface only', 1, true))
end

return tests
