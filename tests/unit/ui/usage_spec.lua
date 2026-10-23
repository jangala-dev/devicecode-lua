local usage = require 'services.ui.usage'
local json = require 'cjson.safe'
local tests = {}
local function visit(n, browser)
	return { visitor_id = string.format('%032x', browser or n), visit_id = string.format('%032x', n) }
end

function tests.validates_ids()
	assert(usage.valid(visit(1)))
	for _, value in ipairs({ {}, { visitor_id = 'x', visit_id = 'y' }, { visitor_id = {}, visit_id = 1 } }) do
		assert(not usage.valid(value))
	end
end

function tests.batches_multiple_visits_and_deduplicates_across_flushes()
	local buffer = usage.new()
	assert(buffer:add(visit(1), 10))
	assert(buffer:add(visit(2), 12))
	assert(not buffer:add(visit(1), 15))
	local batch = json.decode(buffer:drain({ real = 1700000000, mono = 0 }))
	assert(batch.schema == 'devicecode.ui.visits/1')
	assert(#batch.visits == 2)
	assert(batch.visits[1].visited_at_ms == 1700000010000)
	assert(not buffer:add(visit(3, 1), 20), 'simultaneous tabs must collapse')
	assert(buffer:drain({ real = 0, mono = 0 }) == nil)
	assert(buffer:add(visit(4, 1), 1810), 'new visit after thirty minutes')
end

function tests.drops_oldest_on_overflow()
	local buffer = usage.new()
	for i = 1, 300 do assert(buffer:add(visit(i), i)) end
	local batch = json.decode(buffer:drain({ real = 0, mono = 0 }))
	assert(#batch.visits == 128)
	assert(batch.visits[1].visit_id == visit(173).visit_id)
	assert(batch.visits[128].visit_id == visit(300).visit_id)
end

return tests
