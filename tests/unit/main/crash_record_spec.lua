-- tests/unit/main/crash_record_spec.lua
--
-- The crash record carries the reason for a devicecode exit across the restart,
-- so the next process can send it to the cloud.

local crash_record = require 'devicecode.crash_record'

local T = {}

local function temp_path()
	local path = os.tmpname()
	os.remove(path)
	return path
end

local function new_store(path, overrides)
	local opts = {
		path = path,
		boot_id = 'boot-1',
		monotonic = function() return 1000 end,
		read_system_log = function() return '' end,
	}
	for k, v in pairs(overrides or {}) do opts[k] = v end
	return crash_record.new(opts)
end

-- A process that has started and then failed, as procd would run it.
local function failed_run(path, reason, overrides)
	local store = new_store(path, overrides)
	store:begin_run()
	store:note_log('net', 'warn', { what = 'apply_failed', err = 'timeout' })
	store:record_failure({ service = 'net', status = 'failed', primary = reason or 'net.lua:1: boom' })
	return store
end

local function restarted(path, overrides)
	local store = new_store(path, overrides)
	store:begin_run()
	return store
end

function T.a_service_failure_is_there_for_the_next_process()
	local path = temp_path()
	failed_run(path, 'gsm.lua:1685: attempt to index field scope')

	local rec = restarted(path):next_pending(2000)
	assert(rec, 'expected a pending record')
	assert(rec.kind == 'service_failed', 'kind: ' .. tostring(rec.kind))
	assert(rec.service == 'net', 'service: ' .. tostring(rec.service))
	assert(rec.reason:match('attempt to index field scope'), 'reason: ' .. tostring(rec.reason))
	assert(rec.mono == 1000, 'mono: ' .. tostring(rec.mono))
	assert(rec.log:match('apply_failed'), 'log: ' .. tostring(rec.log))
	os.remove(path)
end

function T.nothing_is_pending_after_a_clean_start()
	local path = temp_path()
	assert(restarted(path):next_pending(2000) == nil, 'expected nothing pending')
	os.remove(path)
end

function T.a_killed_process_is_reported_as_unknown_exit_with_system_log()
	local path = temp_path()
	new_store(path):begin_run() -- never records anything: killed

	local store = restarted(path, {
		read_system_log = function() return 'kern.err kernel: Out of memory: Killed process 1234' end,
	})
	local rec = store:next_pending(2000)
	assert(rec, 'expected a pending record')
	assert(rec.kind == 'unknown_exit', 'kind: ' .. tostring(rec.kind))
	assert(rec.log:match('Out of memory'), 'log: ' .. tostring(rec.log))
	os.remove(path)
end

function T.a_recorded_failure_is_not_also_reported_as_unknown_exit()
	local path = temp_path()
	failed_run(path)
	local store = restarted(path)
	local rec = store:next_pending(2000)
	assert(rec.kind == 'service_failed', 'kind: ' .. tostring(rec.kind))
	store:mark_sent(rec.seq, 2000)
	assert(store:next_pending(2000) == nil, 'expected one record only')
	os.remove(path)
end

function T.a_deliberate_restart_shows_as_a_signal_with_no_log()
	local path = temp_path()
	local store = new_store(path)
	store:begin_run()
	store:note_log('net', 'warn', { what = 'noise' })
	store:record_signal('signal:TERM')

	local rec = restarted(path):next_pending(2000)
	assert(rec.kind == 'signal', 'kind: ' .. tostring(rec.kind))
	assert(rec.reason == 'signal:TERM', 'reason: ' .. tostring(rec.reason))
	assert(rec.log == nil, 'a deliberate restart should send no log')
	os.remove(path)
end

function T.an_error_reaching_the_top_is_recorded_once()
	local path = temp_path()
	local store = new_store(path)
	store:begin_run()
	store:record_failure({ service = 'net', status = 'failed', primary = 'first' })
	store:record_error('service_not_ok:net')

	local next_store = restarted(path)
	local rec = next_store:next_pending(2000)
	assert(rec.reason == 'first', 'first record should win, got ' .. tostring(rec.reason))
	next_store:mark_sent(rec.seq, 2000)
	assert(next_store:next_pending(2000) == nil, 'expected one record for one run')
	os.remove(path)
