-- tests/unit/gsm/test_apn_legacy_import_service.lua
--
-- The first-boot import through the real GSM service, on an in-process bus, with a
-- fake control store and a fake filesystem capability.

local busmod = require 'bus'
local fibers = require 'fibers'
local sleep = require 'fibers.sleep'
local cjson = require 'cjson.safe'
local runfibers = require 'tests.support.run_fibers'
local fake_store = require 'tests.support.fake_control_store'
local bus_cleanup = require 'devicecode.support.bus_cleanup'
local gsm_service = require 'services.gsm'
local gsm_topics = require 'services.gsm.topics'

local tests = {}

local KEY = 'custom-apns-v1'
local TIMEOUT = 8.0

local function rec(apn)
	return { carrier = 'Carrier', mcc = '234', mnc = '10', apn = apn }
end

local function user_cfg(apns)
	return cjson.encode({ default = { apns = apns } })
end

local function count_calls(store, method)
	local n = 0
	for _, call in ipairs(store.calls) do
		if call.method == method then n = n + 1 end
	end
	return n
end

local function wait_until(fn, what)
	for _ = 1, 700 do
		if fn() then return end
		fibers.perform(sleep.sleep_op(0.01))
	end
	error('timed out waiting for ' .. what, 2)
end

-- Starts GSM with a fake store and, unless replies is nil, a filesystem capability
-- that gives each read the next reply, repeating the last. A function reply runs first.
local function start(scope, opts)
	local bus = busmod.new()
	local store = fake_store.new({ id = 'gsm', values = opts.values })
	store:start(bus:connect({ origin_base = { kind = 'test', service = 'fake-hal' } }), { id = 'gsm', scope = scope })
	local h = { bus = bus, store = store, reads = 0 }
	if opts.replies then
		local conn = bus:connect({ origin_base = { kind = 'test', service = 'fake-fs' } })
		local ep = assert(bus_cleanup.bind(conn, { 'cap', 'fs', 'credentials', 'rpc', 'read' }, { queue_len = 8 }))
		assert(scope:spawn(function()
			while true do
				local req = fibers.perform(ep:recv_op())
				if req == nil then return end
				h.reads = h.reads + 1
				local reply = opts.replies[math.min(h.reads, #opts.replies)]
				if type(reply) == 'function' then reply = reply() end
				req:reply(reply)
			end
		end))
	end
	local cfg_conn = bus:connect({ origin_base = { kind = 'test', service = 'config' } })
	cfg_conn:retain({ 'cfg', 'gsm' }, {
		schema = 'devicecode.config.snapshot/1',
		service = 'gsm',
		rev = 1,
		data = {
			schema = 'devicecode.config/gsm/1',
			apn_store = { kind = 'control-store', id = 'gsm', key = KEY },
			modems = { default = { enabled = false, signal_freq = 60 }, known = {} },
		},
	})
	assert(scope:spawn(function()
		gsm_service.start(bus:connect({ origin_base = { service = 'gsm' } }), { name = 'gsm', env = 'dev', heartbeat_s = 60 })
	end))
	h.conn = bus:connect({ origin_base = { kind = 'test', service = 'probe' } })
	h.state_sub = h.conn:subscribe(gsm_topics.custom_apns_state())
	return h
end

local function add_apn(h, apn)
	local topic = gsm_topics.rpc('add-custom-apn', 'main')
	return fibers.perform(h.conn:call_op(topic, { record = rec(apn) }, { timeout = 2 }))
end

local function stored(h)
	local body = h.store.values[KEY]
	return body and cjson.decode(body).records or nil
end

local function wait_for_count(h, want)
	while true do
		local msg = fibers.perform(h.state_sub:recv_op())
		assert(msg, 'state subscription closed')
		if msg.payload and msg.payload.count == want then return msg.payload end
	end
end

function tests.test_first_boot_imports_v09_apns_and_publishes_them()
	runfibers.run(function(scope)
		local h = start(scope, { replies = {
			{ ok = true, reason = user_cfg({ rec('one'), { apn = 'bad' }, rec('two') }) },
		} })
		local state = wait_for_count(h, 2)
		assert(state.records[1].apn == 'one')
		local list = assert(stored(h))
		assert(#list == 2 and list[2].apn == 'two')
		assert(h.reads == 1)
	end, { timeout = TIMEOUT })
end

function tests.test_existing_key_is_left_alone()
	runfibers.run(function(scope)
		local body = cjson.encode({ records = { rec('entered-later') } })
		local h = start(scope, { values = { [KEY] = body }, replies = {
			{ ok = true, reason = user_cfg({ rec('old') }) },
		} })
		wait_for_count(h, 1)
		fibers.perform(sleep.sleep_op(0.2))
		assert(h.reads == 0, 'user.cfg must not be read')
		assert(h.store.values[KEY] == body)
		assert(count_calls(h.store, 'put') == 0)
	end, { timeout = TIMEOUT })
end

function tests.test_read_failure_is_retried_until_it_works()
	runfibers.run(function(scope)
		local h = start(scope, { replies = {
			{ ok = false, reason = 'read busy' },
			{ ok = true, reason = user_cfg({ rec('one') }) },
		} })
		wait_for_count(h, 1)
		assert(h.reads == 2)
		assert(stored(h)[1].apn == 'one')
	end, { timeout = TIMEOUT })
end

function tests.test_gsm_runs_and_apns_work_when_the_filesystem_never_answers()
	runfibers.run(function(scope)
		local h = start(scope, {})
		wait_until(function() return count_calls(h.store, 'get') > 0 end, 'store read')
		fibers.perform(sleep.sleep_op(0.05))
		local reply, err = add_apn(h, 'typed')
		assert(reply and reply.ok == true, tostring(err or (reply and reply.reason)))
		assert(stored(h)[1].apn == 'typed')
	end, { timeout = TIMEOUT })
end

function tests.test_missing_and_malformed_files_write_nothing()
	for _, reply in ipairs({
		{ ok = false, reason = 'failed to open file /data/configs/user.cfg: No such file or directory' },
		{ ok = true, reason = 'not json' },
	}) do
		runfibers.run(function(scope)
			local h = start(scope, { replies = { reply } })
			wait_until(function() return h.reads >= 1 end, 'the read')
			fibers.perform(sleep.sleep_op(0.2))
			assert(h.reads == 1, 'a final result must not be retried')
			assert(count_calls(h.store, 'put') == 0)
		end, { timeout = TIMEOUT })
	end
end

function tests.test_a_save_in_the_new_ui_beats_a_slow_import()
	runfibers.run(function(scope)
		local h
		h = start(scope, { replies = { function()
			local reply, err = add_apn(h, 'typed')
			assert(reply and reply.ok == true, tostring(err))
			return { ok = true, reason = user_cfg({ rec('old') }) }
		end } })
		wait_for_count(h, 1)
		fibers.perform(sleep.sleep_op(0.2))
		local list = assert(stored(h))
		assert(#list == 1 and list[1].apn == 'typed', 'the new save must stand')
		assert(count_calls(h.store, 'put') == 1)
	end, { timeout = TIMEOUT })
end

return tests
