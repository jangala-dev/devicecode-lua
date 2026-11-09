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

-- Browser storage is per address, so reports say which address was used.
function tests.classifies_the_address_used()
	local cases = {
		['config.bigbox.home'] = 'name', ['CONFIG.BigBox.Home.'] = 'name', ['config.bigbox.home:80'] = 'name',
		['172.28.8.1'] = 'ip', ['172.28.8.1:8080'] = 'ip', ['[fd00::1]'] = 'ip', ['[fd00::1]:80'] = 'ip',
		['[::1]'] = 'ip', ['[2001:db8::8:800:200c:417a]:443'] = 'ip', ['[1:2:3:4:5:6:7:8]'] = 'ip',
		['example.com'] = 'other', ['999.1.1.1'] = 'other', ['172.28.8'] = 'other', [''] = 'other',
		['[1234]'] = 'other', ['[::::]'] = 'other', ['[fd00::1]80'] = 'other', ['[1:2:3:4:5:6:7:8:9]'] = 'other',
		['[1::2::3]'] = 'other', ['[12345::1]'] = 'other', ['[]'] = 'other', ['172.28.8.1:'] = 'other',
	}
	for host, want in pairs(cases) do
		local got = usage.via_from_host(host)
		assert(got == want, host .. ': expected ' .. want .. ', got ' .. tostring(got))
	end
	assert(usage.via_from_host(nil) == 'other')
	assert(usage.via_from_host({}) == 'other')
end

function tests.reports_the_address_used_with_each_visit()
	local buffer = usage.new()
	local first, second, third = visit(1), visit(2), visit(3)
	first.via, second.via, third.via = 'ip', 'name', 'somewhere.example'
	assert(buffer:add(first, 10)); assert(buffer:add(second, 11)); assert(buffer:add(third, 12))
	local batch = json.decode(buffer:drain({ real = 0, mono = 0 }))
	assert(batch.visits[1].via == 'ip')
	assert(batch.visits[2].via == 'name')
	assert(batch.visits[3].via == 'other', 'only the three known values are sent')
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
