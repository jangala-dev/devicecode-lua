-- tests/unit/gsm/test_apn_legacy_import.lua

local fibers = require 'fibers'
local op = require 'fibers.op'
local cjson = require 'cjson.safe'
local runfibers = require 'tests.support.run_fibers'
local store_mod = require 'services.gsm.apn_store_control_store'
local import = require 'services.gsm.apn_legacy_import'

local tests = {}

local KEY = 'custom-apns-v1'

local function fake_conn(initial)
	local conn = { data = initial or {}, puts = 0, fail_get = nil }
	function conn:call_op(topic, payload)
		local method = topic[5]
		if method == 'get' then
			if self.fail_get then return op.always({ ok = false, reason = self.fail_get }, nil) end
			if self.data[payload.key] == nil then return op.always({ ok = false, reason = 'not found' }, nil) end
			return op.always({ ok = true, reason = self.data[payload.key] }, nil)
		elseif method == 'put' then
			self.puts = self.puts + 1
			self.data[payload.key] = payload.data
			return op.always({ ok = true, reason = nil }, nil)
		end
		return op.always({ ok = false, reason = 'bad_method' }, nil)
	end
	return conn
end

local function rec(apn, extra)
	local out = { carrier = 'Carrier', mcc = '234', mnc = '10', apn = apn }
	for k, v in pairs(extra or {}) do out[k] = v end
	return out
end

local function user_cfg(apns)
	return cjson.encode({ default = { apns = apns } }) .. '\n\n'
end

local function reading(reply, err)
	return function() return op.always(reply, err) end
end

local function run(conn, read_op)
	return fibers.perform(import.run_op(store_mod.new(conn), read_op))
end

