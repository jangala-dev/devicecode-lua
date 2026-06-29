-- tests/unit/update/test_config.lua

local config = require 'services.update.config'

local tests = {}

local function fail(msg) error(msg or 'assertion failed', 2) end
local function assert_eq(a, b, msg) if a ~= b then fail(msg or ('expected ' .. tostring(b) .. ', got ' .. tostring(a))) end end
local function assert_true(v, msg) if v ~= true then fail(msg or ('expected true, got ' .. tostring(v))) end end
local function assert_not_nil(v, msg) if v == nil then fail(msg or 'expected non-nil value') end end

function tests.test_default_config_normalises()
	local cfg, err = config.normalise({})
	assert_not_nil(cfg, err)
	assert_eq(cfg.schema, config.SCHEMA)
	assert_eq(cfg.service_id, 'update')
	assert_eq(cfg.namespace, 'default')
	assert_eq(cfg.summary.component_count, 0)
	assert_true(cfg.publish.enabled)
end

function tests.test_components_array_is_normalised_to_map()
	local cfg, err = config.normalise({
		components = {
			{ component = 'cm5', backend = 'swupdate', stage_timeout_s = '12.5' },
			{ component = 'mcu', backend = 'mcu' },
		},
	})
	assert_not_nil(cfg, err)
	assert_eq(cfg.components.cm5.component, 'cm5')
	assert_eq(cfg.components.cm5.stage_timeout_s, 12.5)
	assert_eq(cfg.components.mcu.component, 'mcu')
	assert_eq(cfg.summary.component_count, 2)
end


function tests.test_components_array_requires_component_identifier_field()
	local cfg, err = config.normalise({
		components = {
			{ id = 'cm5', backend = 'swupdate' },
		},
	})
	if cfg ~= nil then fail('expected id alias to be rejected') end
	assert_not_nil(err)
end

function tests.test_unsupported_schema_is_rejected()
	local cfg, err = config.normalise({ schema = 'wrong/schema' })
	if cfg ~= nil then fail('expected config to be rejected') end
	assert_not_nil(err)
end

function tests.test_component_phase_timeouts_must_be_positive_numbers()
	local cfg, err = config.normalise({
		components = {
			mcu = { component = 'mcu', stage_timeout_s = 0 },
		},
	})
	if cfg ~= nil then fail('expected zero stage timeout to be rejected') end
	assert_not_nil(err)
	assert_true(tostring(err):find('stage_timeout_s', 1, true) ~= nil, err)
end

function tests.test_extract_payload_accepts_config_service_shape()
	local raw, rev = config.extract_payload({ rev = 7, data = { schema = config.SCHEMA, namespace = 'prod' } })
	assert_eq(rev, 7)
	assert_eq(raw.namespace, 'prod')
end

function tests.test_retention_policy_normalises()
	local cfg, err = config.normalise({
		retention = {
			prune_on_startup = true,
			terminal_max_count = '50',
			terminal_max_age_s = '604800',
		},
	})
	assert_not_nil(cfg, err)
	assert_true(cfg.retention.prune_on_startup)
	assert_eq(cfg.retention.terminal_max_count, 50)
	assert_eq(cfg.retention.terminal_max_age_s, 604800)
end

return tests
