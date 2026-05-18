local config = require 'services.wired.config'
local service = require 'services.wired.service'

local tests = {}
local function assert_true(v,msg) if v ~= true then error(msg or 'expected true',2) end end
local function assert_not_nil(v,msg) if v == nil then error(msg or 'expected non-nil',2) end end
local function assert_eq(a,b,msg)
	if a ~= b then error(msg or ('expected '..tostring(b)..', got '..tostring(a)),2) end
end

local function protected_intent()
	local intent, err = config.normalise({
		schema = config.SCHEMA,
		surfaces = {
			['switch-uplink-cm5'] = {
				kind = 'switch-port',
				role = 'internal-trunk',
				protected = true,
				provider = { capability_id = 'switch-main', provider_surface_id = 'uplink-cm5' },
				attachment = { mode = 'trunk', required_segments = { 'mgmt', 'switch_control', 'fabric' } },
			},
		},
	})
	assert_not_nil(intent, err)
	return intent
end

function tests.test_protected_trunk_reports_missing_required_vlan_carriage()
	local snap = {
		net = {
			segments = {
				mgmt = { vlan = { id = 10 } },
				switch_control = { vlan = { id = 11 } },
				fabric = { vlan = { id = 12 } },
			},
		},
		config_intent = protected_intent(),
		providers = {
			['switch-main'] = {
				status = { state = 'available', available = true },
				surfaces = {
					['uplink-cm5'] = {
						attachment = { mode = 'trunk', vlans = { 10, 12 } },
					},
				},
			},
		},
		stats = {},
	}
	service._test.rebuild_derived(snap)
	local found = false
	for _, v in ipairs(snap.violations or {}) do
		if v.kind == 'missing_required_segment_carriage' and v.segment == 'switch_control' and v.vlan == 11 then
			found = true
			assert_eq(v.severity, 'critical')
		end
	end
	assert_true(found, 'expected missing switch_control VLAN carriage violation')
	assert_eq(snap.state, 'degraded')
end

function tests.test_protected_trunk_passes_when_all_required_vlans_are_observed()
	local snap = {
		net = {
			segments = {
				mgmt = { vlan = { id = 10 } },
				switch_control = { vlan = { id = 11 } },
				fabric = { vlan = { id = 12 } },
			},
		},
		config_intent = protected_intent(),
		providers = {
			['switch-main'] = {
				status = { state = 'available', available = true },
				surfaces = {
					['uplink-cm5'] = {
						attachment = { mode = 'trunk', vlans = { 10, 11, 12, 100 } },
					},
				},
			},
		},
		stats = {},
	}
	service._test.rebuild_derived(snap)
	for _, v in ipairs(snap.violations or {}) do
		if v.kind == 'missing_required_segment_carriage' then
			error('unexpected carriage violation: '..tostring(v.segment), 2)
		end
	end
	assert_eq(snap.state, 'running')
end


function tests.test_protected_trunk_reports_provider_missing()
	local snap = {
		net = { segments = { mgmt = { vlan = { id = 10 } } } },
		config_intent = protected_intent(),
		providers = {},
		stats = {},
	}
	service._test.rebuild_derived(snap)
	local found = false
	for _, v in ipairs(snap.violations or {}) do
		if v.kind == 'protected_provider_missing' and v.surface_id == 'switch-uplink-cm5' then
			found = true
			assert_eq(v.severity, 'critical')
		end
	end
	assert_true(found, 'expected protected provider missing violation')
end

function tests.test_protected_trunk_reports_provider_surface_missing()
	local snap = {
		net = {
			segments = {
				mgmt = { vlan = { id = 10 } },
				switch_control = { vlan = { id = 11 } },
				fabric = { vlan = { id = 12 } },
			},
		},
		config_intent = protected_intent(),
		providers = { ['switch-main'] = { status = { state = 'available', available = true }, surfaces = {} } },
		stats = {},
	}
	service._test.rebuild_derived(snap)
	local found = false
	for _, v in ipairs(snap.violations or {}) do
		if v.kind == 'protected_provider_surface_missing' and v.provider_surface_id == 'uplink-cm5' then
			found = true
			assert_eq(v.severity, 'critical')
		end
	end
	assert_true(found, 'expected protected provider surface missing violation')
end

function tests.test_all_realised_user_segments_are_checked_on_protected_trunk()
	local intent, err = config.normalise({
		schema = config.SCHEMA,
		surfaces = {
			['switch-uplink-cm5'] = {
				protected = true,
				provider = { capability_id = 'switch-main', provider_surface_id = 'uplink-cm5' },
				attachment = { mode = 'trunk', required_segments = { 'mgmt' }, user_segments = 'all-realised-user-segments' },
			},
		},
	})
	assert_not_nil(intent, err)
	local snap = {
		net = {
			segments = {
				mgmt = { protected = true, kind = 'system', vlan = { id = 10 } },
				lan = { kind = 'user', vlan = { id = 100 } },
				guest = { kind = 'guest', vlan = { id = 101 } },
			},
		},
		config_intent = intent,
		providers = {
			['switch-main'] = {
				status = { state = 'available', available = true },
				surfaces = {
					['uplink-cm5'] = {
						attachment = { mode = 'trunk', vlans = { 10, 100 } },
					},
				},
			},
		},
		stats = {},
	}
	service._test.rebuild_derived(snap)
	local found = false
	for _, v in ipairs(snap.violations or {}) do
		if v.kind == 'missing_user_segment_carriage' and v.segment == 'guest' and v.vlan == 101 then found = true end
	end
	assert_true(found, 'expected missing guest user-segment carriage violation')
end

function tests.test_provider_capability_checks_report_unsupported_access_trunk_and_poe()
	local intent, err = config.normalise({
		schema = config.SCHEMA,
		surfaces = {
			['lan-1'] = {
				provider = { capability_id = 'switch-main', provider_surface_id = 'port-1' },
				capabilities = { poe = true },
				attachment = { mode = 'access', segment = 'lan' },
			},
			['trunk-1'] = {
				provider = { capability_id = 'switch-main', provider_surface_id = 'port-2' },
				attachment = { mode = 'trunk', segments = { 'lan' } },
			},
		},
	})
	assert_not_nil(intent, err)
	local snap = {
		net = { segments = { lan = { vlan = { id = 100 } } } },
		config_intent = intent,
		providers = {
				['switch-main'] = {
					status = { state = 'available', available = true },
					surfaces = {
						['port-1'] = {
							capabilities = { access = false, trunk = true, poe = false },
							attachment = { mode = 'access', vlan = 100 },
						},
						['port-2'] = {
							capabilities = { access = true, trunk = false, poe = false },
							attachment = { mode = 'access', vlan = 100 },
						},
					},
			},
		},
		stats = {},
	}
	service._test.rebuild_derived(snap)
	local seen = {}
	for _, v in ipairs(snap.violations or {}) do seen[v.kind] = true end
	assert_true(seen.provider_surface_does_not_support_access, 'access capability violation expected')
	assert_true(seen.provider_surface_does_not_support_trunk, 'trunk capability violation expected')
	assert_true(seen.provider_surface_does_not_support_poe, 'poe capability violation expected')
end

return tests