local function run_sources(conn, remote_body, user_body)
	local reads = {}
	local bodies = { ['remote.cfg'] = remote_body, ['user.cfg'] = user_body }
	local result, err = fibers.perform(import.run_op(store_mod.new(conn), function(filename)
		reads[#reads + 1] = filename
		return op.always({ ok = true, reason = assert(bodies[filename]) })
	end, import.FILENAMES))
	return result, err, reads
end

function tests.test_user_apn_subsection_replaces_remote_list()
	runfibers.run(function()
		local conn = fake_conn()
		local result, err = run_sources(conn, user_cfg({ rec('old-remote') }), user_cfg({ rec('user-choice') }))
		assert(result and result.status == 'imported', tostring(err))
		local records = cjson.decode(assert(conn.data[KEY])).records
		assert(#records == 1, 'user APNs must replace remote APNs; saved ' .. tostring(#records))
		assert(records[1].apn == 'user-choice')
	end)
end

function tests.test_explicit_empty_user_apn_subsection_clears_remote_list()
	runfibers.run(function()
		local conn = fake_conn()
		local result, err = run_sources(conn, user_cfg({ rec('old-remote') }), '{"default":{"apns":[]}}')
		assert(result, tostring(err))
		assert(conn.puts == 0, 'explicit user empty list must not persist remote APNs')
		assert(result.status == 'no_source', result.status)
	end)
end

function tests.test_absent_user_apn_subsection_preserves_remote_list()
	runfibers.run(function()
		local conn = fake_conn()
		local result, err, reads = run_sources(conn, user_cfg({ rec('remote') }), '{"default":{"other":true}}')
		assert(result and result.status == 'imported', tostring(err))
		local records = cjson.decode(assert(conn.data[KEY])).records
		assert(#records == 1 and records[1].apn == 'remote')
		assert(#reads == 2 and reads[2] == 'user.cfg')
	end)
end

function tests.test_malformed_remote_source_does_not_hide_valid_user_apns()
	runfibers.run(function()
		local conn = fake_conn()
		local result, err, reads = run_sources(conn, '{', user_cfg({ rec('user-choice') }))
		assert(#reads == 2 and reads[2] == 'user.cfg', 'malformed remote source prevented reading user.cfg')
		assert(result and result.status == 'imported', tostring(err or (result and result.status)))
		local records = cjson.decode(assert(conn.data[KEY])).records
		assert(#records == 1 and records[1].apn == 'user-choice')
	end)
end

function tests.test_malformed_user_source_preserves_remote_apns()
	runfibers.run(function()
		local conn = fake_conn()
		local result, err = run_sources(conn, user_cfg({ rec('remote') }), '{')
		assert(result and result.status == 'imported', tostring(err))
		assert(result.imported == 1 and conn.puts == 1)
		assert(cjson.decode(assert(conn.data[KEY])).records[1].apn == 'remote')
	end)
end

function tests.test_missing_source_does_not_hide_the_other_source()
	for _, missing_filename in ipairs(import.FILENAMES) do
		runfibers.run(function()
			local conn, reads = fake_conn(), {}
			local result, err = fibers.perform(import.run_op(store_mod.new(conn), function(filename)
				reads[#reads + 1] = filename
				if filename == missing_filename then
					return op.always({ ok = false, reason = 'No such file or directory' })
				end
				return op.always({ ok = true, reason = user_cfg({ rec(filename) }) })
			end, import.FILENAMES))
			assert(result and result.status == 'imported', tostring(err))
			assert(result.imported == 1 and conn.puts == 1 and #reads == 2)
			local expected = missing_filename == 'remote.cfg' and 'user.cfg' or 'remote.cfg'
			assert(cjson.decode(assert(conn.data[KEY])).records[1].apn == expected)
		end)
	end
end

function tests.test_invalid_user_records_still_replace_remote_subsection()
	runfibers.run(function()
		local conn = fake_conn()
		local result, err = run_sources(conn, user_cfg({ rec('remote') }), user_cfg({ { apn = 'invalid' } }))
		assert(result and result.status == 'no_source', tostring(err))
		assert(result.skipped == 1 and conn.puts == 0 and conn.data[KEY] == nil)
	end)
end

function tests.test_replacement_preserves_normalized_user_order_and_counts()
	runfibers.run(function()
		local conn = fake_conn()
		local remote = user_cfg({ rec('old'), rec('old'), { apn = 'invalid' } })
		local user = user_cfg({
			rec(' same ', { user = ' first ', password = ' one ' }),
			rec('same', { user = 'first', password = 'one' }),
			rec('same', { user = 'second', password = 'two' }),
		})
		local result, err = run_sources(conn, remote, user)
		assert(result and result.status == 'imported', tostring(err))
		assert(result.imported == 2 and result.skipped == 1, 'only the effective list contributes counts')
		local records = cjson.decode(assert(conn.data[KEY])).records
		assert(#records == 2 and records[1].apn == 'same')
		assert(records[1].user == 'first' and records[1].password == 'one')
		assert(records[2].user == 'second' and records[2].password == 'two')
	end)
end

function tests.test_malformed_source_combinations_do_not_write()
	for _, case in ipairs({
		{ remote = '{', user = '{', status = 'malformed' },
		{ remote = '{', user = '{}', status = 'no_source' },
		{ remote = '{}', user = '{', status = 'no_source' },
		{ remote = '{', user = '{"default":{"apns":[]}}', status = 'no_source' },
	}) do
		runfibers.run(function()
			local conn = fake_conn()
			local result, err, reads = run_sources(conn, case.remote, case.user)
			assert(result and result.status == case.status, tostring(err or (result and result.status)))
			assert(#reads == 2 and conn.puts == 0 and conn.data[KEY] == nil)
		end)
	end
end

function tests.test_parse_distinguishes_absent_and_explicit_empty_subsections()
	for _, body in ipairs({ '{}', '{"default":{}}', '{"addn":{"apns":[]}}' }) do
		local records, skipped, has_apns = import.parse(body)
		assert(records and #records == 0 and skipped == 0 and has_apns == false, body)
	end
	local records, skipped, has_apns = import.parse('{"default":{"apns":[]}}')
	assert(records and #records == 0 and skipped == 0 and has_apns == true)
end

function tests.test_legacy_sources_include_remote_before_user_cfg()
	local filenames = import.FILENAMES or { import.FILENAME }
	assert(filenames[1] == 'remote.cfg', 'remote.cfg must be the first legacy APN source')
	assert(filenames[2] == 'user.cfg', 'user.cfg must be merged after remote.cfg')
end

function tests.test_parse_reads_the_list_the_v09_ui_saves()
	local records, skipped = import.parse(user_cfg({ rec('one'), rec('two', { user = 'u', password = 'p' }) }))
	assert(#records == 2 and skipped == 0)
	assert(records[1].apn == 'one')
	assert(records[2].password == 'p')
end

function tests.test_parse_drops_only_the_bad_records()
	local records, skipped = import.parse(user_cfg({
		rec('good'),
		{ carrier = 'No MCC', mnc = '10', apn = 'bad' },
		rec('good'),
		'not a table',
		rec('also-good', { unknown_field = 'dropped' }),
	}))
	assert(#records == 2, 'valid records stay')
	assert(skipped == 3, 'skipped ' .. tostring(skipped))
	assert(records[2].apn == 'also-good' and records[2].unknown_field == nil)
end

-- v0.9 connected custom APNs without looking at MVNO fields, and its UI took free text
-- there, so they mustn't cost a working record or change how it ranks.
function tests.test_parse_keeps_records_v09_would_have_used()
	local records, skipped = import.parse(user_cfg({
		rec('none', { mvno_type = 'none' }),
		rec('half', { mvno_type = 'gid' }),
		rec('valid', { mvno_type = 'spn', mvno_match_data = 'x' }),
		rec('null-field', { proxy = cjson.null, mmsc = {} }),
	}))
	assert(#records == 4 and skipped == 0, 'kept ' .. tostring(#records))
	for _, item in ipairs(records) do
		assert(item.mvno_type == nil and item.mvno_match_data == nil, item.apn)
		assert(item.proxy == nil and item.mmsc == nil, item.apn)
	end
end

function tests.test_parse_preserves_credential_variants_in_order()
	local records, skipped = import.parse(user_cfg({
		rec('same', { user = 'first', password = 'one' }),
		rec('same', { user = 'second', password = 'two' }),
	}))
	assert(#records == 2, 'credential variants imported: ' .. tostring(#records))
	assert(skipped == 0, 'skipped ' .. tostring(skipped))
	assert(records[1].user == 'first' and records[2].user == 'second')
end

function tests.test_parse_uses_apn_as_fallback_carrier_for_legacy_records()
	local records, skipped = import.parse(user_cfg({
		{ mcc = '234', mnc = '10', apn = 'carrierless.net', user = 'legacy' },
	}))
	assert(#records == 1, 'carrier-less legacy APN was discarded')
	assert(skipped == 0, 'skipped ' .. tostring(skipped))
	assert(records[1].carrier == 'carrierless.net', tostring(records[1].carrier))
end

function tests.test_parse_treats_no_apns_as_an_empty_list()
	for _, body in ipairs({ '{}', '{"default":{}}', '{"addn":{"apns":[]}}', '{"default":{"apns":[]}}' }) do
		local records, skipped = import.parse(body)
		assert(records and #records == 0 and skipped == 0, body)
	end
end

function tests.test_parse_rejects_malformed_files_without_echoing_them()
	for _, body in ipairs({
		'not json {"password":"secret"}', '[1,2', '"text"', '{"default":3}', '{"default":{"apns":3}}',
	}) do
		local records, err = import.parse(body)
		assert(records == nil, body)
		assert(err == 'malformed', tostring(err))
	end
end

function tests.test_imports_once_when_the_store_has_no_key()
	runfibers.run(function()
		local conn = fake_conn()
		local result = assert(run(conn, reading({ ok = true, reason = user_cfg({ rec('one'), { apn = 'bad' } }) })))
		assert(result.status == 'imported', result.status)
		assert(result.imported == 1 and result.skipped == 1)
		assert(result.records[1].apn == 'one')
		local stored = cjson.decode(conn.data[KEY])
		assert(stored.records[1].apn == 'one')

		-- A later start finds the key and leaves it alone.
		local again = assert(run(conn, function() error('must not read user.cfg again') end))
		assert(again.status == 'exists' and conn.puts == 1)
	end)
end

function tests.test_an_emptied_list_is_not_imported_again()
	runfibers.run(function()
		local conn = fake_conn({ [KEY] = cjson.encode({ records = {} }) })
		local result = assert(run(conn, function() error('must not read user.cfg') end))
		assert(result.status == 'exists')
		assert(conn.puts == 0)
	end)
end

function tests.test_missing_file_or_no_apns_writes_nothing()
	runfibers.run(function()
		local conn = fake_conn()
		local missing = { ok = false, reason = 'failed to open file /data/configs/user.cfg: No such file or directory' }
		assert(assert(run(conn, reading(missing))).status == 'no_source')
		assert(assert(run(conn, reading({ ok = true, reason = '{}' }))).status == 'no_source')
		assert(conn.puts == 0 and conn.data[KEY] == nil)
	end)
end

function tests.test_all_records_invalid_writes_nothing()
	runfibers.run(function()
		local conn = fake_conn()
		local result = assert(run(conn, reading({ ok = true, reason = user_cfg({ { apn = 'bad' } }) })))
		assert(result.status == 'no_source' and result.skipped == 1)
		assert(conn.puts == 0)
	end)
end

function tests.test_malformed_file_is_final_and_writes_nothing()
	runfibers.run(function()
		local conn = fake_conn()
		local result = assert(run(conn, reading({ ok = true, reason = 'not json' })))
		assert(result.status == 'malformed')
		assert(conn.puts == 0)
	end)
end

function tests.test_read_and_store_failures_are_retryable()
	runfibers.run(function()
		local conn = fake_conn()
		local a, aerr = run(conn, reading({ ok = false, reason = 'read busy' }))
		assert(a == nil and aerr == 'read busy', tostring(aerr))
		local b, berr = run(conn, reading(nil, 'no_route'))
		assert(b == nil and berr == 'no_route', tostring(berr))
		conn.fail_get = 'store busy'
		local c, cerr = run(conn, function() error('must not read when the store is failing') end)
		assert(c == nil and cerr == 'store busy', tostring(cerr))
		assert(conn.puts == 0)
	end)
end

return tests
