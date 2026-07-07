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


function tests.test_redact_list_removes_apn_secrets_but_preserves_presence_flags()
	local redacted = model.redact_list({
		{ carrier='A', mcc='234', mnc='10', apn='internet', user='alice', password='secret', auth='token' },
	})
	eq(redacted[1].carrier, 'A')
	eq(redacted[1].apn, 'internet')
	eq(redacted[1].user, nil)
	eq(redacted[1].password, nil)
	eq(redacted[1].auth, nil)
	eq(redacted[1].has_user, true)
	eq(redacted[1].has_password, true)
	eq(redacted[1].has_auth, true)
end

return tests
