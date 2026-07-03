local config = require 'services.ui.config'

local M = {}

local function eq(a, b, msg)
	if a ~= b then error((msg or 'assertion failed') .. ': expected ' .. tostring(b) .. ', got ' .. tostring(a), 2) end
end
local function ok(v, msg) if not v then error(msg or 'assertion failed', 2) end return v end

local function update_policy(overrides)
	local upload = {
		enabled = true,
		max_bytes = 1024 * 1024,
		require_auth = false,
		component = 'mcu',
		create_job = true,
		start_job = true,
	}
	local commit = { require_auth = false }
	for k, v in pairs((overrides and overrides.upload) or {}) do upload[k] = v end
	for k, v in pairs((overrides and overrides.commit) or {}) do commit[k] = v end
	return { upload = upload, commit = commit }
end

function M.test_normalise_supplies_http_static_sse_defaults_and_accepts_explicit_update_policy()
	local cfg = ok(config.normalise({ schema = config.SCHEMA, updates = update_policy() }))
	eq(cfg.enabled, true)
	eq(cfg.http.enabled, true)
	eq(cfg.http.cap_id, 'main')
	eq(cfg.http.port, 8080)
	eq(cfg.static.root, 'www')
	eq(cfg.sse.enabled, true)
	eq(cfg.updates.upload.enabled, true)
	eq(cfg.updates.upload.max_bytes, 1024 * 1024)
	eq(cfg.updates.upload.require_auth, false)
	eq(cfg.updates.upload.component, 'mcu')
	eq(cfg.updates.upload.create_job, true)
	eq(cfg.updates.upload.start_job, true)
	eq(cfg.updates.commit.require_auth, false)
	eq(config.DEFAULTS.updates, nil)
	eq(cfg.observability.status_interval_s, 30)
	eq(cfg.observability.coalesce_status_s, 0.05)
end


function M.test_observability_status_interval_is_configurable()
	local cfg = ok(config.normalise({
		schema = config.SCHEMA,
		updates = update_policy(),
		observability = { status_interval_s = 15, coalesce_status_s = 0.1 },
	}))
	eq(cfg.observability.status_interval_s, 15)
	eq(cfg.observability.coalesce_status_s, 0.1)

	cfg = ok(config.normalise({
		schema = config.SCHEMA,
		updates = update_policy(),
		observability = { status_interval_s = false },
	}))
	eq(cfg.observability.status_interval_s, false)

	local bad, err = config.normalise({
		schema = config.SCHEMA,
		updates = update_policy(),
		observability = { every_status = true },
	})
	eq(bad, nil)
	ok(tostring(err):find('observability has unknown field', 1, true))
end

function M.test_update_upload_and_commit_can_require_authentication()
	local cfg = ok(config.normalise({
		schema = config.SCHEMA,
		updates = update_policy({ upload = { require_auth = true }, commit = { require_auth = true } }),
	}))
	eq(cfg.updates.upload.require_auth, true)
	eq(cfg.updates.commit.require_auth, true)
end

function M.test_update_upload_policy_requires_component_create_and_start_fields()
	local cfg, err = config.normalise({
		schema = config.SCHEMA,
		updates = { upload = { enabled = true, max_bytes = 1024, require_auth = false }, commit = { require_auth = false } },
	})
	eq(cfg, nil)
	ok(tostring(err):find('updates.upload.component is required', 1, true))
end

function M.test_update_upload_start_requires_create()
	local cfg, err = config.normalise({
		schema = config.SCHEMA,
		updates = update_policy({ upload = { create_job = false, start_job = true } }),
	})
	eq(cfg, nil)
	ok(tostring(err):find('start_job requires', 1, true))
end

function M.test_can_disable_http_listener_without_disabling_service()
	local cfg = ok(config.normalise({ schema = config.SCHEMA, http = { enabled = false }, updates = update_policy() }))
	eq(cfg.enabled, true)
	eq(cfg.http.enabled, false)
end

function M.test_config_is_explicit_not_derived_from_main_options()
	eq(config.from_legacy_params, nil)
	local cfg = ok(config.normalise({
		schema = config.SCHEMA,
		http = { host = '127.0.0.1', port = 9000, cap_id = 'main' },
		static = { root = '/srv/ui' },
		updates = update_policy(),
	}))
	eq(cfg.http.host, '127.0.0.1')
	eq(cfg.http.port, 9000)
	eq(cfg.static.root, '/srv/ui')
end

function M.test_rejects_unknown_fields()
	local cfg, err = config.normalise({ schema = config.SCHEMA, transport = {}, updates = update_policy() })
	eq(cfg, nil)
	ok(tostring(err):find('unknown field', 1, true))
end

function M.test_rejects_legacy_uploads_field()
	local cfg, err = config.normalise({ schema = config.SCHEMA, uploads = { require_auth = false }, updates = update_policy() })
	eq(cfg, nil)
	ok(tostring(err):find('unknown field', 1, true))
end

return M
