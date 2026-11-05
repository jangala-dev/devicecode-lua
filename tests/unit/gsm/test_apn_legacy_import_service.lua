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

local function list_apns(h)
	local topic = gsm_topics.rpc('list-custom-apns', 'main')
	return fibers.perform(h.conn:call_op(topic, {}, { timeout = 2 }))
end

local function wait_for_list(h, want)
	wait_until(function()
		local reply = list_apns(h)
		return reply and reply.ok == true and #reply.reason == want
	end, 'the list to hold ' .. want)
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
	h.retain_cfg = function(rev)
		cfg_conn:retain({ 'cfg', 'gsm' }, {
			schema = 'devicecode.config.snapshot/1',
			service = 'gsm',
			rev = rev,
			data = {
				schema = 'devicecode.config/gsm/1',
				apn_store = { kind = 'control-store', id = 'gsm', key = KEY, import_v09_user_cfg = opts.import ~= false },
				modems = { default = { enabled = false, signal_freq = 60 }, known = {} },
			},
		})
	end
	h.retain_cfg(1)
	assert(scope:spawn(function()
		gsm_service.start(bus:connect({ origin_base = { service = 'gsm' } }), {
			name = 'gsm', env = 'dev', heartbeat_s = 60, apn_import_give_up_s = opts.give_up_s,
		})
	end))
	h.conn = bus:connect({ origin_base = { kind = 'test', service = 'probe' } })
	h.state_sub = h.conn:subscribe(gsm_topics.custom_apns_state())
	return h
end

local function add_apn(h, apn)
	local topic = gsm_topics.rpc('add-custom-apn', 'main')
	return fibers.perform(h.conn:call_op(topic, { record = rec(apn) }, { timeout = 2 }))
end

local function wait_for_status(h, want)
	local sub = h.conn:subscribe(gsm_topics.apns_status_state())
	while true do
		local msg = assert(fibers.perform(sub:recv_op()), 'status subscription closed')
		if msg.payload and msg.payload.state == want then return end
	end
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

