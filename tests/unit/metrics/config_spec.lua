-- tests/unit/metrics/config_spec.lua
--
-- Pure unit tests for services.metrics.config.
-- No fibers needed; all tests are synchronous function calls.

local conf = require 'services.metrics.config'

local T = {}

function T.validate_http_config_valid()
	local ok, err = conf.validate_http_config({
		url       = 'http://cloud.example.com',
		thing_key = 'key',
		channels  = { { id = 'ch1', name = 'data' } },
	})
	assert(ok == true, 'expected valid http config, got err=' .. tostring(err))
	assert(err == nil, 'expected no error, got ' .. tostring(err))
end

function T.validate_http_config_nil()
	local ok, err = conf.validate_http_config(nil)
	assert(ok == false, 'expected invalid for nil config')
	assert(err ~= nil, 'expected error message')
end

function T.validate_http_config_missing_url()
	local ok, err = conf.validate_http_config({ thing_key = 'k', channels = {} })
	assert(ok == false, 'expected invalid config missing url')
	assert(err ~= nil, 'expected error message')
end

function T.merge_config()
	local merged = conf.merge_config(
		{ a = 1, nested = { x = 10, y = 20 } },
		{ b = 2, nested = { y = 99, z = 30 } }
	)
	assert(merged.a == 1,  'expected merged.a=1')
	assert(merged.b == 2,  'expected merged.b=2')
	assert(merged.nested.x == 10, 'expected nested.x=10')
	assert(merged.nested.y == 99, 'expected nested.y=99 (overridden)')
	assert(merged.nested.z == 30, 'expected nested.z=30 (added)')
end

function T.apply_config_builds_pipeline()
	local map, period = conf.apply_config({
		publish_period = 30,
		pipelines = {
			rx_bytes = {
				protocol = 'log',
				process  = { { type = 'DeltaValue' } },
			},
		},
	})
	assert(period == 30, 'expected period=30, got ' .. tostring(period))
	assert(map.rx_bytes ~= nil, 'expected pipeline entry for rx_bytes')
	assert(map.rx_bytes.protocol == 'log', 'expected protocol=log')
	assert(map.rx_bytes.pipeline ~= nil, 'expected pipeline object')
end

function T.validate_config_rejects_bad_period()
	local ok, _, err = conf.validate_config({
		publish_period = -1,
		pipelines      = { sim = { protocol = 'log', process = {} } },
	})
	assert(ok == false, 'expected invalid config with period=-1')
	assert(err ~= nil, 'expected error message')
end

function T.validate_config_warns_bad_protocol()
	local ok, warns = conf.validate_config({
		publish_period = 10,
		pipelines      = { sim = { protocol = 'invalid' } },
	})
	assert(ok == true, 'expected ok=true (warnings, not fatal)')
	assert(#warns > 0, 'expected at least one warning for invalid protocol')
end

function T.validate_config_propagates_invalid_template_to_pipeline()
	local ok, warns, err = conf.validate_config({
		publish_period = 10,
		templates = {
			bad_template = {
				protocol = 'invalid',
			},
		},
		pipelines = {
			sim = {
				template = 'bad_template',
			},
		},
	})

	assert(ok == true,  'expected ok=true')
	assert(err == nil,  'expected no fatal error')

	local saw_template_invalid              = false
	local saw_metric_uses_invalid_template  = false
	local saw_metric_invalid_protocol       = false

	for _, w in ipairs(warns) do
		if w.type == 'template'
			and w.endpoint == 'bad_template'
			and string.find(w.msg, "invalid protocol 'invalid'", 1, true)
		then
			saw_template_invalid = true
		end

		if w.type == 'metric'
			and w.endpoint == 'sim'
			and string.find(w.msg, 'uses invalid template [bad_template]', 1, true)
		then
			saw_metric_uses_invalid_template = true
		end

		if w.type == 'metric'
			and w.endpoint == 'sim'
			and string.find(w.msg, "invalid protocol 'invalid'", 1, true)
		then
			saw_metric_invalid_protocol = true
		end
	end

	assert(saw_template_invalid,             'expected warning: template bad_template has invalid protocol')
	assert(saw_metric_uses_invalid_template, 'expected warning: sim uses invalid template [bad_template]')
	assert(saw_metric_invalid_protocol,      "expected warning: sim inherited invalid protocol 'invalid'")
end

return T
