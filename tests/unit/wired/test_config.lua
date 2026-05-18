local config = require 'services.wired.config'

local tests = {}
local function assert_true(v, msg) if v ~= true then error(msg or 'expected true', 2) end end
local function assert_not_nil(v, msg) if v == nil then error(msg or 'expected non-nil', 2) end end
local function assert_eq(a,b,msg)
	if a ~= b then error(msg or ('expected '..tostring(b)..', got '..tostring(a)), 2) end
end

function tests.test_cm5_trunk_config_normalises()
	local intent, err = config.normalise({
		schema = config.SCHEMA,
		surfaces = {
			['cm5-eth0'] = {
				kind = 'direct-nic',
				role = 'internal-trunk',
				protected = true,
				provider = { capability_id = 'cm5-local-wired', provider_surface_id = 'eth0' },
				attachment = {
					mode = 'trunk',
					required_segments = { 'mgmt', 'switch_control', 'fabric' },
					user_segments = 'all-realised-user-segments',
				},
			},
		},
	})
	assert_not_nil(intent, err)
	assert_true(intent.surfaces['cm5-eth0'].protected)
	assert_eq(intent.surfaces['cm5-eth0'].attachment.mode, 'trunk')
end


function tests.test_protected_surface_cannot_be_disabled()
	local intent, err = config.normalise({
		schema = config.SCHEMA,
		surfaces = {
			['cm5-eth0'] = {
				protected = true,
				enabled = false,
				provider = { capability_id = 'cm5-local-wired', provider_surface_id = 'eth0' },
				attachment = { mode = 'trunk', required_segments = { 'mgmt' } },
			},
		},
	})
	if intent ~= nil then error('expected invalid protected surface config') end
	assert_not_nil(err)
end

function tests.test_protected_surface_must_be_trunk_with_required_segments()
	local intent, err = config.normalise({
		schema = config.SCHEMA,
		surfaces = {
			['cm5-eth0'] = {
				protected = true,
				provider = { capability_id = 'cm5-local-wired', provider_surface_id = 'eth0' },
				attachment = { mode = 'access', segment = 'lan' },
			},
		},
	})
	if intent ~= nil then error('expected protected non-trunk config to fail') end
	assert_not_nil(err)

	intent, err = config.normalise({
		schema = config.SCHEMA,
		surfaces = {
			['cm5-eth0'] = {
				protected = true,
				provider = { capability_id = 'cm5-local-wired', provider_surface_id = 'eth0' },
				attachment = { mode = 'trunk' },
			},
		},
	})
	if intent ~= nil then error('expected protected trunk without required_segments to fail') end
	assert_not_nil(err)
end

function tests.test_access_surface_requires_segment()
	local intent, err = config.normalise({
		schema = config.SCHEMA,
		surfaces = {
			['lan-1'] = {
				provider = { capability_id = 'switch-main', provider_surface_id = 'port-1' },
				attachment = { mode = 'access' },
			},
		},
	})
	if intent ~= nil then error('expected invalid config') end
	assert_not_nil(err)
end

return tests
