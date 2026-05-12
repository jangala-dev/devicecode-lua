-- services/monitor.lua
--
-- Monitor service:
--   * subscribes to obs/<ver>/# (canonical plane) and prints messages
--   * subscribes to obs/# (legacy plane) to detect services not using canonical endpoints
--   * bounded, drop-oldest

-- Canonical obs version token. All function/variable names are version-agnostic;
-- bumping the canonical plane to v2 etc. is a one-line change here.
local OBS_VER = 'v1'

local fibers  = require 'fibers'
local runtime = require 'fibers.runtime'
local file    = require 'fibers.io.file'

local perform      = fibers.perform
local named_choice = fibers.named_choice

local base = require 'devicecode.service_base'
local tablex = require 'shared.table'

local M = {}

-- pretty printer kept as-is (it is purely a dev/operator tool)

local is_array = tablex.is_array

local function sort_keys(t)
	local ks = {}
	for k in pairs(t) do ks[#ks + 1] = k end
	table.sort(ks, function(a, b)
		local ta, tb = type(a), type(b)
		if ta ~= tb then return ta < tb end
		if ta == 'number' then return a < b end
		return tostring(a) < tostring(b)
	end)
	return ks
end

local function pretty(v, opts, depth, seen)
	opts            = opts or {}
	depth           = depth or 0
	seen            = seen or {}

	local max_depth = opts.max_depth or 5
	local max_items = opts.max_items or 30

	local tv = type(v)
	if tv == 'string' then return string.format('%q', v) end
	if tv == 'number' or tv == 'boolean' or tv == 'nil' then return tostring(v) end
	if tv ~= 'table' then return ('<%s:%s>'):format(tv, tostring(v)) end

	if seen[v] then return '<cycle>' end
	seen[v] = true

	if depth >= max_depth then
		seen[v] = nil
		return '{...}'
	end

	local out = {}
	local count = 0

	if is_array(v) then
		out[#out + 1] = '['
		for i = 1, #v do
			count = count + 1
			if count > max_items then out[#out + 1] = '...'; break end
			out[#out + 1] = pretty(v[i], opts, depth + 1, seen)
		end
		out[#out + 1] = ']'
	else
		out[#out + 1] = '{'
		local keys = sort_keys(v)
		for i = 1, #keys do
			count = count + 1
			if count > max_items then out[#out + 1] = '...'; break end
			local k = keys[i]
			local kk = (type(k) == 'string') and k or ('[' .. tostring(k) .. ']')
			out[#out + 1] = tostring(kk) .. '=' .. pretty(v[k], opts, depth + 1, seen)
		end
		out[#out + 1] = '}'
	end

	seen[v] = nil
	return table.concat(out, ' ')
end

local function topic_to_string(topic)
	local parts = {}
	for i = 1, #topic do parts[#parts + 1] = tostring(topic[i]) end
	return table.concat(parts, '/')
end

local function fmt_time()
	local mono = runtime.now and runtime.now() or 0
	return os.date('%Y-%m-%d %H:%M:%S') .. string.format(' (mono=%.3f)', mono)
end

local function classify_canonical(msg)
	local t = msg.topic or {}
	-- canonical shape: obs/<ver>/<svc>/<kind>[/<name>]
	local svc  = t[3] or 'unknown'
	local kind = t[4]
	local name = t[5]

	if kind == 'event' then
		if name == 'log' then
			local level = (type(msg.payload) == 'table' and msg.payload.level) or 'info'
			return 'log', svc, level
		end
		return 'event', svc, name or 'event'
	elseif kind == 'metric' then
		return 'metric', svc, nil
	elseif kind == 'counter' then
		return 'counter', svc, name or 'counter'
	end
	return 'obs', svc, nil
end

local function format_canonical_line(msg)
	local kind, svc, lvl_or_name = classify_canonical(msg)

	local payload = msg.payload
	local payload_s = (type(payload) == 'string') and payload
		or pretty(payload, { max_depth = 6, max_items = 40 })

	if kind == 'log' then
		return string.format('%s  LOG  %-10s %-5s  %s',
			fmt_time(), tostring(svc), tostring(lvl_or_name or 'info'), payload_s)
	end

	if kind == 'metric' then
		return string.format('%s  MET  %-10s %-24s  %s',
			fmt_time(), tostring(svc), topic_to_string(msg.topic), payload_s)
	end

	if kind == 'event' then
		return string.format('%s  EVT  %-10s %-12s  %s',
			fmt_time(), tostring(svc), tostring(lvl_or_name or 'event'), payload_s)
	end

	if kind == 'counter' then
		return string.format('%s  CNT  %-10s %-12s  %s',
			fmt_time(), tostring(svc), tostring(lvl_or_name or 'counter'), payload_s)
	end

	return string.format('%s  OBS  %-10s %-24s  %s',
		fmt_time(), tostring(svc), topic_to_string(msg.topic), payload_s)
end

-- Formats a warning line for traffic on the legacy obs plane that indicates
-- a service is not publishing on the canonical plane.
-- reason: 'legacy-only'       — topic is a known dual-publish target but no canonical seen
--         'unknown-endpoint'  — topic is outside the known obs schema entirely
local function format_legacy_warn(msg, reason)
	local t   = msg.topic or {}
	local svc = tostring(t[3] or 'unknown')

	local payload = msg.payload
	local payload_s = (type(payload) == 'string') and payload
		or pretty(payload, { max_depth = 4, max_items = 20 })

	return string.format('%s  WARN  %-10s %-20s  topic=%s  %s',
		fmt_time(), svc, tostring(reason), topic_to_string(t), payload_s)
end

function M.start(conn, ctx)
	ctx = ctx or {}
	local svc = base.new(conn, { name = ctx.name or 'monitor', env = ctx.env })
	local name = svc.name

	local out = file.fdopen(1, 'w', 'stdout')
	out:setvbuf('line')

	local function write_line(line)
		local n, err = perform(out:write_op(line, '\n'))
		if n == nil and err ~= nil then error(err) end
	end

	-- Tracks which (svc, canonical_kind) pairs have been seen on the canonical plane.
	-- canonical_seen[svc_name][canonical_kind] = true
	-- Granularity is per-kind so a service publishing only metrics on the canonical
	-- plane does not suppress warnings about its legacy-only events/states.
	local canonical_seen = {}

	-- Count of consecutive legacy-only messages per (svc, legacy_kind), for pairs
	-- not yet seen on the canonical plane. Reset per-kind when canonical arrives.
	-- A threshold of 2 tolerates the timing race in service_base (which publishes
	-- legacy before canonical in the same obs_log/obs_event call).
	local legacy_count = {}
	local LEGACY_WARN_THRESHOLD = 2

	-- Known dually-supported legacy topic kinds (service_base publishes both legacy
	-- and canonical for these). Any other kind on the legacy plane is unknown.
	-- Maps legacy kind → the canonical kind it corresponds to:
	--   obs/log/<svc>/...   → obs/v1/<svc>/event/log  (canonical kind: 'event')
	--   obs/event/<svc>/... → obs/v1/<svc>/event/<n>  (canonical kind: 'event')
	--   obs/state/<svc>/... → obs/v1/<svc>/metric/<n> (canonical kind: 'metric')
	local legacy_to_canonical_kind = { log = 'event', event = 'event', state = 'metric' }

	local canonical_sub = conn:subscribe(
		{ 'obs', OBS_VER, '#' },
		{ queue_len = 500, full = 'drop_oldest' }
	)
	local legacy_sub = conn:subscribe(
		{ 'obs', '#' },
		{ queue_len = 200, full = 'drop_oldest' }
	)

	local canonical_topic = 'obs/' .. OBS_VER .. '/#'
	svc:status('running', { subscribed = canonical_topic .. ',obs/#' })

	write_line(string.format('%s  STA  %-10s %-12s  %s',
		fmt_time(), name, 'start',
		'subscribed to ' .. canonical_topic .. ' (canonical) + obs/# (legacy-detect)'))

	while true do
		local which, msg, err = perform(named_choice {
			canonical = canonical_sub:recv_op(),
			legacy    = legacy_sub:recv_op(),
		})

		if which == 'canonical' then
			if msg == nil then
				local why = tostring(err or 'closed')
				write_line(string.format('%s  STA  %-10s %-12s  %s',
					fmt_time(), name, 'stop', 'canonical subscription ended: ' .. why))
				break
			end
			local svc_name = msg.topic[3]
			local can_kind = msg.topic[4]
			if type(svc_name) == 'string' and type(can_kind) == 'string' then
				canonical_seen[svc_name] = canonical_seen[svc_name] or {}
				canonical_seen[svc_name][can_kind] = true
				-- Reset legacy counts for all legacy kinds that map to this canonical kind.
				if legacy_count[svc_name] then
					legacy_count[svc_name][can_kind] = nil
				end
			end
			write_line(format_canonical_line(msg))

		elseif which == 'legacy' then
			if msg == nil then
				local why = tostring(err or 'closed')
				write_line(string.format('%s  STA  %-10s %-12s  %s',
					fmt_time(), name, 'stop', 'legacy subscription ended: ' .. why))
				break
			end

			local topic    = msg.topic or {}
			local kind     = topic[2]
			local svc_name = topic[3]

			-- Messages on the canonical plane also arrive via the obs/# wildcard; skip them.
			if kind ~= OBS_VER then
				if legacy_to_canonical_kind[kind] then
					local can_kind = legacy_to_canonical_kind[kind]
					local svc_seen = canonical_seen[svc_name]
					if not (svc_seen and svc_seen[can_kind]) then
						-- No canonical counterpart seen yet for this kind; count toward warning.
						local svc_counts = legacy_count[svc_name] or {}
						legacy_count[svc_name] = svc_counts
						local count = (svc_counts[kind] or 0) + 1
						svc_counts[kind] = count
						if count >= LEGACY_WARN_THRESHOLD then
							write_line(format_legacy_warn(msg, 'legacy-only'))
						end
					end
				else
					write_line(format_legacy_warn(msg, 'unknown-endpoint'))
				end
			end
		end
	end
end

return M
