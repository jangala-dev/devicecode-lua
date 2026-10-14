-- Anonymous local UI visits. Pending records and deduplication are bounded.
local json = require 'cjson.safe'
local M = { metric = 'local_ui_visits', topic = { 'obs', 'v1', 'ui', 'metric', 'local_ui_visits' } }

local function valid_id(value)
	return type(value) == 'string' and #value == 32 and value:match('^[a-f0-9]+$') ~= nil
end

function M.valid(value)
	return type(value) == 'table' and valid_id(value.visitor_id) and valid_id(value.visit_id)
end

function M.new()
	local pending, recent = {}, {}
	local buffer = {}

	function buffer:add(value, now)
		if not M.valid(value) then return false end
		for i = #recent, 1, -1 do
			if now - recent[i].time >= 1800 then table.remove(recent, i) end
		end
		for _, record in ipairs(recent) do
			-- Also collapse simultaneous tabs that generated different visit IDs.
			if record.visitor_id == value.visitor_id then return false end
		end
		local record = { visitor_id = value.visitor_id, visit_id = value.visit_id, time = now }
		if #pending == 128 then table.remove(pending, 1) end
		if #recent == 256 then table.remove(recent, 1) end
		pending[#pending + 1] = record
		recent[#recent + 1] = record
		return true
	end

	function buffer:drain(base_time)
		if #pending == 0 then return nil end
		local visits = {}
		for _, record in ipairs(pending) do
			visits[#visits + 1] = {
				visitor_id = record.visitor_id,
				visit_id = record.visit_id,
				visited_at_ms = math.floor((base_time.real + record.time - base_time.mono) * 1000),
			}
		end
		pending = {}
		return assert(json.encode({ schema = 'devicecode.ui.visits/1', visits = visits }))
	end

	return buffer
end

return M
