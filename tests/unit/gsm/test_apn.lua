local apn = require 'services.gsm.apn'
local fibers = require 'fibers'
local op = require 'fibers.op'
local gsm = require 'services.gsm'
local binser = require 'shared.binser'

local tests = {}
local function fail(msg) error(msg or 'assertion failed', 2) end
local function eq(a,b,msg) if a ~= b then fail(msg or ('expected '..tostring(b)..', got '..tostring(a))) end end
local function ok(v,msg) if not v then fail(msg or 'expected truthy') end end

local function with_apn_db(db, fn)
	local original_read = binser.r
	binser.r = function(path)
		eq(path, 'etc/apns')
		return { db }
	end
	local success, err = xpcall(fn, debug.traceback)
	binser.r = original_read
	if not success then error(err, 0) end
end

local function mvno_apn_db()
	return {
		['234'] = {
			['10'] = {
				o2 = { carrier='O2', apn='mobile.o2.co.uk' },
				giffgaff = {
					carrier='giffgaff', apn='giffgaff.com',
					mvno_type='spn', mvno_match_data='giffgaff',
				},
			},
		},
	}
end

local function rankings_by_name(rankings)
	local out = {}
	for _, ranking in ipairs(rankings) do
		out[ranking.name] = ranking.rank
	end
	return out
end

function tests.test_custom_apn_is_ranked_before_default()
	local ranked, rankings = apn.get_ranked_apns('234', '10', '234100000000000', nil, nil, {
		{ carrier='Custom', mcc='234', mnc='10', apn='custom.net' },
	})
	ok(rankings[1])
	eq(rankings[1].name, 'custom-1')
	eq(ranked['custom-1'].apn, 'custom.net')
end

function tests.test_selection_filters_custom_apns_and_normalises_mnc()
	with_apn_db({
		['234'] = {
			['01'] = {
				builtin = { carrier='Built in', apn='builtin.net' },
			},
		},
	}, function()
		local ranked, rankings = apn.get_ranked_apns('234', '1', '234010000000000', nil, nil, {
			{ carrier='Match', mcc='234', mnc='1', apn='custom.net' },
			{ carrier='Wrong MCC', mcc='235', mnc='1', apn='wrong-mcc.net' },
			{ carrier='Wrong MNC', mcc='234', mnc='2', apn='wrong-mnc.net' },
			{ carrier='Missing MCC', mnc='1', apn='missing-mcc.net' },
		})
		local ranks = rankings_by_name(rankings)
		eq(ranked['custom-1'].apn, 'custom.net')
		eq(ranked['custom-2'], nil)
		eq(ranked['custom-3'], nil)
		eq(ranked['custom-4'], nil)
		eq(ranked['builtin-builtin'].apn, 'builtin.net')
		eq(ranks['custom-1'], 1)
		eq(ranks['builtin-builtin'], 3)
	end)
end

function tests.test_selection_orders_custom_mvno_plain_default_and_mismatch()
	with_apn_db({
		['234'] = {
			['10'] = {
				plain = { carrier='O2', apn='o2.net' },
				matched = {
					carrier='giffgaff', apn='giffgaff.com',
					mvno_type='spn', mvno_match_data='giffgaff',
				},
				mismatched = {
					carrier='Other MVNO', apn='other.net',
					mvno_type='spn', mvno_match_data='other',
				},
			},
		},
	}, function()
		local _, rankings = apn.get_ranked_apns('234', '10', '234100000000000', 'giffgaff', nil, {
			{ carrier='Custom', mcc='234', mnc='10', apn='custom.net' },
		})
		eq(rankings[1].name, 'custom-1')
		eq(rankings[1].rank, 1)
		eq(rankings[2].name, 'builtin-matched')
		eq(rankings[2].rank, 2)
		eq(rankings[3].name, 'builtin-plain')
		eq(rankings[3].rank, 3)
		eq(rankings[4].name, 'default')
		eq(rankings[4].rank, 4)
		eq(rankings[5].name, 'builtin-mismatched')
		ok(rankings[5].rank <= 4, 'legacy MVNO fallback must remain within the default cutoff')
	end)
