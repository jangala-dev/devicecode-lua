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

function tests.test_redact_connection_string_hides_only_the_password()
	local apns = require 'services.gsm.apn'
	local out = apns.redact_connection_string('apn=example,user=me,password=s3cret,allow-roaming=true')
	assert(out == 'apn=example,user=me,password=***,allow-roaming=true', out)
	assert(apns.redact_connection_string('apn=example') == 'apn=example')
	local err = apns.redact_connection_string('mmcli --simple-connect=apn=a,password=s3cret failed for modem 0')
	assert(err == 'mmcli --simple-connect=apn=a,password=*** failed for modem 0', err)
end

-- A failed connect's error repeats the whole mmcli command, password included.
function tests.test_apn_connect_never_logs_the_password()
	fibers.run(function()
		local values = { mcc = '001', mnc = '01', imsi = '001010000000000', gid1 = 'ff' }
		local logged = {}
		local cap = {
			call_control_op = function(_, method, args)
				if method == 'get' then return op.always({ ok = true, reason = values[args.field] }) end
				if method == 'connect' then
					return op.always({ ok = false, reason = 'mmcli -m 0 --simple-connect='
						.. args.connection_string .. ' failed for modem 0: error, output: nope' })
				end
				return op.always({ ok = false, reason = 'unexpected method: ' .. tostring(method) })
			end,
			get_state_sub = function()
				return {
					recv = function() return { payload = 'registered' } end,
					recv_op = function() return op.always(nil) end, -- ends the attempt after one failure
					unsubscribe = function() end,
				}
			end,
		}
		local svc = {
			custom_apns = {
				{ carrier = 'Test', mcc = '001', mnc = '01', apn = 'private', user = 'me', password = 's3cret' },
			},
			obs_log = function(_, _, payload)
				if type(payload) == 'table' then
					for _, v in pairs(payload) do logged[#logged + 1] = tostring(v) end
				else
					logged[#logged + 1] = tostring(payload)
				end
			end,
		}
		local modem = setmetatable({ cap = cap, svc = svc, cfg = {}, name = 'primary' }, gsm._test.GsmModem)

		local _, connect_err = modem:_apn_connect()

		local all = table.concat(logged, '\n')
		ok(all:find('apn=private', 1, true), 'expected the attempt to be logged')
		ok(all:find('failed for modem', 1, true), 'expected the error to be logged')
		ok(not all:find('s3cret', 1, true), 'password in logs: ' .. all)
		ok(not tostring(connect_err):find('s3cret', 1, true), 'password in the returned error')
	end)
end

return tests
