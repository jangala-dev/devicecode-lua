local model = require 'services.gsm.apn_model'

local tests = {}
local function fail(msg) error(msg or 'assertion failed', 2) end
local function eq(a,b,msg) if a ~= b then fail(msg or ('expected '..tostring(b)..', got '..tostring(a))) end end
local function ok(v,msg) if not v then fail(msg or 'expected truthy') end end

function tests.test_normalise_record_requires_core_fields()
	local rec, err = model.normalise_record({ carrier=' Test ', mcc='234', mnc='10', apn=' internet ' })
	ok(rec, err)
	eq(rec.carrier, 'Test')
	eq(rec.apn, 'internet')
	local bad = model.normalise_record({ carrier='x', mcc='23', mnc='10', apn='internet' })
	if bad then fail('invalid MCC accepted') end
end

function tests.test_normalise_list_rejects_duplicates()
	local list, err = model.normalise_list({
		{ carrier='A', mcc='234', mnc='10', apn='internet' },
		{ carrier='A', mcc='234', mnc='10', apn='internet' },
	})
	if list then fail('duplicate accepted') end
	ok(err and err:find('duplicate', 1, true))
end

return tests
