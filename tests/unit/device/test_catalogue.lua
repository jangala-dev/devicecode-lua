-- tests/unit/device/test_catalogue.lua

local config = require 'services.device.config'
local catalogue = require 'services.device.catalogue'
local topics = require 'services.device.topics'

local tests = {}

local function fail(msg) error(msg or 'assertion failed', 2) end
local function assert_eq(a, b, msg) if a ~= b then fail(msg or ('expected ' .. tostring(b) .. ', got ' .. tostring(a))) end end
local function assert_true(v, msg) if v ~= true then fail(msg or ('expected true, got ' .. tostring(v))) end end
local function assert_not_nil(v, msg) if v == nil then fail(msg or 'expected non-nil') end end
local function assert_nil(v, msg) if v ~= nil then fail(msg or ('expected nil, got ' .. tostring(v))) end end

local function sample_config()
	return {
		schema = config.SCHEMA,
		components = {
			mcu = {
				class = 'member',
				subtype = 'mcu',
				member = 'mcu',
				required_facts = { 'software' },
				facts = {
					software = topics.raw_member_state('mcu', 'software'),
				},
				events = {
					alert = topics.raw_member_cap_event('mcu', 'telemetry', 'main', 'alert'),
				},
				actions = {
					restart = { kind = 'rpc', call_topic = topics.raw_member_cap_rpc('mcu', 'control', 'main', 'restart') },
				},
			},
		},
	}
end

function tests.test_config_to_catalogue_normalises_component_routes()
	local cat, err = config.to_catalogue(sample_config())
	assert_nil(err)
	assert_not_nil(cat)
	assert_not_nil(cat.components.mcu)
	assert_eq(cat.components.mcu.facts.software.name, 'software')
	assert_eq(cat.components.mcu.events.alert.name, 'alert')
	assert_eq(cat.components.mcu.actions.restart.kind, 'rpc')
	assert_eq(cat.components.mcu.actions.restart.call_topic[1], 'raw')
end



function tests.test_catalogue_rejects_transitional_action_and_component_aliases()
	local cfg = sample_config()
	cfg.components.mcu.actions.restart = topics.raw_member_cap_rpc('mcu', 'control', 'main', 'restart')
	local cat, err = config.to_catalogue(cfg)
	assert_nil(cat)
	if not tostring(err):find('must be a table with kind and call_topic', 1, true) then
		fail('unexpected error: ' .. tostring(err))
	end

	cfg = sample_config()
	cfg.components.mcu.actions.restart = { kind = 'rpc', topic = topics.raw_member_cap_rpc('mcu', 'control', 'main', 'restart') }
	cat, err = config.to_catalogue(cfg)
	assert_nil(cat)
	if not tostring(err):find('deprecated topic; use call_topic', 1, true) then
		fail('unexpected error: ' .. tostring(err))
	end

	cfg = sample_config()
	cfg.components.mcu.actions.restart = { kind = 'rpc', call_topic = topics.raw_member_cap_rpc('mcu', 'control', 'main', 'restart'), timeout = 1 }
	cat, err = config.to_catalogue(cfg)
	assert_nil(cat)
	if not tostring(err):find('deprecated timeout; use timeout_s', 1, true) then
		fail('unexpected error: ' .. tostring(err))
	end
end

function tests.test_fabric_stage_requires_target_and_rejects_receiver()
	local cfg = sample_config()
	cfg.components.mcu.actions['stage-update'] = {
		kind = 'fabric_stage',
	}
	local cat, err = config.to_catalogue(cfg)
	assert_nil(cat)
	if not tostring(err):find('requires fabric_stage target', 1, true) then
		fail('unexpected error: ' .. tostring(err))
	end

	cfg.components.mcu.actions['stage-update'] = {
		kind = 'fabric_stage',
		receiver = topics.raw_member_cap_rpc('mcu', 'update', 'main', 'stage'),
	}
	cat, err = config.to_catalogue(cfg)
	assert_nil(cat)
	if not tostring(err):find('deprecated receiver; use target', 1, true) then
		fail('unexpected error: ' .. tostring(err))
	end

	cfg.components.mcu.actions['stage-update'] = {
		kind = 'fabric_stage',
		target = 'updater/main',
	}
	cat, err = config.to_catalogue(cfg)
	assert_nil(err)
	assert_not_nil(cat.components.mcu.actions['stage-update'])
end
function tests.test_catalogue_material_comparison_is_stable_for_copies()
	local a = assert(config.to_catalogue(sample_config()))
	local b = catalogue.copy(a)
	assert_true(catalogue.materially_equal(a, b))
	b.components.mcu.required_facts[2] = 'updater'
	if catalogue.materially_equal(a, b) then fail('expected material difference') end
end

return tests
