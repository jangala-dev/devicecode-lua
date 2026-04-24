-- tests/unit/metrics/senml_spec.lua
--
-- Pure unit tests for services.metrics.senml encoder.
-- No fibers needed; all tests are synchronous function calls.

local senml = require 'services.metrics.senml'

local T = {}

function T.encode_number()
	local rec, err = senml.encode('cpu', 42.5)
	assert(err == nil, tostring(err))
	assert(rec.n == 'cpu',  'expected n=cpu, got ' .. tostring(rec.n))
	assert(rec.v == 42.5,   'expected v=42.5, got ' .. tostring(rec.v))
end

function T.encode_string()
	local rec, err = senml.encode('status', 'ok')
	assert(err == nil, tostring(err))
	assert(rec.vs == 'ok', 'expected vs=ok, got ' .. tostring(rec.vs))
end

function T.encode_boolean()
	local rec, err = senml.encode('flag', true)
	assert(err == nil, tostring(err))
	assert(rec.vb == true, 'expected vb=true')
end

function T.encode_with_time()
	local rec, err = senml.encode('t', 1, 1000)
	assert(err == nil, tostring(err))
	assert(rec.t == 1000, 'expected t=1000, got ' .. tostring(rec.t))
end

function T.encode_invalid_value()
	local rec, err = senml.encode('k', {})
	assert(rec == nil, 'expected nil record for invalid value')
	assert(err ~= nil, 'expected error for invalid value type')
end

function T.encode_r_flat()
	local recs, err = senml.encode_r('dev', { temp = 23.5, status = 'on' })
	assert(err == nil, tostring(err))
	assert(#recs == 2, 'expected 2 records, got ' .. tostring(#recs))

	local names = {}
	for _, r in ipairs(recs) do names[r.n] = r end

	assert(names['dev.temp'] ~= nil,   'expected record dev.temp')
	assert(names['dev.temp'].v == 23.5, 'expected dev.temp.v=23.5')
	assert(names['dev.status'] ~= nil,  'expected record dev.status')
	assert(names['dev.status'].vs == 'on', 'expected dev.status.vs=on')
end

return T
