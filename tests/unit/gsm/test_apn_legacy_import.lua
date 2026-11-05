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
		assert(result.status == 'exists' and #result.records == 0)
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
