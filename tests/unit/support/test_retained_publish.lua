local retained = require 'devicecode.support.retained_publish'

local tests = {}

local function eq(a, b, msg)
	if a ~= b then error((msg or 'assertion failed') .. ': expected ' .. tostring(b) .. ', got ' .. tostring(a), 2) end
end
local function ok(v, msg) if not v then error(msg or 'assertion failed', 2) end return v end

local function topic_key(t)
	local parts = {}
	for i = 1, #(t or {}) do parts[#parts + 1] = tostring(t[i]) end
	return table.concat(parts, '/')
end

local function fake_conn()
	return {
		retains = {},
		unretains = {},
		retain = function(self, topic, payload)
			self.retains[#self.retains + 1] = { topic = topic_key(topic), payload = payload }
			return true
		end,
		unretain = function(self, topic)
			self.unretains[#self.unretains + 1] = topic_key(topic)
			return true
		end,
	}
end

function tests.test_retain_if_changed_suppresses_identical_payloads()
	local conn = fake_conn()
	local cache = {}
	local ret, err, changed = retained.retain_if_changed(conn, cache, 'a', { 'state', 'x' }, { value = 1 })
	ok(ret, err)
	eq(changed, true)
	eq(#conn.retains, 1)
	ret, err, changed = retained.retain_if_changed(conn, cache, 'a', { 'state', 'x' }, { value = 1 })
	ok(ret, err)
	eq(changed, false)
	eq(#conn.retains, 1)
	ret, err, changed = retained.retain_if_changed(conn, cache, 'a', { 'state', 'x' }, { value = 2 })
	ok(ret, err)
	eq(changed, true)
	eq(#conn.retains, 2)
end

function tests.test_unretain_if_present_is_idempotent()
	local conn = fake_conn()
	local cache = { a = { value = 1 } }
	local ret, err, changed = retained.unretain_if_present(conn, cache, 'a', { 'state', 'x' })
	ok(ret, err)
	eq(changed, true)
	eq(#conn.unretains, 1)
	ret, err, changed = retained.unretain_if_present(conn, cache, 'a', { 'state', 'x' })
	ok(ret, err)
	eq(changed, false)
	eq(#conn.unretains, 1)
end

function tests.test_publish_map_changed_retains_changed_and_unretains_removed_entries()
	local conn = fake_conn()
	local cache = {}
	local topic = function(id) return { 'state', 'item', id } end
	local payload = function(rec) return rec end
	local ret, err, changed = retained.publish_map_changed(conn, cache, { a = { n = 1 }, b = { n = 2 } }, topic, payload)
	ok(ret, err)
	eq(changed, 2)
	eq(#conn.retains, 2)
	ret, err, changed = retained.publish_map_changed(conn, cache, { a = { n = 1 }, c = { n = 3 } }, topic, payload)
	ok(ret, err)
	eq(changed, 2)
	eq(#conn.retains, 3)
	eq(#conn.unretains, 1)
	eq(conn.unretains[1], 'state/item/b')
end

return tests
