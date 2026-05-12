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
end

function M.test_policy_updates_are_copied_and_validated()
	local raw = {
		schema = config.SCHEMA,
		policy = {
			allowed_schemes = { https = true },
			allow_loopback = false,
			allowed_hosts = { ['example.com'] = true },
		},
	}
	local cfg = ok(config.normalise(raw))
	eq(cfg.policy.allowed_schemes.https, true)
	eq(cfg.policy.allowed_schemes.http, nil)
	eq(cfg.policy.allow_loopback, false)
	raw.policy.allowed_hosts['example.com'] = false
	eq(cfg.policy.allowed_hosts['example.com'], true, 'normalised config must not alias raw tables')
end

function M.test_rejects_unknown_fields()
	local cfg, err = config.normalise({ schema = config.SCHEMA, backend = {} })
	eq(cfg, nil)
	ok(tostring(err):find('unknown field', 1, true))
end

return M