end

function T.an_error_with_no_earlier_record_is_recorded()
	local path = temp_path()
	local store = new_store(path)
	store:begin_run()
	store:record_error('boot failed for service net: load_failed')

	local rec = restarted(path):next_pending(2000)
	assert(rec.kind == 'main_error', 'kind: ' .. tostring(rec.kind))
	assert(rec.reason:match('load_failed'), 'reason: ' .. tostring(rec.reason))
	os.remove(path)
end

function T.records_stay_within_the_size_limits()
	local path = temp_path()
	local store = new_store(path)
	store:begin_run()
	for i = 1, 200 do
		store:note_log('svc', 'error', { what = 'noise', n = i, detail = string.rep('x', 400) })
	end
	store:record_failure({ service = 'net', status = 'failed', primary = string.rep('y', 5000) })

	local rec = restarted(path):next_pending(2000)
	assert(#rec.reason <= crash_record.MAX_REASON, 'reason length ' .. #rec.reason)
	assert(#rec.log <= crash_record.MAX_LOG, 'log length ' .. #rec.log)
	os.remove(path)
end

function T.the_newest_log_lines_are_the_ones_kept()
	local path = temp_path()
	local store = new_store(path)
	store:begin_run()
	for i = 1, 50 do store:note_log('svc', 'warn', { what = 'line' .. i }) end
	store:record_failure({ service = 'net', status = 'failed', primary = 'x' })

	local rec = restarted(path):next_pending(2000)
	assert(rec.log:match('line50'), 'expected the newest line')
	assert(not rec.log:match('line30[^%d]'), 'expected old lines to have gone')
	os.remove(path)
end

function T.debug_logs_do_not_fill_the_buffer()
	local path = temp_path()
	local store = new_store(path)
	store:begin_run()
	store:note_log('svc', 'warn', { what = 'useful' })
	for _ = 1, 100 do
		store:note_log('svc', 'debug', { what = 'chatter' })
		store:note_log('svc', 'trace', { what = 'chatter' })
	end
	store:record_failure({ service = 'net', status = 'failed', primary = 'x' })

	local rec = restarted(path):next_pending(2000)
	assert(rec.log:match('useful'), 'expected the warning to survive')
	assert(not rec.log:match('chatter'), 'expected no debug lines')
	os.remove(path)
end

function T.secrets_and_identifiers_are_removed()
	local path = temp_path()
	local store = new_store(path)
	store:begin_run()
	store:note_log('gsm', 'error', {
		what = 'x', password = 'hunter2', thing_key = 'abc123', mac = 'AA:BB:CC:DD:EE:FF',
		apn_user = 'someone', psk = 'wifipass',
	})
	store:note_log('wifi', 'error', { what = 'y', message = 'client aa-bb-cc-dd-ee-ff joined with token=tok123' })
	store:note_log('http', 'error', { what = 'z', message = 'Authorization: Thing 11111111-2222-3333-4444-555555555555' })
	store:note_log('gsm', 'error', { what = 'w', message = 'iccid 8944200012345678901 imei 356938035643809' })
	store:note_log('http', 'error', { what = 'v', err = 'GET https://user:pa55@cloud.example/x failed' })
	store:record_failure({
		service = 'gsm', status = 'failed',
		primary = 'connect failed password=hunter3 for aa:bb:cc:dd:ee:00',
	})

	local rec = restarted(path):next_pending(2000)
	local text = rec.reason .. '\n' .. rec.log
	for _, secret in ipairs({
		'hunter2', 'hunter3', 'abc123', 'someone', 'wifipass', 'tok123', 'pa55',
		'11111111%-2222', '8944200012345678901', '356938035643809',
	}) do
		assert(not text:match(secret), 'leaked ' .. secret .. ' in: ' .. text)
	end
	assert(not text:lower():match('aa[:%-]bb[:%-]cc'), 'leaked a MAC address in: ' .. text)
	assert(text:match('connect failed'), 'expected the useful text to stay: ' .. text)
	os.remove(path)
end

function T.only_the_first_crashes_in_a_boot_send_full_logs()
	local path = temp_path()
	for i = 1, crash_record.FULL_LOG_CRASHES + 2 do failed_run(path, 'crash' .. i) end

	local store = restarted(path)
	local with_log, without_log = 0, 0
	local rec = store:next_pending(2000)
	local t = 2000
	while rec do
		if rec.log then with_log = with_log + 1 else without_log = without_log + 1 end
		store:mark_sent(rec.seq, t)
		t = t + crash_record.SEND_INTERVAL_S
		rec = store:next_pending(t)
	end
	assert(with_log == crash_record.FULL_LOG_CRASHES, 'records with logs: ' .. with_log)
	assert(without_log == 2, 'records without logs: ' .. without_log)
	os.remove(path)
end

function T.a_crash_loop_cannot_grow_the_file()
	local path = temp_path()
	for i = 1, 100 do failed_run(path, 'crash' .. i) end

	local store = restarted(path)
	local n, last = 0, nil
	local t = 2000
	local rec = store:next_pending(t)
	while rec do
		n = n + 1
		last = rec
		store:mark_sent(rec.seq, t)
		t = t + crash_record.SEND_INTERVAL_S
		rec = store:next_pending(t)
	end
	assert(n <= crash_record.MAX_PENDING, 'pending records: ' .. n)
	assert(last.seq == 100, 'the count should still show every crash, got ' .. tostring(last.seq))
	assert(last.reason == 'crash100', 'expected the newest reason, got ' .. tostring(last.reason))
	os.remove(path)
end

function T.sending_is_paced_once_past_the_first_crashes()
	local path = temp_path()
	for _ = 1, crash_record.FULL_LOG_CRASHES + 2 do failed_run(path) end
	local store = restarted(path)

	local t = 2000
	for _ = 1, crash_record.FULL_LOG_CRASHES do
		local rec = assert(store:next_pending(t), 'early records should send straight away')
		store:mark_sent(rec.seq, t)
	end
	local rec = assert(store:next_pending(t), 'expected the next record after the early ones')
	store:mark_sent(rec.seq, t)
	assert(store:next_pending(t) == nil, 'later records should wait')
	assert(store:next_pending(t + crash_record.SEND_INTERVAL_S), 'expected a send after the interval')
	os.remove(path)
end

function T.a_failed_send_keeps_the_record_and_retries_later()
	local path = temp_path()
	failed_run(path)
	local store = restarted(path)
	local rec = assert(store:next_pending(2000))
	store:mark_failed(2000)

	assert(store:next_pending(2000) == nil, 'should wait before retrying')
	local again = store:next_pending(2000 + crash_record.SEND_INTERVAL_S)
	assert(again and again.seq == rec.seq, 'expected the same record again')
	os.remove(path)
end

function T.a_sent_record_stays_sent_after_another_restart()
	local path = temp_path()
	failed_run(path)
	local store = restarted(path)
	local rec = assert(store:next_pending(2000))
	store:mark_sent(rec.seq, 2000)
	store:record_signal('signal:TERM')

	local after = restarted(path)
	local next_rec = after:next_pending(2000 + crash_record.SEND_INTERVAL_S)
	assert(next_rec and next_rec.kind == 'signal', 'the failure should not be sent twice')
	os.remove(path)
end

function T.a_different_boot_starts_again()
	local path = temp_path()
	failed_run(path)
	local store = restarted(path, { boot_id = 'boot-2' })
	assert(store:next_pending(2000) == nil, 'records from another boot should be dropped')
	os.remove(path)
end

function T.a_corrupt_file_does_not_stop_devicecode()
	local path = temp_path()
	local f = assert(io.open(path, 'w'))
	f:write('{not json')
	f:close()
	local store = restarted(path)
	assert(store:next_pending(2000) == nil, 'a corrupt file should count as empty')
	store:record_failure({ service = 'net', status = 'failed', primary = 'x' })
	assert(restarted(path):next_pending(2000), 'expected the store to work again')
	os.remove(path)
end

function T.an_unwritable_path_does_not_stop_devicecode()
	local store = new_store('/nonexistent-dir/devicecode-crash.json')
	store:begin_run()
	store:note_log('net', 'warn', { what = 'x' })
	store:record_failure({ service = 'net', status = 'failed', primary = 'x' })
	store:record_error('y')
	store:record_signal('z')
	assert(store:next_pending(2000) == nil or true, 'should not raise')
end

return T
