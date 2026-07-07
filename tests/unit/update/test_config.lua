-- tests/unit/update/test_config.lua

local config = require 'services.update.config'

local tests = {}

local function fail(msg) error(msg or 'assertion failed', 2) end
local function assert_eq(a, b, msg) if a ~= b then fail(msg or ('expected ' .. tostring(b) .. ', got ' .. tostring(a))) end end
local function assert_true(v, msg) if v ~= true then fail(msg or ('expected true, got ' .. tostring(v))) end end
local function assert_not_nil(v, msg) if v == nil then fail(msg or 'expected non-nil value') end end
local function assert_nil(v, msg) if v ~= nil then fail(msg or ('expected nil, got ' .. tostring(v))) end end
local function assert_contains(s, needle, msg)
	if tostring(s or ''):find(tostring(needle), 1, true) == nil then
		fail(msg or ('expected ' .. tostring(s) .. ' to contain ' .. tostring(needle)))
	end
end

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
	assert_eq(cfg.retention.mode, 'single_job')
	assert_eq(cfg.retention.max_jobs, 1)
	assert_true(cfg.retention.scrub_legacy_on_startup)
	assert_eq(cfg.retention.terminal_max_count, 50)
	assert_eq(cfg.retention.terminal_max_age_s, 604800)
end


function tests.test_bundled_job_policy_normalises()
	local cfg, err = config.normalise({
		bundled = {
			enabled = true,
			max_attempts = 7,
			components = {
				mcu = {
					component = 'mcu',
					source = { kind = 'file', path = '/artifacts/mcu.dcmcu', policy = 'transient_only' },
					job = {
						job_id = 'bundled-mcu',
						create_if = 'image_differs',
						start = 'auto',
						commit = 'auto',
						reconcile = 'required',
						supersede = 'same_job_if_image_changed',
						max_attempts = 5,
					},
				},
			},
		},
	})
	assert_not_nil(cfg, err)
	assert_eq(cfg.bundled.max_attempts, 7)
	local mcu = cfg.bundled.components.mcu
	assert_eq(mcu.job.job_id, 'bundled-mcu')
	assert_eq(mcu.job.create_if, 'image_differs')
	assert_eq(mcu.job.start, 'auto')
	assert_eq(mcu.job.commit, 'auto')
	assert_eq(mcu.job.reconcile, 'required')
	assert_eq(mcu.job.supersede, 'same_job_if_image_changed')
	assert_eq(mcu.job.max_attempts, 5)
	assert_nil(mcu.auto_create)
	assert_nil(mcu.auto_start)
end

function tests.test_bundled_legacy_auto_flags_map_to_job_policy()
	local cfg, err = config.normalise({
		bundled = {
			enabled = true,
			max_attempts = 9,
			components = {
				mcu = {
					component = 'mcu',
					source = { kind = 'file', path = '/artifacts/mcu.dcmcu' },
					auto_create = true,
					auto_start = true,
				},
			},
		},
	})
	assert_not_nil(cfg, err)
	local mcu = cfg.bundled.components.mcu
	assert_eq(mcu.job.job_id, 'bundled-mcu')
	assert_eq(mcu.job.create_if, 'always')
	assert_eq(mcu.job.start, 'auto')
	assert_eq(mcu.job.commit, 'manual')
	assert_eq(mcu.job.max_attempts, 9)
	assert_nil(mcu.auto_create)
	assert_nil(mcu.auto_start)
end

function tests.test_bundled_enabled_requires_attempt_budget()
	local cfg, err = config.normalise({
		bundled = {
			enabled = true,
			components = {},
		},
	})
	assert_nil(cfg)
	assert_contains(err, 'bundled.max_attempts')
end

return tests
