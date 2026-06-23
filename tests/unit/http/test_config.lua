local config = require 'services.http.config'

local M = {}

local function eq(a, b, msg)
	if a ~= b then error((msg or 'assertion failed') .. ': expected ' .. tostring(b) .. ', got ' .. tostring(a), 2) end
end
local function ok(v, msg) if not v then error(msg or 'assertion failed', 2) end return v end

function M.test_normalise_supplies_safe_defaults()
	local cfg = ok(config.normalise({ schema = config.SCHEMA }))
	eq(cfg.id, 'main')
	eq(cfg.enabled, true)
	eq(cfg.policy.allowed_schemes.http, true)
	eq(cfg.policy.allowed_schemes.https, true)
	eq(cfg.policy.allowed_schemes.ws, true)
	eq(cfg.policy.allowed_schemes.wss, true)
	eq(cfg.policy.allowed_response_parsers.strict, true)
	eq(cfg.policy.allowed_response_parsers['legacy-http1-close'], nil)
	eq(cfg.policy.legacy_http1_close_max_response_bytes, 1024 * 1024)
	eq(cfg.observability.status_interval_s, 30)
	eq(cfg.observability.request_trace, false)
	eq(cfg.observability.success_events, false)
	eq(cfg.observability.failure_rate_limit_s, 60)
end

function M.test_policy_updates_are_copied_and_validated()
	local raw = {
		schema = config.SCHEMA,
		policy = {
			allowed_schemes = { https = true },
			allow_loopback = false,
			allowed_hosts = { ['example.com'] = true },
			allowed_response_parsers = { strict = true, ['legacy-http1-close'] = true },
			legacy_http1_close_max_response_bytes = 12345,
		},
	}
	local cfg = ok(config.normalise(raw))
	eq(cfg.policy.allowed_schemes.https, true)
	eq(cfg.policy.allowed_schemes.http, nil)
	eq(cfg.policy.allow_loopback, false)
	eq(cfg.policy.allowed_response_parsers['legacy-http1-close'], true)
	eq(cfg.policy.legacy_http1_close_max_response_bytes, 12345)
	raw.policy.allowed_hosts['example.com'] = false
	eq(cfg.policy.allowed_hosts['example.com'], true, 'normalised config must not alias raw tables')
end


function M.test_observability_updates_are_copied_and_validated()
	local raw = {
		schema = config.SCHEMA,
		observability = {
			status_interval_s = 10,
			request_trace = true,
			success_events = true,
			failure_rate_limit_s = 20,
		},
	}
	local cfg = ok(config.normalise(raw))
	eq(cfg.observability.status_interval_s, 10)
	eq(cfg.observability.request_trace, true)
	eq(cfg.observability.success_events, true)
	eq(cfg.observability.failure_rate_limit_s, 20)
	raw.observability.status_interval_s = 99
	eq(cfg.observability.status_interval_s, 10, 'normalised config must not alias raw observability')

	local bad, err = config.normalise({ schema = config.SCHEMA, observability = { every_request = true } })
	eq(bad, nil)
	ok(tostring(err):find('observability has unknown field', 1, true))
end

function M.test_rejects_unknown_fields()
	local cfg, err = config.normalise({ schema = config.SCHEMA, backend = {} })
	eq(cfg, nil)
	ok(tostring(err):find('unknown field', 1, true))
end

return M
