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

function T.next_send_at_says_when_a_record_is_due()
	local path = temp_path()
	assert(restarted(path):next_send_at() == nil, 'expected nothing due with nothing pending')
	os.remove(path)

	failed_run(path, 'gsm.lua:1: boom')
	local store = restarted(path)
	assert(store:next_send_at() == 0, 'expected a new record to be due at once')

	store:mark_failed(2000)
	assert(store:next_send_at() == 2000 + crash_record.RETRY_MIN_S,
		'expected the retry deadline, got ' .. tostring(store:next_send_at()))

	store:mark_sent(store:next_pending(math.huge).seq, 2100)
	assert(store:next_send_at() == nil, 'expected nothing due once sent')
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

function T.secrets_in_json_quoted_and_nested_text_are_removed()
	local path = temp_path()
	local store = new_store(path)
	store:begin_run()
	for _, message in ipairs({
		'{"password":"hunter2","user_salt":"salty"}',
		'password="two secret words" next=x',
		"token='single quoted value' next=x",
		[[{"secret":"esc\"aped value","next":"x"}]],
		'{"credentials":{"value":"nested1"}}',
		[[{"err":"password=\"esc secret\""}]],
		[[{\"psk\":\"encoded json\"}]],
		'Authorization: Bearer abc.def.ghi',
		'run --password flagvalue now',
	}) do
		store:note_log('http', 'error', { what = 'x', message = message })
	end
	store:note_log('http', 'error', { what = 'ok_line', detail = 'stays' })
	store:record_failure({ service = 'x', status = 'failed', primary = 'connect failed {"psk":"wifi pass phrase"}' })

	local rec = restarted(path):next_pending(2000)
	local text = rec.reason .. '\n' .. rec.log
	for _, secret in ipairs({
		'hunter2', 'salty', 'two secret', 'secret words', 'single quoted', 'esc', 'aped value', 'nested1',
		'encoded json', 'abc%.def', 'flagvalue', 'wifi pass', 'pass phrase',
	}) do
		assert(not text:match(secret), 'leaked ' .. secret .. ' in: ' .. text)
	end
	assert(text:find('ok_line detail=stays', 1, true), 'lost a harmless line from: ' .. text)
	assert(text:find('connect failed', 1, true), 'lost the text before the secret from: ' .. text)
	os.remove(path)
end

function T.secrets_on_continuation_lines_are_removed()
	local path = temp_path()
	local store = new_store(path)
	store:begin_run()
	store:note_log('x', 'error', { what = 'a', message = 'password="first\ncontinuation1\nlast"' })
	store:note_log('x', 'error', { what = 'b', message = '{\n  "credentials": {\n    "value": "continuation2"\n  }\n}' })
	store:record_failure({ service = 'x', status = 'failed', primary = 'psk: "one\ncontinuation3"' })

	local rec = restarted(path):next_pending(2000)
	local text = rec.reason .. '\n' .. rec.log
	for _, secret in ipairs({ 'continuation1', 'continuation2', 'continuation3', 'first', 'last' }) do
		assert(not text:match(secret), 'leaked ' .. secret .. ' in: ' .. text)
	end
	os.remove(path)
end

function T.a_credential_cut_off_by_the_limits_stays_hidden()
	local path = temp_path()
	local store = new_store(path)
	store:begin_run()
	local long = string.rep('p', 3000)
	store:note_log('x', 'error', { what = 'a', message = 'GET https://alice:' .. long .. '@host/x' })
	store:record_failure({ service = 'x', status = 'failed', primary = 'GET https://bob:' .. long .. '@host/x' })

	local rec = restarted(path):next_pending(2000)
	local text = rec.reason .. '\n' .. rec.log
	for _, secret in ipairs({ 'alice', 'bob', 'pppp' }) do
		assert(not text:match(secret), 'leaked ' .. secret .. ' in: ' .. text)
	end
	os.remove(path)
end

function T.limits_hold_after_redaction_lengthens_the_text()
	local path = temp_path()
	local store = new_store(path)
	store:begin_run()
	local nearly = string.rep('x', crash_record.MAX_REASON - 10) .. ' password='
	store:note_log('x', 'error', { what = 'a', message = nearly })
	store:record_failure({ service = 'x', status = 'failed', primary = nearly })

	local rec = restarted(path):next_pending(2000)
	assert(#rec.reason <= crash_record.MAX_REASON, 'reason length ' .. #rec.reason)
	for line in rec.log:gmatch('[^\n]+') do
		assert(#line <= crash_record.MAX_LINE, 'line length ' .. #line)
	end
	os.remove(path)
end

function T.only_kernel_and_procd_lines_come_from_the_system_log()
	local path = temp_path()
	new_store(path):begin_run()
	local store = restarted(path, {
		read_system_log = function()
			return table.concat({
				'daemon.info someapp: connected with secret hunter2 for AA:BB:CC:DD:EE:FF',
				'daemon.notice other: pretty printed',
				'  continuation line of something',
				'daemon.info procd: Instance devicecode::instance1 s in a crash loop',
				'kern.err kernel: Out of memory: Killed process 1234 (luajit)',
				'',
			}, '\n')
		end,
	})
	local rec = store:next_pending(2000)
	assert(rec.log:match('Out of memory'), 'log: ' .. tostring(rec.log))
	assert(rec.log:match('procd'), 'log: ' .. tostring(rec.log))
	assert(not rec.log:match('hunter2'), 'log: ' .. tostring(rec.log))
	assert(not rec.log:match('continuation'), 'log: ' .. tostring(rec.log))
	os.remove(path)
end

function T.system_log_lines_are_chosen_by_their_source_not_their_contents()
	local path = temp_path()
	new_store(path):begin_run()
	local store = restarted(path, {
		read_system_log = function()
			return table.concat({
				'Thu Nov  5 10:00:00 2026 daemon.info dnsmasq-dhcp[123]: DHCPACK(br) 10.0.0.2 customer-procd-laptop',
				'Thu Nov  5 10:00:01 2026 daemon.info someapp[9]: saw kern.err in client-laptop-name',
				'Thu Nov  5 10:00:02 2026 daemon.info hostapd: procd: client-phone-name joined',
				'Thu Nov  5 10:00:03 2026 kern.err kernel: [ 12.3] Out of memory: Killed process 1234 (luajit)',
				'Thu Nov  5 10:00:04 2026 daemon.info procd: Instance devicecode::instance1 s in a crash loop',
				'',
			}, '\n')
		end,
	})
	local rec = store:next_pending(2000)
	assert(rec.log:match('Out of memory'), 'log: ' .. tostring(rec.log))
	assert(rec.log:match('crash loop'), 'log: ' .. tostring(rec.log))
	for _, name in ipairs({ 'customer', 'laptop', 'phone' }) do
		assert(not rec.log:match(name), 'leaked ' .. name .. ' in: ' .. rec.log)
	end
	os.remove(path)
end

function T.a_very_long_system_log_line_is_not_kept_part_way_through()
	local path = temp_path()
	new_store(path):begin_run()
	local store = restarted(path, {
		read_system_log = function()
			return 'kern.err kernel: password=' .. string.rep('s', 20000) .. '\n'
		end,
	})
	local rec = store:next_pending(2000)
	assert(not tostring(rec.log):match('sss'), 'leaked part of a value: ' .. tostring(rec.log):sub(1, 80))
	os.remove(path)
end

function T.ordinary_errors_are_left_readable()
	for _, line in ipairs({
		"gsm.lua:1685: attempt to index field 'scope' (a nil value)",
		'service_not_ok:net',
		"metrics.lua:149: attempt to index field 'pipelines' (a nil value)",
		'http_listener_context_event_report_failed: full',
	}) do
		assert(crash_record.redact(line) == line, 'changed: ' .. crash_record.redact(line))
	end
end

-- Redaction runs on the scheduler, so long input mustn't hold up other fibers.
function T.long_input_is_quick()
	local path = temp_path()
	local store = new_store(path)
	store:begin_run()
	for _, filler in ipairs({ 'x', 'a=', '"', '1', ':' }) do
		local t0 = os.clock()
		store:note_log('svc', 'error', { what = 'x', message = string.rep(filler, 1024 * 1024) })
		local _ = crash_record.redact(string.rep(filler, 1024 * 1024))
		local elapsed = os.clock() - t0
		assert(elapsed < 0.2, ('took %.3f s on a long run of %q'):format(elapsed, filler))
	end
	os.remove(path)
end

function T.a_signal_after_a_failure_keeps_the_failure()
	local path = temp_path()
	local store = new_store(path)
	store:begin_run()
	store:record_failure({ service = 'net', status = 'failed', primary = 'real failure' })
	store:record_signal('signal:TERM')

	local rec = restarted(path):next_pending(2000)
	assert(rec.kind == 'service_failed', 'kind: ' .. tostring(rec.kind))
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
	local again = store:next_pending(2000 + crash_record.RETRY_MIN_S)
	assert(again and again.seq == rec.seq, 'expected the same record again')
	os.remove(path)
end

-- The first send often fails because the network is still coming up, so it shouldn't
-- cost a long wait. Repeated failures back off to the full interval and stay there.
function T.failed_sends_back_off_from_a_short_wait_to_the_full_interval()
	local path = temp_path()
	failed_run(path)
	local store = restarted(path)
	local t = 2000
	local waits = {}
	for i = 1, 8 do
		store:mark_failed(t)
		local wait = 1
		while not store:next_pending(t + wait) do wait = wait + 1 end
		waits[i] = wait
		t = t + wait
	end
	assert(waits[1] == crash_record.RETRY_MIN_S, 'first wait: ' .. waits[1])
	assert(waits[2] == crash_record.RETRY_MIN_S * 2, 'second wait: ' .. waits[2])
	assert(waits[8] == crash_record.SEND_INTERVAL_S, 'last wait: ' .. waits[8])
	os.remove(path)
end

function T.a_success_resets_the_backoff()
	local path = temp_path()
	for _ = 1, 2 do failed_run(path) end
	local store = restarted(path)
	for _ = 1, 5 do store:mark_failed(2000) end
	local rec = assert(store:next_pending(2000 + crash_record.SEND_INTERVAL_S))
	store:mark_sent(rec.seq, 2000 + crash_record.SEND_INTERVAL_S)

	store:mark_failed(5000)
	assert(store:next_pending(5000 + crash_record.RETRY_MIN_S), 'expected the short wait again')
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

-- Valid JSON that this module didn't write, such as a hand edit or a damaged file.
function T.records_of_the_wrong_shape_are_dropped()
	local path = temp_path()
	local f = assert(io.open(path, 'w'))
	f:write('{"boot_id":"boot-1","seq":"x","crashes":null,"next_send":"soon","failures":{},'
		.. '"pending":[true,"x",{"seq":"2","mono":5},{"seq":3},{"seq":4,"mono":1e999},'
		.. '{"seq":5,"mono":900,"kind":"service_failed","reason":7,"log":"tail"}]}')
	f:close()

	local store = restarted(path)
	local rec = store:next_pending(2000)
	assert(rec, 'expected the one good record')
	assert(rec.seq == 5 and rec.mono == 900, 'seq ' .. tostring(rec.seq) .. ' mono ' .. tostring(rec.mono))
	assert(rec.kind == 'service_failed', 'kind: ' .. tostring(rec.kind))
	assert(rec.reason == nil, 'a reason that is not text should be dropped')
	assert(rec.log == 'tail', 'log: ' .. tostring(rec.log))
	assert(store:next_send_at() == 0, 'expected it to be due now')

	store:mark_failed(2000)
	assert(store:next_send_at() == 2000 + crash_record.RETRY_MIN_S, 'failures should count from zero')
	store:mark_sent(5, 2100)
	assert(store:next_send_at() == nil, 'expected nothing pending')

	store:record_failure({ service = 'net', status = 'failed', primary = 'x' })
	assert(restarted(path):next_pending(math.huge).seq == 6, 'new records should follow the kept ones')
	os.remove(path)
end

-- Numbers that are finite but out of range would break the send or the numbering.
function T.records_with_impossible_numbers_are_dropped()
	local path = temp_path()
	local f = assert(io.open(path, 'w'))
	f:write('{"boot_id":"boot-1","seq":100000000000000,"crashes":1,"next_send":0,'
		.. '"pending":[{"seq":1,"mono":1e308},{"seq":-1,"mono":5},{"seq":2.5,"mono":5},'
		.. '{"seq":1e300,"mono":5},{"seq":3,"mono":-5},{"seq":4,"mono":900}]}')
	f:close()

	local store = restarted(path)
	local rec = store:next_pending(2000)
	assert(rec and rec.seq == 4 and rec.mono == 900, 'expected only the good record, got seq ' .. tostring(rec and rec.seq))
	store:mark_sent(4, 2100)
	assert(store:next_pending(math.huge) == nil, 'expected nothing else pending')

	for i = 1, 3 do
		local run = restarted(path)
		run:record_failure({ service = 'net', status = 'failed', primary = 'x' })
		local got = restarted(path):next_pending(math.huge)
		assert(got and got.seq == 4 + i, 'expected seq ' .. (4 + i) .. ', got ' .. tostring(got and got.seq))
		restarted(path):mark_sent(got.seq, 2100)
	end
	os.remove(path)
end

-- Only a damaged file gets near the limit, so starting again is fine.
function T.numbering_starts_again_at_the_limit()
	local path = temp_path()
	local f = assert(io.open(path, 'w'))
	f:write('{"boot_id":"boot-1","seq":2147483647,"crashes":1,"next_send":0,'
		.. '"pending":[{"seq":2147483647,"mono":5}]}')
	f:close()
	for i = 1, 2 do
		restarted(path):record_failure({ service = 'net', status = 'failed', primary = 'x' })
		local got = restarted(path):next_pending(math.huge)
		assert(got and got.seq == i, 'expected seq ' .. i .. ', got ' .. tostring(got and got.seq))
		restarted(path):mark_sent(got.seq, 2100)
	end
	os.remove(path)
end

function T.pending_that_is_not_a_list_counts_as_empty()
	local path = temp_path()
	local f = assert(io.open(path, 'w'))
	f:write('{"boot_id":"boot-1","seq":1,"crashes":1,"next_send":0,"pending":{"a":{"seq":1,"mono":5}}}')
	f:close()
	assert(restarted(path):next_pending(2000) == nil, 'expected nothing pending')
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
