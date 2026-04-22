-- services/ui/topics.lua
--
-- Small topic/value helpers used by the UI model and handlers.
--
-- Responsibilities:
--   * validate plain topic arrays
--   * build stable topic keys
--   * deep-copy plain Lua values for UI snapshots/events
--   * match wildcard topic patterns
--
-- Notes:
--   * these helpers are intentionally UI-scoped and plain-table only
--   * sort_entries() orders by debug-topic string for stable presentation, not
--     by any richer topic semantics

local M = {}

local function copy_plain(x, seen)
	if type(x) ~= 'table' then
		return x
	end
	if getmetatable(x) ~= nil then
		error('copy_plain: metatables are not supported', 2)
	end

	seen = seen or {}
	if seen[x] then
		return seen[x]
	end

	local out = {}
	seen[x] = out
	for k, v in pairs(x) do
		out[copy_plain(k, seen)] = copy_plain(v, seen)
	end
	return out
end

local function array_len(t)
	if type(t) ~= 'table' then
		return nil
	end

	local n = 0
	for _ in ipairs(t) do
		n = n + 1
	end

	for k in pairs(t) do
		if type(k) ~= 'number' or k < 1 or k % 1 ~= 0 or k > n then
			return nil
		end
	end

	return n
end

local function normalise_topic(topic, opts)
	opts = opts or {}

	local allow_wild = not not opts.allow_wildcards
	local allow_numbers = opts.allow_numbers ~= false
	local s_wild = opts.s_wild or '+'
	local m_wild = opts.m_wild or '#'

	local n = array_len(topic)
	if not n then
		return nil, 'topic must be a dense array'
	end

	local out = {}
	for i = 1, n do
		local v = topic[i]
		local tv = type(v)

		if tv ~= 'string' and not (allow_numbers and tv == 'number') then
			return nil, ('topic[%d] must be %s'):format(
				i,
				allow_numbers and 'a string or number' or 'a string'
			)
		end

		if tv == 'string' then
			if v == '' then
				return nil, ('topic[%d] must be non-empty'):format(i)
			end
			if not allow_wild and (v == s_wild or v == m_wild) then
				return nil, 'topic must be concrete (no wildcards)'
			end
		end

		out[i] = v
	end

	return out, nil
end

local function topic_key(topic)
	local n = assert(array_len(topic), 'topic_key requires a dense topic array')
	local parts = {}
	for i = 1, n do
		local v = topic[i]
		local tv = type(v)
		local s = tostring(v)
		parts[i] = ((tv == 'number') and 'n' or 's') .. #s .. ':' .. s
	end
	return table.concat(parts, '|')
end

local function topic_debug(topic)
	local n = array_len(topic) or 0
	local parts = {}
	for i = 1, n do
		parts[i] = tostring(topic[i])
	end
	return table.concat(parts, '/')
end

local function match(pattern, topic, s_wild, m_wild)
	s_wild = s_wild or '+'
	m_wild = m_wild or '#'

	local pn = array_len(pattern) or 0
	local tn = array_len(topic) or 0
	local pi, ti = 1, 1

	while pi <= pn do
		local pv = pattern[pi]
		if pv == m_wild then
			return true
		end
		if ti > tn then
			return false
		end
		if pv ~= s_wild and pv ~= topic[ti] then
			return false
		end
		pi = pi + 1
		ti = ti + 1
	end

	return ti > tn
end

local function sort_entries(entries)
	table.sort(entries, function(a, b)
		return topic_debug(a.topic) < topic_debug(b.topic)
	end)
	return entries
end

M.copy_plain = copy_plain
M.normalise_topic = normalise_topic
M.topic_key = topic_key
M.topic_debug = topic_debug
M.match = match
M.sort_entries = sort_entries

return M
