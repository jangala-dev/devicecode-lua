-- tests/unit/gsm/test_apn_legacy_import_service.lua
--
-- The first-boot import through the real GSM service, on an in-process bus, with a
-- fake control store and a fake filesystem capability.

local busmod = require 'bus'
local fibers = require 'fibers'
local sleep = require 'fibers.sleep'
local cond = require 'fibers.cond'
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

-- A store whose put takes effect at once but whose reply waits for a gate, and a read that
-- waits for its own gate, so tests can hold each write open while the other side moves.
local function start_gated(scope)
	local bus = busmod.new()
	local h = { conn = bus:connect({ origin_base = { kind = 'test', service = 'probe' } }), values = {}, puts = {} }
	h.read_gate = cond.new()
	h.put_gates = {}
	local server = bus:connect({ origin_base = { kind = 'test', service = 'fake-hal' } })
	local function serve(topic, handler)
		local ep = assert(bus_cleanup.bind(server, topic, { queue_len = 8 }))
		assert(scope:spawn(function()
			while true do
				local req = fibers.perform(ep:recv_op())
				if req == nil then return end
				assert(scope:spawn(function() req:reply(handler(req.payload)) end))
			end
		end))
	end
	serve({ 'cap', 'control-store', 'gsm', 'rpc', 'get' }, function(payload)
		local body = h.values[payload.key]
		if body == nil then return { ok = false, reason = 'not found' } end
		return { ok = true, reason = body }
	end)
	serve({ 'cap', 'control-store', 'gsm', 'rpc', 'put' }, function(payload)
		h.puts[#h.puts + 1] = payload.data
		local n = #h.puts
		local fail = h.fail_put == n
		if not fail then h.values[payload.key] = payload.data end
		local gate = h.put_gates[n]
		if gate then fibers.perform(gate:wait_op()) end
		if fail then return { ok = false, reason = 'disk full' } end
		return { ok = true, reason = true }
	end)
	serve({ 'cap', 'fs', 'credentials', 'rpc', 'read' }, function()
		h.reading = true
		fibers.perform(h.read_gate:wait_op())
		return { ok = true, reason = user_cfg({ rec('old') }) }
	end)
	local cfg_conn = bus:connect({ origin_base = { kind = 'test', service = 'config' } })
	h.retain_cfg = function(rev)
		cfg_conn:retain({ 'cfg', 'gsm' }, {
			schema = 'devicecode.config.snapshot/1',
			service = 'gsm',
			rev = rev,
			data = {
				schema = 'devicecode.config/gsm/1',
				apn_store = { kind = 'control-store', id = 'gsm', key = KEY },
				modems = { default = { enabled = false, signal_freq = 60 }, known = {} },
			},
		})
	end
	h.retain_cfg(1)
	assert(scope:spawn(function()
		gsm_service.start(bus:connect({ origin_base = { service = 'gsm' } }), { name = 'gsm', env = 'dev', heartbeat_s = 60 })
	end))
	return h
end

local function final_list(h)
	local topic = gsm_topics.rpc('list-custom-apns', 'main')
	local reply = assert(fibers.perform(h.conn:call_op(topic, {}, { timeout = 2 })))
	assert(reply.ok == true, tostring(reply.reason))
	local body = h.values[KEY]
	return reply.reason, body and cjson.decode(body).records or nil
end

-- The UI's save has landed but not replied when the import finishes reading.
function tests.test_import_never_overwrites_a_ui_save_still_in_flight()
	runfibers.run(function(scope)
		local h = start_gated(scope)
		h.put_gates[1] = cond.new()
		wait_until(function() return h.reading end, 'the read')
		local reply, err
		assert(scope:spawn(function() reply, err = add_apn(h, 'typed') end))
		wait_until(function() return #h.puts == 1 end, 'the UI save')
		h.read_gate:signal()
		fibers.perform(sleep.sleep_op(0.2))
		h.put_gates[1]:signal()
		wait_until(function() return reply ~= nil or err ~= nil end, 'the UI reply')
		assert(reply and reply.ok == true, tostring(err))
		fibers.perform(sleep.sleep_op(0.2))
		assert(#h.puts == 1, 'the import must not write, wrote ' .. tostring(#h.puts - 1))
		local memory, disk = final_list(h)
		assert(#memory == 1 and memory[1].apn == 'typed', 'memory')
		assert(#disk == 1 and disk[1].apn == 'typed', 'disk')
	end, { timeout = TIMEOUT })
end

-- The import's save is in flight when the UI saves: the UI waits, then wins.
function tests.test_ui_save_waits_for_an_import_save_then_wins()
	runfibers.run(function(scope)
		local h = start_gated(scope)
		h.put_gates[1] = cond.new()
		wait_until(function() return h.reading end, 'the read')
		h.read_gate:signal()
		wait_until(function() return #h.puts == 1 end, 'the import save')
		local reply, err
		assert(scope:spawn(function() reply, err = add_apn(h, 'typed') end))
		fibers.perform(sleep.sleep_op(0.2))
		assert(#h.puts == 1, 'the UI save must wait for the import save')
		h.put_gates[1]:signal()
		wait_until(function() return reply ~= nil or err ~= nil end, 'the UI reply')
		assert(reply and reply.ok == true, tostring(err or (reply and reply.reason)))
		assert(#h.puts == 2)
		fibers.perform(sleep.sleep_op(0.2))
		local memory, disk = final_list(h)
		assert(memory[#memory].apn == 'typed', 'memory')
		assert(disk[#disk].apn == 'typed', 'disk')
	end, { timeout = TIMEOUT })
end

-- Once a UI save has been tried, the import stands down until the next start, so a failed
-- save leaves nothing waiting. The key still doesn't exist, so the next start imports.
function tests.test_failed_ui_save_stands_the_import_down_until_the_next_start()
	runfibers.run(function(scope)
		local h = start_gated(scope)
		h.fail_put = 1
		h.put_gates[1] = cond.new()
		wait_until(function() return h.reading end, 'the read')
		local reply, err
		assert(scope:spawn(function() reply, err = add_apn(h, 'typed') end))
		wait_until(function() return #h.puts == 1 end, 'the UI save')
		h.read_gate:signal()
		fibers.perform(sleep.sleep_op(0.1))
		h.put_gates[1]:signal()
		wait_until(function() return reply ~= nil or err ~= nil end, 'the UI reply')
		assert(reply and reply.ok == false, 'the UI must see the failure')

		-- Waking the main loop must not start the import again.
		h.retain_cfg(2)
		fibers.perform(sleep.sleep_op(0.3))
		assert(#h.puts == 1, 'the import must not write this boot')
		assert(h.values[KEY] == nil)

		-- GSM stays usable, and a retried save works.
		local again, again_err = add_apn(h, 'typed')
		assert(again and again.ok == true, tostring(again_err or (again and again.reason)))
		local memory, disk = final_list(h)
		assert(memory[1].apn == 'typed' and disk[1].apn == 'typed')
	end, { timeout = TIMEOUT })
end

return tests
