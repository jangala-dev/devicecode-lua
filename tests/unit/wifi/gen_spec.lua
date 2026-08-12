local gen = require 'services.wifi.gen'

local T = {}

function T.userid_is_deterministic_for_a_salt()
	local mac = '00:11:22:33:44:55'
	local salt = 'target-salt'

	assert(gen.userid(mac, salt) == '760205')
	assert(gen.userid(mac, salt) == gen.userid(mac, salt))
end

function T.userid_changes_with_the_salt()
	local mac = '00:11:22:33:44:55'

	assert(gen.userid(mac, 'first-salt') ~= gen.userid(mac, 'second-salt'))
end

return T
