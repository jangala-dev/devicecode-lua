local publisher = require 'services.wired.publisher'

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

local function snapshot(link_state)
	return {
		service = 'wired',
		state = 'running',
		ready = true,
		generation = 1,
		config = {},
		observations = {},
		stats = {},
		surfaces = {
			a = { surface_id = 'a', link = { state = link_state or 'up' }, availability = { state = 'available' } },
		},
		topology = { trunks = {}, access = {}, protected_trunks = {} },
		violations = {},
	}
end

local function topics(retains)
	local out = {}
	for _, rec in ipairs(retains) do out[#out + 1] = rec.topic end
	table.sort(out)
	return table.concat(out, ',')
end

function tests.test_publish_all_suppresses_unchanged_retained_payloads()
	local conn = fake_conn()
	local published = publisher.new_state()
	local dirty = publisher.mark_all(publisher.new_dirty_state())
	local ok1, err1, changed = publisher.publish_dirty_now(conn, snapshot('up'), published, dirty)
	ok(ok1, err1)
	eq(changed, 4)
	eq(#conn.retains, 4)
	dirty = publisher.mark_all(dirty)
	local ok2, err2, changed2 = publisher.publish_dirty_now(conn, snapshot('up'), published, dirty)
	ok(ok2, err2)
	eq(changed2, 0)
	eq(#conn.retains, 4)
end

function tests.test_dirty_surface_publish_only_retains_changed_surface()
	local conn = fake_conn()
	local published = publisher.new_state()
	local dirty = publisher.mark_all(publisher.new_dirty_state())
	ok(publisher.publish_dirty_now(conn, snapshot('up'), published, dirty))
	local before = #conn.retains
	publisher.mark_surface(dirty, 'a')
	local ok2, err2, changed = publisher.publish_dirty_now(conn, snapshot('down'), published, dirty)
	ok(ok2, err2)
	eq(changed, 1)
	eq(#conn.retains, before + 1)
	eq(conn.retains[#conn.retains].topic, 'state/wired/surface/a')
end


function tests.test_counter_updates_publish_metric_without_republishing_surface()
	local conn = fake_conn()
	local published = publisher.new_state()
	local snap = snapshot('up')
	snap.counters = { a = { surface_id = 'a', counters = { rx = { bytes = 1 } } } }
	local dirty = publisher.mark_all(publisher.new_dirty_state())
	ok(publisher.publish_dirty_now(conn, snap, published, dirty))
	local before = #conn.retains
	local snap2 = snapshot('up')
	snap2.counters = { a = { surface_id = 'a', counters = { rx = { bytes = 2 } } } }
	publisher.mark_counter(dirty, 'a')
	local ok2, err2, changed = publisher.publish_dirty_now(conn, snap2, published, dirty)
	ok(ok2, err2)
	eq(changed, 1)
	eq(#conn.retains, before + 1)
	eq(conn.retains[#conn.retains].topic, 'obs/v1/wired/metric/surface_counters/a')
end

function tests.test_removed_dirty_surface_is_unretained_once()
	local conn = fake_conn()
	local published = publisher.new_state()
	local dirty = publisher.mark_all(publisher.new_dirty_state())
	ok(publisher.publish_dirty_now(conn, snapshot('up'), published, dirty))
	publisher.mark_surface(dirty, 'a')
	local snap = snapshot('up')
	snap.surfaces = {}
	local ok2, err2, changed = publisher.publish_dirty_now(conn, snap, published, dirty)
	ok(ok2, err2)
	eq(changed, 1)
	eq(#conn.unretains, 1)
	eq(conn.unretains[1], 'state/wired/surface/a')
end

return tests
