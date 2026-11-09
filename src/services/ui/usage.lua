-- Anonymous local UI visits. Pending records and deduplication are bounded.
local json = require 'cjson.safe'
local M = { metric = 'local_ui_visits', topic = { 'obs', 'v1', 'ui', 'metric', 'local_ui_visits' } }

local function valid_id(value)
	return type(value) == 'string' and #value == 32 and value:match('^[a-f0-9]+$') ~= nil
end

function M.valid(value)
	return type(value) == 'table' and valid_id(value.visitor_id) and valid_id(value.visit_id)
end

local VIA = { ip = true, name = true, other = true }
M.UI_NAME = 'config.bigbox.home'

local function ipv4(host)
	local parts = { host:match('^(%d+)%.(%d+)%.(%d+)%.(%d+)$') }
	if #parts ~= 4 then return false end
	for _, part in ipairs(parts) do
		if #part > 3 or tonumber(part) > 255 then return false end
	end
	return true
end

local function ipv6(addr)
	-- A dotted IPv4 ending, as in ::ffff:172.28.8.1, counts as two groups.
	local extra = 0
	local prefix, v4 = addr:match('^(.*:)(%d+%.%d+%.%d+%.%d+)$')
	if v4 then
		if not ipv4(v4) then return false end
		addr, extra = prefix .. '0', 1
	end
	local head, tail = addr, nil
	local at = addr:find('::', 1, true)
	if at then
		if addr:find('::', at + 1, true) then return false end
		head, tail = addr:sub(1, at - 1), addr:sub(at + 2)
	end
	local count = 0
	for _, part in ipairs({ head, tail }) do
		if part ~= '' then
			for group in (part .. ':'):gmatch('([^:]*):') do
				if not group:match('^%x%x?%x?%x?$') then return false end
				count = count + 1
			end
		end
	end
	count = count + extra
	if at then return count <= 7 end
	return count == 8
end

--- Which address the UI was reached at, from the request's Host header: 'name' for
--- the box's UI name, 'ip' for an address, otherwise 'other'. Browser storage is per
--- address, so this tells apart visitors who use each one. The host itself is not sent.
function M.via_from_host(host)
	if type(host) ~= 'string' then return 'other' end
	host = host:lower()
	if host:sub(1, 1) == '[' then
		local addr, rest = host:match('^%[([%x:%.]+)%](.*)$')
		local port_ok = rest == '' or (rest and rest:match('^:%d+$'))
		return (addr and port_ok and ipv6(addr)) and 'ip' or 'other'
	end
	host = host:gsub(':%d+$', ''):gsub('%.$', '')
	if host == M.UI_NAME then return 'name' end
	return ipv4(host) and 'ip' or 'other'
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
		local record = {
			visitor_id = value.visitor_id, visit_id = value.visit_id, time = now,
			via = VIA[value.via] and value.via or 'other',
		}
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
				via = record.via,
			}
		end
		pending = {}
		return assert(json.encode({ schema = 'devicecode.ui.visits/1', visits = visits }))
	end

	return buffer
end

return M
