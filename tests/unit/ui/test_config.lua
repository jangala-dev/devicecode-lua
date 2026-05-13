local config = require 'services.ui.config'

local M = {}

local function eq(a, b, msg)
	if a ~= b then error((msg or 'assertion failed') .. ': expected ' .. tostring(b) .. ', got ' .. tostring(a), 2) end
end
local function ok(v, msg) if not v then error(msg or 'assertion failed', 2) end return v end

function M.test_normalise_supplies_http_static_sse_and_upload_defaults()
	local cfg = ok(config.normalise({ schema = config.SCHEMA }))
	eq(cfg.enabled, true)
	eq(cfg.http.enabled, true)
	eq(cfg.http.cap_id, 'main')
	eq(cfg.http.port, 8080)
	eq(cfg.static.root, 'www')
	eq(cfg.sse.enabled, true)
	eq(cfg.uploads.enabled, true)
end

function M.test_can_disable_http_listener_without_disabling_service()
	local cfg = ok(config.normalise({ schema = config.SCHEMA, http = { enabled = false } }))
	eq(cfg.enabled, true)
	eq(cfg.http.enabled, false)
end

function M.test_config_is_explicit_not_derived_from_main_options()
	eq(config.from_legacy_params, nil)
	local cfg = ok(config.normalise({
		schema = config.SCHEMA,
		http = { host = '127.0.0.1', port = 9000, cap_id = 'main' },
		static = { root = '/srv/ui' },
	}))
	eq(cfg.http.host, '127.0.0.1')
	eq(cfg.http.port, 9000)
	eq(cfg.static.root, '/srv/ui')
end

function M.test_rejects_unknown_fields()
	local cfg, err = config.normalise({ schema = config.SCHEMA, transport = {} })
	eq(cfg, nil)
	ok(tostring(err):find('unknown field', 1, true))
end

return M
