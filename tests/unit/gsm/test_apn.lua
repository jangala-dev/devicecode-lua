local apn = require 'services.gsm.apn'
local fibers = require 'fibers'
local op = require 'fibers.op'
local gsm = require 'services.gsm'

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

function tests.test_apn_connect_continues_when_gid1_is_unavailable()
	fibers.run(function()
		local values = {
			mcc = '655',
			mnc = '10',
			imsi = '655100000000000',
		}
		local connect_string
		local gid1_log
		local state_sub = {
			recv = function() return { payload = 'registered' } end,
			unsubscribe = function() end,
		}
		local cap = {
			call_control_op = function(_, method, args)
				if method == 'get' then
					if args.field == 'gid1' then
						return op.always({ ok = false, reason = 'field unavailable: gid1' })
					end
					return op.always({ ok = true, reason = values[args.field] })
				end
				if method == 'connect' then
					connect_string = args.connection_string
					return op.always({ ok = true, reason = '' })
				end
				return op.always({ ok = false, reason = 'unexpected method: ' .. tostring(method) })
			end,
			get_state_sub = function()
				return state_sub
			end,
		}
		local svc = {
			custom_apns = {
				{ carrier = 'MTN Data', mcc = '655', mnc = '10', apn = 'myMTN' },
			},
			obs_log = function(_, level, payload)
				if type(payload) == 'table' and payload.what == 'gid1_unavailable' then
					gid1_log = { level = level, payload = payload }
				end
			end,
		}
		local modem = setmetatable({
			cap = cap,
			svc = svc,
			cfg = {},
			name = 'primary',
		}, gsm._test.GsmModem)

		local active_apn, connect_err, retry_timeout = modem:_apn_connect()

		eq(connect_err, '')
		eq(retry_timeout, nil)
		eq(active_apn.apn, 'myMTN')
		eq(connect_string, 'apn=myMTN')
		ok(gid1_log, 'expected unavailable GID1 to be logged')
		eq(gid1_log.level, 'warn')
		eq(gid1_log.payload.modem, 'primary')
		eq(gid1_log.payload.err, 'field unavailable: gid1')
	end)
end

return tests
