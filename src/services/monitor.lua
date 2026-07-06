-- services/monitor.lua
--
-- Monitor service:
--   * operator mode subscribes to observability but prints structured logs only
--   * keeps a boot buffer and rolling in-memory ring of normalised log records
--   * raw mode preserves the previous firehose behaviour for development
--   * legacy obs-plane detection is retained, but no longer pollutes operator mode

local OBS_VER = 'v1'

local fibers  = require 'fibers'
local runtime = require 'fibers.runtime'
local file    = require 'fibers.io.file'
local sleep   = require 'fibers.sleep'

local perform      = fibers.perform
local named_choice = fibers.named_choice

local base = require 'devicecode.service_base'

local M = {}

local LEVEL_VALUE = {
	trace = 10,
	debug = 20,
	info  = 30,
	warn  = 40,
	error = 50,
	fatal = 60,
}

local function env(name, default)
	local v = os.getenv(name)
	if v == nil or v == '' then return default end
	return v
end

local function env_num(name, default)
	local n = tonumber(env(name, nil))
	if n == nil then return default end
	return n
end

local function norm_level(level)
	level = tostring(level or 'info'):lower()
	if level == 'warning' then level = 'warn' end
	if LEVEL_VALUE[level] then return level end
	return 'info'
end

local function level_enabled(level, min_level)
	return (LEVEL_VALUE[norm_level(level)] or LEVEL_VALUE.info) >= (LEVEL_VALUE[norm_level(min_level)] or LEVEL_VALUE.info)
end

-- pretty printer kept intentionally small; this is an operator/dev tool, not a
-- serialisation contract.
local function is_array(t)
	local n = 0
	for _ in ipairs(t) do n = n + 1 end
	for k in pairs(t) do
		if type(k) ~= 'number' or k < 1 or k % 1 ~= 0 or k > n then return false end
	end
	return true
end

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
	if depth >= max_depth then seen[v] = nil; return '{...}' end

	local out, count = {}, 0
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
	for i = 1, #(topic or {}) do parts[#parts + 1] = tostring(topic[i]) end
	return table.concat(parts, '/')
end

local function fmt_time(mono)
	mono = mono or (runtime.now and runtime.now()) or 0
	return os.date('%Y-%m-%d %H:%M:%S') .. string.format(' (mono=%.3f)', mono)
end

local function classify_canonical(msg)
	local t = msg.topic or {}
	-- canonical service_base log: obs/v1/<svc>/event/log
	local svc, kind, name = t[3] or 'unknown', t[4], t[5]
	if kind == 'event' and name == 'log' then
		local level = (type(msg.payload) == 'table' and msg.payload.level) or 'info'
		return 'log', svc, level
	end
	-- newer direct log shape used by http: obs/v1/<svc>/log/<id>/<level>
	if kind == 'log' then
		return 'log', svc, t[6] or t[5] or (type(msg.payload) == 'table' and msg.payload.level) or 'info'
	end
	if kind == 'event' then return 'event', svc, name or 'event' end
	if kind == 'metric' then return 'metric', svc, nil end
	if kind == 'counter' then return 'counter', svc, name or 'counter' end
	return 'obs', svc, nil
end

local function classify_legacy(msg)
	local t = msg.topic or {}
	local kind, svc = t[2], t[3] or 'unknown'
	if kind == 'log' then return 'log', svc, t[4] or (type(msg.payload) == 'table' and msg.payload.level) or 'info' end
	if kind == 'event' then return 'event', svc, t[4] or 'event' end
	if kind == 'state' then return 'state', svc, t[4] or 'state' end
	return 'obs', svc, nil
end

local function payload_string(payload, max_depth, max_items)
	return (type(payload) == 'string') and payload
		or pretty(payload, { max_depth = max_depth or 6, max_items = max_items or 40 })
end

local DETAIL_SKIP_KEYS = {
	service = true, env = true, run_id = true, ts = true, at = true, level = true,
	what = true, summary = true, message = true,
}

local DETAIL_PRIORITY = {
	'entity', 'id', 'role', 'modem', 'address', 'interface', 'uplink_id', 'device',
	'from', 'to', 'state', 'ready', 'reason', 'ok', 'err', 'peak_mbps', 'elapsed_ms',
	'generation', 'apply_id', 'weight_apply_id', 'links', 'components', 'backend',
}

local function compact_value(v)
	local tv = type(v)
	if tv == 'string' then return v end
	if tv == 'number' then
		if math.floor(v) == v then return tostring(v) end
		return string.format('%.3f', v):gsub('0+$', ''):gsub('%.$', '')
	end
	if tv == 'boolean' then return v and 'true' or 'false' end
	if tv == 'nil' then return nil end
	return pretty(v, { max_depth = 2, max_items = 5 })
end

