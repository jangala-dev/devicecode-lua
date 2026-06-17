local apn = require 'services.gsm.apn'

local tests = {}
local function fail(msg) error(msg or 'assertion failed', 2) end
local function eq(a,b,msg) if a ~= b then fail(msg or ('expected '..tostring(b)..', got '..tostring(a))) end end
local function ok(v,msg) if not v then fail(msg or 'expected truthy') end end

function tests.test_custom_apn_is_ranked_before_default()
	local ranked, rankings = apn.get_ranked_apns('234', '10', '234100000000000', nil, nil, {
		{ carrier='Custom', mcc='234', mnc='10', apn='custom.net' },
	})
	ok(rankings[1])
	eq(rankings[1].name, 'custom-1')
	eq(ranked['custom-1'].apn, 'custom.net')
end

function tests.test_connection_string_uses_allowed_auth_when_present()
	local s, err = apn.build_connection_string({ apn='internet', user='u', password='p', authtype='1' }, true)
	ok(s, err)
	ok(s:find('apn=internet', 1, true))
	ok(s:find('allowed-auth=pap', 1, true))
	ok(s:find('allow-roaming=true', 1, true))
end

return tests