function tests.test_import_off_reads_nothing_and_leaves_saves_free()
	runfibers.run(function(scope)
		local h = start(scope, { import = false, replies = { { ok = true, reason = user_cfg({ rec('old') }) } } })
		wait_until(function() return count_calls(h.store, 'get') > 0 end, 'store read')
		wait_for_status(h, 'ready')
		local reply, err = add_apn(h, 'typed')
		assert(reply and reply.ok == true, tostring(err or (reply and reply.reason)))
		assert(h.reads == 0, 'user.cfg must not be read')
		assert(#stored(h) == 1)
	end, { timeout = TIMEOUT })
end

-- With no filesystem answer, APN requests wait only until the import gives up.
function tests.test_import_gives_up_so_requests_cannot_stay_waiting()
	runfibers.run(function(scope)
		local h = start(scope, { give_up_s = 0.3 })
		wait_for_status(h, 'ready')
		local reply, err = add_apn(h, 'typed')
		assert(reply and reply.ok == true, tostring(err or (reply and reply.reason)))
		assert(stored(h)[1].apn == 'typed')
	end, { timeout = TIMEOUT })
end

-- Other main-loop events must not cost the import its retries.
function tests.test_busy_main_loop_cannot_starve_the_import()
	runfibers.run(function(scope)
		local h = start(scope, { give_up_s = 3, replies = {
			{ ok = false, reason = 'read busy' },
			{ ok = true, reason = user_cfg({ rec('one') }) },
		} })
		assert(scope:spawn(function()
			for rev = 2, 60 do
				h.retain_cfg(rev)
				fibers.perform(sleep.sleep_op(0.05))
			end
		end))
		wait_until(function() return h.reads >= 2 end, 'a retry')
		wait_for_list(h, 1)
		assert(stored(h)[1].apn == 'one')
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

-- A store whose put takes effect at once but whose reply waits for a gate, and a read that
-- waits for its own gate, so tests can hold each write open while the other side moves.
local function start_gated(scope, opts)
	opts = opts or {}
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
				apn_store = { kind = 'control-store', id = 'gsm', key = KEY, import_v09_user_cfg = true },
				modems = { default = { enabled = false, signal_freq = 60 }, known = {} },
			},
		})
	end
	h.retain_cfg(1)
	assert(scope:spawn(function()
		gsm_service.start(bus:connect({ origin_base = { service = 'gsm' } }), {
			name = 'gsm', env = 'dev', heartbeat_s = 60, apn_import_give_up_s = opts.give_up_s,
		})
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

-- This is how the local UI works: it reads the whole list, then saves the whole list back.
-- A read and a save that arrive while the import is reading wait, and see what it imported.
function tests.test_ui_read_then_save_during_the_read_keeps_the_import()
	runfibers.run(function(scope)
		local h = start_gated(scope)
		wait_until(function() return h.reading end, 'the read')
		local listed, list_err
		assert(scope:spawn(function() listed, list_err = list_apns(h) end))
		local added
		assert(scope:spawn(function() added = add_apn(h, 'added') end))
		fibers.perform(sleep.sleep_op(0.1))
		assert(listed == nil and added == nil, 'requests must wait for the import')
		assert(#h.puts == 0)
		h.read_gate:signal()
		wait_until(function() return listed ~= nil or list_err ~= nil end, 'the list')
		assert(listed and listed.ok == true, tostring(list_err))
		assert(#listed.reason >= 1 and listed.reason[1].apn == 'old', 'the read must see the import')
		wait_until(function() return added ~= nil end, 'the add')
		assert(added.ok == true, tostring(added.reason))

		local current = assert(list_apns(h))
		local next_list = current.reason
		next_list[#next_list + 1] = rec('typed')
		local topic = gsm_topics.rpc('replace-custom-apns', 'main')
		local reply = fibers.perform(h.conn:call_op(topic, { records = next_list }, { timeout = 2 }))
		assert(reply and reply.ok == true, tostring(reply and reply.reason))
		local memory, disk = final_list(h)
		assert(#memory == 3 and memory[1].apn == 'old' and memory[3].apn == 'typed', 'memory')
		assert(#disk == 3 and disk[1].apn == 'old', 'disk')
	end, { timeout = TIMEOUT })
end

-- The import's save is in flight: a UI save waits for it, then adds to it.
function tests.test_ui_save_waits_for_the_import_save_and_adds_to_it()
	runfibers.run(function(scope)
		local h = start_gated(scope)
		h.put_gates[1] = cond.new()
		wait_until(function() return h.reading end, 'the read')
		h.read_gate:signal()
		wait_until(function() return #h.puts == 1 end, 'the import save')
		local reply
		assert(scope:spawn(function() reply = add_apn(h, 'typed') end))
		fibers.perform(sleep.sleep_op(0.1))
		assert(#h.puts == 1 and reply == nil, 'the UI save must wait')
		h.put_gates[1]:signal()
		wait_until(function() return reply ~= nil end, 'the UI reply')
		assert(reply.ok == true, tostring(reply.reason))
		local memory, disk = final_list(h)
		assert(#memory == 2 and memory[1].apn == 'old' and memory[2].apn == 'typed', 'memory')
		assert(#disk == 2 and disk[1].apn == 'old', 'disk')
	end, { timeout = TIMEOUT })
end

-- Giving up can't lose a save that has landed: only a finished attempt can give up.
function tests.test_deadline_does_not_abandon_a_save_in_flight()
	runfibers.run(function(scope)
		local h = start_gated(scope, { give_up_s = 0.2 })
		h.put_gates[1] = cond.new()
		wait_until(function() return h.reading end, 'the read')
		h.read_gate:signal()
		wait_until(function() return #h.puts == 1 end, 'the import save')
		fibers.perform(sleep.sleep_op(0.4))
		h.put_gates[1]:signal()
		wait_for_list(h, 1)
		local reply, err = add_apn(h, 'typed')
		assert(reply and reply.ok == true, tostring(err or (reply and reply.reason)))
		local memory, disk = final_list(h)
		assert(#memory == 2 and memory[1].apn == 'old', 'memory')
		assert(#disk == 2 and disk[1].apn == 'old', 'disk')
	end, { timeout = TIMEOUT })
end

function tests.test_failed_import_save_is_retried()
	runfibers.run(function(scope)
		local h = start_gated(scope)
		h.fail_put = 1
		wait_until(function() return h.reading end, 'the read')
		h.read_gate:signal()
		wait_for_list(h, 1)
		assert(#h.puts == 2, 'puts ' .. tostring(#h.puts))
		local memory, disk = final_list(h)
		assert(memory[1].apn == 'old' and disk[1].apn == 'old')
	end, { timeout = TIMEOUT })
end

-- A config reload in the middle of the import's save doesn't disturb it.
function tests.test_config_reload_during_the_import_save()
	runfibers.run(function(scope)
		local h = start_gated(scope)
		h.put_gates[1] = cond.new()
		wait_until(function() return h.reading end, 'the read')
		h.read_gate:signal()
		wait_until(function() return #h.puts == 1 end, 'the import save')
		h.retain_cfg(2)
		fibers.perform(sleep.sleep_op(0.1))
		h.put_gates[1]:signal()
		wait_for_list(h, 1)
		assert(#h.puts == 1, 'the import must not save twice')
		local reply, err = add_apn(h, 'typed')
		assert(reply and reply.ok == true, tostring(err or (reply and reply.reason)))
		local memory = final_list(h)
		assert(#memory == 2 and memory[1].apn == 'old')
	end, { timeout = TIMEOUT })
end

function tests.test_only_bigbox_ss_turns_the_import_on()
	local function flag(target)
		local f = assert(io.open('../src/configs/' .. target .. '.json'))
		local doc = assert(cjson.decode(f:read('*a')))
		f:close()
		return doc.gsm.data.apn_store.import_v09_user_cfg
	end
	assert(flag('bigbox-ss') == true)
	assert(flag('bigbox-v1-cm') == nil and flag('bigbox-v1-cm-2') == nil)
end

return tests