local function summarise_log_payload(payload)
	if type(payload) ~= 'table' then return tostring(payload or '') end
	if type(payload.summary) == 'string' and payload.summary ~= '' then return payload.summary end
	if type(payload.message) == 'string' and payload.message ~= '' then return payload.message end

	local parts, used = {}, {}
	for _, k in ipairs(DETAIL_PRIORITY) do
		local v = payload[k]
		local s = compact_value(v)
		if s ~= nil and s ~= '' then
			parts[#parts + 1] = tostring(k) .. '=' .. s
			used[k] = true
		end
	end
	local keys = sort_keys(payload)
	for _, k in ipairs(keys) do
		if #parts >= 8 then break end
		if type(k) == 'string' and not used[k] and not DETAIL_SKIP_KEYS[k] then
			local s = compact_value(payload[k])
			if s ~= nil and s ~= '' then parts[#parts + 1] = tostring(k) .. '=' .. s end
		end
	end
	local what = payload.what and tostring(payload.what) or nil
	if #parts > 0 then
		return what and (what .. ' ' .. table.concat(parts, ' ')) or table.concat(parts, ' ')
	end
	if what ~= nil then return what end
	return payload_string(payload, 4, 12)
end

local function format_log_line(rec)
	return string.format('%s  LOG  %-10s %-5s  %-24s  %s',
		fmt_time(rec.mono), tostring(rec.service), tostring(rec.level), tostring(rec.what or ''), summarise_log_payload(rec.payload))
end

local function format_canonical_line(msg)
	local kind, svc, lvl_or_name = classify_canonical(msg)
	local payload_s = payload_string(msg.payload, 6, 40)
	if kind == 'log' then
		local rec = {
			mono = (runtime.now and runtime.now()) or 0,
			service = svc,
			level = norm_level(lvl_or_name),
			what = type(msg.payload) == 'table' and msg.payload.what or nil,
			payload = msg.payload,
		}
		return format_log_line(rec)
	end
	if kind == 'metric' then
		return string.format('%s  MET  %-10s %-24s  %s', fmt_time(), tostring(svc), topic_to_string(msg.topic), payload_s)
	end
	if kind == 'event' then
		return string.format('%s  EVT  %-10s %-12s  %s', fmt_time(), tostring(svc), tostring(lvl_or_name or 'event'), payload_s)
	end
	if kind == 'counter' then
		return string.format('%s  CNT  %-10s %-12s  %s', fmt_time(), tostring(svc), tostring(lvl_or_name or 'counter'), payload_s)
	end
	return string.format('%s  OBS  %-10s %-24s  %s', fmt_time(), tostring(svc), topic_to_string(msg.topic), payload_s)
end

local function format_legacy_warn(msg, reason)
	local t = msg.topic or {}
	local _, svc = classify_legacy(msg)
	return string.format('%s  WARN  %-10s %-20s  topic=%s  %s',
		fmt_time(), tostring(svc), tostring(reason), topic_to_string(t), payload_string(msg.payload, 4, 20))
end

local function normalise_log_record(msg, plane)
	local kind, svc, level
	if plane == 'canonical' then kind, svc, level = classify_canonical(msg) else kind, svc, level = classify_legacy(msg) end
	if kind ~= 'log' then return nil end
	local payload = msg.payload
	if type(payload) ~= 'table' then payload = { message = tostring(payload or '') } end
	return {
		mono = (runtime.now and runtime.now()) or 0,
		wall = os.date('%Y-%m-%d %H:%M:%S'),
		service = tostring(payload.service or svc or 'unknown'),
		level = norm_level(payload.level or level),
		what = payload.what,
		summary = payload.summary or payload.message,
		payload = payload,
		topic = msg.topic,
		plane = plane,
	}
end

local function ring_append(buf, rec, max_records)
	if max_records <= 0 then return false end
	buf[#buf + 1] = rec
	if #buf > max_records then
		table.remove(buf, 1)
		return false
	end
	return true
end

function M.start(conn, ctx)
	ctx = ctx or {}
	local svc = base.new(conn, { name = ctx.name or 'monitor', env = ctx.env })
	local name = svc.name

	local profile = tostring(ctx.profile or env('DEVICECODE_MONITOR_PROFILE', 'operator'))
	local min_level = tostring(ctx.min_level or env('DEVICECODE_MONITOR_LEVEL', profile == 'debug' and 'debug' or profile == 'trace' and 'trace' or 'info'))
	local raw = profile == 'raw'
	local legacy_detect = raw or env('DEVICECODE_MONITOR_LEGACY_DETECT', '0') == '1'
	local summary_period_s = env_num('DEVICECODE_MONITOR_SUMMARY_PERIOD_S', 60)
	local ring_max = tonumber(ctx.ring_max_records) or env_num('DEVICECODE_MONITOR_RING_RECORDS', 5000)
	local boot_max = tonumber(ctx.boot_max_records) or env_num('DEVICECODE_MONITOR_BOOT_RECORDS', 2000)
	local boot_window_s = tonumber(ctx.boot_window_s) or env_num('DEVICECODE_MONITOR_BOOT_SECONDS', 120)

	local out = file.fdopen(1, 'w', 'stdout')
	out:setvbuf('line')

	local function write_line(line)
		local which, a, b = perform(named_choice {
			wrote   = out:write_op(line, '\n'),
			timeout = sleep.sleep_op(0.5):wrap(function () return nil, 'write timeout' end),
		})
		if which == 'wrote' then
			local n, err = a, b
			if n == nil and err ~= nil then error(err) end
		end
	end

	local start_mono = (runtime.now and runtime.now()) or 0
	local last_summary = start_mono
	local ring, boot = {}, {}
	local counts = { received = 0, logs = 0, stored = 0, printed = 0, dropped = 0, suppressed = 0 }

	local function publish_status(extra)
		local payload = {
			profile = profile,
			min_level = min_level,
			ring_records = #ring,
			boot_records = #boot,
			counts = counts,
		}
		if type(extra) == 'table' then for k, v in pairs(extra) do payload[k] = v end end
		svc:status('running', payload)
	end

	local function store_record(rec)
		counts.logs = counts.logs + 1
		local appended = ring_append(ring, rec, ring_max)
		if appended then counts.stored = counts.stored + 1 else counts.dropped = counts.dropped + 1 end
		local age = rec.mono - start_mono
		if age <= boot_window_s and #boot < boot_max then boot[#boot + 1] = rec end
	end

	local function maybe_summary()
		local now = (runtime.now and runtime.now()) or 0
		if summary_period_s <= 0 or now - last_summary < summary_period_s then return end
		last_summary = now
		if counts.suppressed > 0 or counts.dropped > 0 then
			write_line(string.format('%s  STA  %-10s %-12s  suppressed=%d dropped=%d stored=%d',
				fmt_time(now), name, 'summary', counts.suppressed, counts.dropped, #ring))
		end
		publish_status()
	end

	local canonical_sub = conn:subscribe({ 'obs', OBS_VER, '#' }, { queue_len = 500, full = 'drop_oldest' })
	local legacy_sub = conn:subscribe({ 'obs', '#' }, { queue_len = 200, full = 'drop_oldest' })
	local canonical_topic = 'obs/' .. OBS_VER .. '/#'
	publish_status({ subscribed = canonical_topic, boot_window_s = boot_window_s })

	write_line(string.format('%s  STA  %-10s %-12s  profile=%s min_level=%s subscribed=%s',
		fmt_time(start_mono), name, 'start', profile, min_level, canonical_topic))

	local canonical_seen = {}
	local legacy_count = {}
	local LEGACY_WARN_THRESHOLD = 2
	local legacy_to_canonical_kind = { log = 'event', event = 'event', state = 'metric' }

	while true do
		local which, msg, err = perform(named_choice { canonical = canonical_sub:recv_op(), legacy = legacy_sub:recv_op() })
		maybe_summary()
		if which == 'canonical' then
			if msg == nil then
				write_line(string.format('%s  STA  %-10s %-12s  canonical subscription ended: %s', fmt_time(), name, 'stop', tostring(err or 'closed')))
				break
			end
			counts.received = counts.received + 1
			local svc_name, can_kind = msg.topic[3], msg.topic[4]
			if type(svc_name) == 'string' and type(can_kind) == 'string' then
				canonical_seen[svc_name] = canonical_seen[svc_name] or {}
				canonical_seen[svc_name][can_kind] = true
			end
			local rec = normalise_log_record(msg, 'canonical')
			if rec then
				store_record(rec)
				if raw or level_enabled(rec.level, min_level) then
					write_line(format_log_line(rec))
					counts.printed = counts.printed + 1
				else counts.suppressed = counts.suppressed + 1 end
			elseif raw then
				write_line(format_canonical_line(msg)); counts.printed = counts.printed + 1
			else counts.suppressed = counts.suppressed + 1 end
		elseif which == 'legacy' then
			if msg == nil then
				write_line(string.format('%s  STA  %-10s %-12s  legacy subscription ended: %s', fmt_time(), name, 'stop', tostring(err or 'closed')))
				break
			end
			counts.received = counts.received + 1
			local topic = msg.topic or {}
			local kind, svc_name = topic[2], topic[3]
			if kind ~= OBS_VER then
				local rec = normalise_log_record(msg, 'legacy')
				-- service_base dual-publishes legacy and canonical logs.  Operator/debug
				-- profiles therefore ignore legacy log payloads to avoid duplicate lines;
				-- raw mode keeps the old firehose behaviour.
				if rec then
					-- Legacy logs are expected to be dual-published by service_base.  Do
					-- not display or store them here, otherwise operator/debug/raw modes
					-- double-count the same line.  Legacy-only diagnostics are handled
					-- below when explicitly enabled.
					counts.suppressed = counts.suppressed + 1
				elseif legacy_detect then
					if legacy_to_canonical_kind[kind] then
						local can_kind = legacy_to_canonical_kind[kind]
						local svc_seen = canonical_seen[svc_name]
						if not (svc_seen and svc_seen[can_kind]) then
							legacy_count[svc_name] = legacy_count[svc_name] or {}
							local count = (legacy_count[svc_name][kind] or 0) + 1
							legacy_count[svc_name][kind] = count
							if count >= LEGACY_WARN_THRESHOLD then write_line(format_legacy_warn(msg, 'legacy-only')) end
						end
					else write_line(format_legacy_warn(msg, 'unknown-endpoint')) end
				else counts.suppressed = counts.suppressed + 1 end
			end
		end
	end
end

return M