end

function tests.test_selection_supports_spn_gid_and_imsi_mvno_matches()
	with_apn_db({
		['234'] = {
			['10'] = {
				spn = { apn='spn.net', mvno_type='spn', mvno_match_data='giffgaff' },
				gid = { apn='gid.net', mvno_type='gid', mvno_match_data='AB' },
				imsi = { apn='imsi.net', mvno_type='imsi', mvno_match_data='2341099' },
			},
		},
	}, function()
		local _, rankings = apn.get_ranked_apns(
			'234', '10', '234109900000000', 'giffgaff', 'ABCD')
		local ranks = rankings_by_name(rankings)
		eq(ranks['builtin-spn'], 2)
		eq(ranks['builtin-gid'], 2)
		eq(ranks['builtin-imsi'], 2)
	end)
end

function tests.test_selection_ranks_mvnos_as_mismatches_when_identifiers_are_missing()
	with_apn_db({
		['234'] = {
			['10'] = {
				spn = { apn='spn.net', mvno_type='spn', mvno_match_data='giffgaff' },
				gid = { apn='gid.net', mvno_type='gid', mvno_match_data='AB' },
				imsi = { apn='imsi.net', mvno_type='imsi', mvno_match_data='2341099' },
			},
		},
	}, function()
		local _, rankings = apn.get_ranked_apns('234', '10', nil, nil, nil)
		local ranks = rankings_by_name(rankings)
		eq(ranks.default, 4)
		ok(ranks['builtin-spn'] <= 4, 'SPN fallback must remain reachable')
		ok(ranks['builtin-gid'] <= 4, 'GID fallback must remain reachable')
		ok(ranks['builtin-imsi'] <= 4, 'IMSI fallback must remain reachable')
	end)
end

function tests.test_selection_attempts_matching_custom_record_even_when_mvno_metadata_does_not_match()
	with_apn_db({}, function()
		local _, rankings = apn.get_ranked_apns('234', '10', '234100000000000', 'giffgaff', nil, {
			{
				carrier='Manual APN', mcc='234', mnc='10', apn='manual.net',
				mvno_type='spn', mvno_match_data='different-provider',
			},
		})
		eq(rankings[1].name, 'custom-1', 'legacy custom APNs are attempted before ranked database APNs')
		ok(rankings[1].rank <= 4, 'matching MCC/MNC custom APN must remain within the cutoff')
	end)
end

function tests.test_selection_preserves_custom_record_insertion_order_after_nine_entries()
	with_apn_db({}, function()
		local custom = {}
		for i = 1, 12 do
			custom[i] = {
				carrier='Custom ' .. tostring(i),
				mcc='234',
				mnc='10',
				apn='custom-' .. tostring(i) .. '.net',
			}
		end
		local _, rankings = apn.get_ranked_apns('234', '10', '234100000000000', nil, nil, custom)
		for i = 1, 12 do
			eq(rankings[i].name, 'custom-' .. tostring(i), 'custom APN order changed at index ' .. tostring(i))
		end
	end)
end

function tests.test_selection_falls_back_to_default_when_database_has_no_match()
	with_apn_db({}, function()
		local ranked, rankings = apn.get_ranked_apns('999', '99', '999990000000000', nil, nil)
		eq(#rankings, 1)
		eq(rankings[1].name, 'default')
		eq(rankings[1].rank, 4)
		eq(ranked.default.apn, 'internet')
	end)
end

function tests.test_spn_matched_mvno_apn_gets_match_rank()
	with_apn_db(mvno_apn_db(), function()
		local ranked, rankings = apn.get_ranked_apns(
			'234', '10', '234100000000000', 'giffgaff', nil)
		eq(rankings[1].name, 'builtin-giffgaff')
		eq(rankings[1].rank, 2)
		eq(ranked[rankings[1].name].apn, 'giffgaff.com')
		eq(rankings[2].name, 'builtin-o2')
		eq(rankings[2].rank, 3)
	end)
end

function tests.test_spn_mismatched_mvno_apn_remains_within_default_cutoff()
	with_apn_db(mvno_apn_db(), function()
		local _, rankings = apn.get_ranked_apns(
			'234', '10', '234100000000000', 'other-provider', nil)
		eq(rankings[1].name, 'builtin-o2')
		eq(rankings[1].rank, 3)
		eq(rankings[2].name, 'default')
		eq(rankings[2].rank, 4)
		eq(rankings[3].name, 'builtin-giffgaff')
		ok(rankings[3].rank <= 4, 'legacy fallback APN must be attempted with cutoff 4')
	end)
end

function tests.test_apn_connect_fetches_spn_for_mvno_ranking()
	fibers.run(function()
		local values = {
			mcc = '234',
			mnc = '10',
			imsi = '234100000000000',
			spn = 'giffgaff',
			gid1 = '00',
		}
		local requested = {}
		local connect_string
		local state_sub = {
			recv = function() return { payload = 'registered' } end,
			unsubscribe = function() end,
		}
		local cap = {
			call_control_op = function(_, method, args)
				if method == 'get' then
					requested[args.field] = args.timescale == nil and true or args.timescale
					return op.always({ ok = true, reason = values[args.field] })
				end
				if method == 'connect' then
					connect_string = args.connection_string
					return op.always({ ok = true, reason = '' })
				end
				return op.always({ ok = false, reason = 'unexpected method: ' .. tostring(method) })
			end,
			get_state_sub = function() return state_sub end,
		}
		local svc = {
			custom_apns = {
				{
					carrier = 'giffgaff', mcc = '234', mnc = '10', apn = 'giffgaff.com',
					mvno_type = 'spn', mvno_match_data = 'giffgaff',
				},
			},
			obs_log = function() end,
		}
		local modem = setmetatable({
			cap = cap,
			svc = svc,
			cfg = {},
			name = 'primary',
		}, gsm._test.GsmModem)

		local active_apn, connect_err = modem:_apn_connect()

		eq(connect_err, '')
		eq(requested.spn, 0, 'expected SPN to bypass a pre-registration SIM cache')
		eq(active_apn.apn, 'giffgaff.com')
		eq(connect_string, 'apn=giffgaff.com')
	end)
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
			spn = 'MTN',
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

function tests.test_apn_connect_continues_when_spn_is_unavailable()
	fibers.run(function()
		local values = {
			mcc = '655',
			mnc = '10',
			imsi = '655100000000000',
			gid1 = '00',
		}
		local connect_string
		local spn_log
		local state_sub = {
			recv = function() return { payload = 'registered' } end,
			unsubscribe = function() end,
		}
		local cap = {
			call_control_op = function(_, method, args)
				if method == 'get' then
					if args.field == 'spn' then
						return op.always({ ok = false, reason = 'field unavailable: spn' })
					end
					return op.always({ ok = true, reason = values[args.field] })
				end
				if method == 'connect' then
					connect_string = args.connection_string
					return op.always({ ok = true, reason = '' })
				end
				return op.always({ ok = false, reason = 'unexpected method: ' .. tostring(method) })
			end,
			get_state_sub = function() return state_sub end,
		}
		local svc = {
			custom_apns = {
				{ carrier = 'MTN Data', mcc = '655', mnc = '10', apn = 'myMTN' },
			},
			obs_log = function(_, level, payload)
				if type(payload) == 'table' and payload.what == 'spn_unavailable' then
					spn_log = { level = level, payload = payload }
				end
			end,
		}
		local modem = setmetatable({ cap = cap, svc = svc, cfg = {}, name = 'primary' }, gsm._test.GsmModem)

		local active_apn, connect_err, retry_timeout = modem:_apn_connect()

		eq(connect_err, '')
		eq(retry_timeout, nil)
		eq(active_apn.apn, 'myMTN')
		eq(connect_string, 'apn=myMTN')
		ok(spn_log, 'expected unavailable SPN to be logged')
		eq(spn_log.level, 'warn')
		eq(spn_log.payload.modem, 'primary')
		eq(spn_log.payload.err, 'field unavailable: spn')
	end)
end

function tests.test_apn_connect_continues_when_imsi_is_unavailable()
	local outcome
	fibers.run(function()
		local values = { mcc = '655', mnc = '10', spn = 'MTN', gid1 = '00' }
		local connect_string
		local imsi_log
		local state_sub = {
			recv = function() return { payload = 'registered' } end,
			unsubscribe = function() end,
		}
		local cap = {
			call_control_op = function(_, method, args)
				if method == 'get' then
					if args.field == 'imsi' then
						return op.always({ ok = false, reason = 'field unavailable: imsi' })
					end
					return op.always({ ok = true, reason = values[args.field] })
				end
				if method == 'connect' then
					connect_string = args.connection_string
					return op.always({ ok = true, reason = '' })
				end
				return op.always({ ok = false, reason = 'unexpected method: ' .. tostring(method) })
			end,
			get_state_sub = function() return state_sub end,
		}
		local svc = {
			custom_apns = {
				{ carrier = 'MTN Data', mcc = '655', mnc = '10', apn = 'myMTN' },
			},
			obs_log = function(_, level, payload)
				if type(payload) == 'table' and payload.what == 'imsi_unavailable' then
					imsi_log = { level = level, payload = payload }
				end
			end,
		}
		local modem = setmetatable({ cap = cap, svc = svc, cfg = {}, name = 'primary' }, gsm._test.GsmModem)

		local active_apn, connect_err, retry_timeout = modem:_apn_connect()
		outcome = {
			active_apn = active_apn,
			connect_err = connect_err,
			retry_timeout = retry_timeout,
			connect_string = connect_string,
			imsi_log = imsi_log,
		}
	end)

	eq(outcome.connect_err, '')
	eq(outcome.retry_timeout, nil)
	eq(outcome.active_apn.apn, 'myMTN')
	eq(outcome.connect_string, 'apn=myMTN')
	ok(outcome.imsi_log, 'expected unavailable IMSI to be logged')
	eq(outcome.imsi_log.level, 'warn')
	eq(outcome.imsi_log.payload.err, 'field unavailable: imsi')
end

function tests.test_scrub_removes_the_exact_connection_string_and_password()
	local apns = require 'services.gsm.apn'
	local conn = 'apn=a,user=me,password=p.%s (x, y)'
	local err = 'mmcli --simple-connect=' .. conn .. ' failed for modem 0: bad p.%s (x, y) here'
	local out = apns.scrub_secrets(err, conn, 'p.%s (x, y)')
	assert(not out:find('p.%s', 1, true), out)
	assert(not out:find('(x, y)', 1, true), out)
	assert(out:find('failed for modem 0', 1, true), out)
	assert(apns.scrub_secrets('plain', conn, nil) == 'plain')
	assert(apns.scrub_secrets('', conn, 'p') == '')
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
				{
					carrier = 'Test', mcc = '001', mnc = '01', apn = 'private', user = 'me',
					password = 's3cret with space, and comma',
				},
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
		ok(all:find('failed for modem', 1, true), 'expected the error to be logged')
		ok(all:find('failed for modem', 1, true), 'expected the error to be logged')
		for _, part in ipairs({ 's3cret', 'with space', 'and comma' }) do
			ok(not all:find(part, 1, true), 'password in logs: ' .. all)
			ok(not tostring(connect_err):find(part, 1, true), 'password in the returned error')
		end
	end)
end

return tests
