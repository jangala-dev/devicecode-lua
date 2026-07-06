-- services/monitor.lua
--
-- Monitor service:
--   * operator mode subscribes to observability but prints structured logs only
--   * keeps a boot buffer and rolling in-memory ring of normalised log records
--   * raw mode preserves the previous firehose behaviour for development
--   * legacy obs-plane detection is retained, but no longer pollutes operator mode

local OBS_VER = 'v1'

local DEFAULT_BOOT_RECORDS = 200
local DEFAULT_RING_RECORDS = 50
-- A value <= 0 means 'capture the first DEFAULT_BOOT_RECORDS records regardless of elapsed time'.
local DEFAULT_BOOT_WINDOW_S = 0

local fibers  = require 'fibers'
local runtime = require 'fibers.runtime'
local file    = require 'fibers.io.file'
local sleep   = require 'fibers.sleep'
local mailbox = require 'fibers.mailbox'

local queue       = require 'devicecode.support.queue'
local bus_cleanup  = require 'devicecode.support.bus_cleanup'
local config_watch = require 'devicecode.support.config_watch'

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

local function first_num(default, ...)
	for i = 1, select('#', ...) do
		local v = select(i, ...)
		local n = tonumber(v)
		if n ~= nil then return n end
	end
	return default
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

local function monitor_cap_topic(id)
	return { 'cap', 'monitor', id or 'main' }
end

local function monitor_rpc_topic(method, id)
	return { 'cap', 'monitor', id or 'main', 'rpc', method }
end

local function monitor_state_topic(name)
	return { 'state', 'monitor', name }
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


local function shallow_copy_record_payload(payload)
	if type(payload) ~= 'table' then return payload end
	local out = {}
	for k, v in pairs(payload) do out[k] = v end
	return out
end

local function serialise_record(rec)
	if type(rec) ~= 'table' then return rec end
	return {
		id = rec.id,
		mono = rec.mono,
		wall = rec.wall,
		service = rec.service,
		level = rec.level,
		what = rec.what,
		summary = rec.summary or summarise_log_payload(rec.payload),
		payload = shallow_copy_record_payload(rec.payload),
		topic = topic_to_string(rec.topic),
		plane = rec.plane,
	}
end

local function record_matches(rec, filter)
	filter = filter or {}
	if filter.min_level and not level_enabled(rec.level, filter.min_level) then return false end
	if filter.service and tostring(filter.service) ~= '' and tostring(rec.service) ~= tostring(filter.service) then return false end
	if filter.since_id and tonumber(rec.id or 0) <= tonumber(filter.since_id) then return false end
	local contains = filter.contains or filter.q
	if contains and tostring(contains) ~= '' then
		local hay = table.concat({ tostring(rec.service or ''), tostring(rec.level or ''), tostring(rec.what or ''), tostring(rec.summary or ''), summarise_log_payload(rec.payload) }, ' '):lower()
		if not hay:find(tostring(contains):lower(), 1, true) then return false end
	end
	return true
end


local function inc_count(t, key, n)
	key = tostring(key or 'unknown')
	t[key] = (t[key] or 0) + (n or 1)
end

local function top_counts(t, max_items)
	local items = {}
	for k, v in pairs(t or {}) do items[#items + 1] = { k = k, v = v } end
	table.sort(items, function(a, b)
		if a.v ~= b.v then return a.v > b.v end
		return tostring(a.k) < tostring(b.k)
	end)
	local out = {}
	for i = 1, math.min(max_items or 5, #items) do
		out[#out + 1] = tostring(items[i].k) .. '=' .. tostring(items[i].v)
	end
	return (#out > 0) and table.concat(out, ' ') or '-'
end

local function new_period_counts()
	return {
		received = 0,
		logs = 0,
		stored = 0,
		printed = 0,
		dropped = 0,
		suppressed = 0,
		suppressed_by_category = {},
		suppressed_by_service = {},
		received_by_category = {},
		received_by_service = {},
	}
end

local function log_category(level)
	level = norm_level(level)
	return 'log_' .. level
end

local function ring_append(buf, rec, max_records)
	if max_records <= 0 then return false, 0 end
	buf[#buf + 1] = rec
	local evicted = 0
	while #buf > max_records do
		table.remove(buf, 1)
		evicted = evicted + 1
	end
	return true, evicted
end

local function trim_first_records(buf, max_records)
	if max_records <= 0 then
		local n = #buf
		for i = n, 1, -1 do buf[i] = nil end
		return n
	end
	local removed = 0
	while #buf > max_records do
		table.remove(buf)
		removed = removed + 1
	end
	return removed
end

local function trim_latest_records(buf, max_records)
	if max_records <= 0 then
		local n = #buf
		for i = n, 1, -1 do buf[i] = nil end
		return n
	end
	local removed = 0
	while #buf > max_records do
		table.remove(buf, 1)
		removed = removed + 1
	end
	return removed
end

local function monitor_storage_cfg(raw)
	if type(raw) ~= 'table' then return nil end
	local cfg = raw.storage
	if type(cfg) ~= 'table' then return nil end
	return cfg
end

local function field_num(cfg, ...)
	if type(cfg) ~= 'table' then return nil end
	for i = 1, select('#', ...) do
		local k = select(i, ...)
		local n = tonumber(cfg[k])
		if n ~= nil then
			if n < 0 then n = 0 end
			return math.floor(n)
		end
	end
	return nil
end

local function storage_env_cfg(prefix)
	local cfg = {}
	local any = false
	local function set_num(field, suffix)
		local n = tonumber(env(prefix .. suffix, nil))
		if n ~= nil then
			if n < 0 then n = 0 end
			cfg[field] = math.floor(n)
			any = true
		end
	end
	set_num('boot_records', '_BOOT_RECORDS')
	set_num('ring_records', '_RING_RECORDS')
	set_num('boot_seconds', '_BOOT_SECONDS')
	if any then return cfg end
	return nil
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
	-- Buffer sizing is deliberately not a service-start option. Defaults are
	-- compiled into monitor; DEVICECODE_INITIAL_MONITOR_* can override those
	-- earliest boot values before config is available. cfg/monitor may then set
	-- the normal configured values, and DEVICECODE_MONITOR_* can force an
	-- environment override over config for deployment/emergency use.
	local initial_storage = storage_env_cfg('DEVICECODE_INITIAL_MONITOR')
	local env_override_storage = storage_env_cfg('DEVICECODE_MONITOR')
	local boot_max = field_num(env_override_storage, 'boot_records')
		or field_num(initial_storage, 'boot_records')
		or DEFAULT_BOOT_RECORDS
	local ring_max = field_num(env_override_storage, 'ring_records')
		or field_num(initial_storage, 'ring_records')
		or DEFAULT_RING_RECORDS
	local boot_window_s = field_num(env_override_storage, 'boot_seconds')
		or field_num(initial_storage, 'boot_seconds')
		or DEFAULT_BOOT_WINDOW_S
	local storage_source = env_override_storage and 'env_override' or (initial_storage and 'initial_env' or 'default')

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
	local counts = { received = 0, logs = 0, stored = 0, printed = 0, dropped = 0, suppressed = 0, ring_evicted = 0 }
	local period = new_period_counts()
	local next_record_id = 0
	local followers = {}
	local next_follower_id = 0
	local last_summary_payload = nil

	local function public_summary(extra)
		local payload = {
			profile = profile,
			min_level = min_level,
			ring_records = #ring,
			ring_max_records = ring_max,
			boot_records = #boot,
			boot_max_records = boot_max,
			boot_window_s = boot_window_s,
			storage_source = storage_source,
			counts = counts,
			followers = 0,
			last_record_id = next_record_id,
		}
		local n_followers = 0
		for _ in pairs(followers) do n_followers = n_followers + 1 end
		payload.followers = n_followers
		if type(extra) == 'table' then for k, v in pairs(extra) do payload[k] = v end end
		last_summary_payload = payload
		return payload
	end

	local function retain_summary(extra)
		conn:retain(monitor_state_topic('summary'), public_summary(extra))
		conn:retain(monitor_cap_topic('main'), {
			kind = 'cap.monitor',
			class = 'monitor',
			id = 'main',
			owner = name,
			methods = { ['query-logs'] = true, ['follow-logs'] = true, ['set-profile'] = true },
			state = { summary = monitor_state_topic('summary') },
		})
		return last_summary_payload
	end

	local function query_records(payload)
		payload = type(payload) == 'table' and payload or {}
		local source = payload.boot and boot or ring
		local default_limit = payload.boot and boot_max or ring_max
		if default_limit <= 0 then default_limit = 50 end
		local limit = tonumber(payload.limit) or default_limit
		if limit < 0 then limit = 0 end
		if limit > 1000 then limit = 1000 end
		local filter = {
			min_level = payload.min_level,
			service = payload.service,
			since_id = payload.since_id,
			contains = payload.contains or payload.q,
		}
		local out = {}
		for i = #source, 1, -1 do
			local rec = source[i]
			if record_matches(rec, filter) then
				table.insert(out, 1, serialise_record(rec))
				if #out >= limit then break end
			end
		end
		return { ok = true, records = out, count = #out, last_record_id = next_record_id, summary = last_summary_payload or public_summary() }
	end

	local function make_feed(payload)
		payload = type(payload) == 'table' and payload or {}
		next_follower_id = next_follower_id + 1
		local tx, rx = mailbox.new(tonumber(payload.queue_len) or 128, { full = payload.full or 'drop_oldest' })
		local id = next_follower_id
		local feed = { _id = id, _tx = tx, _rx = rx, dropped = 0, closed = false }
		local filter = {
			min_level = payload.min_level,
			service = payload.service,
			since_id = payload.since_id,
			contains = payload.contains or payload.q,
		}
		function feed:recv_op() return self._rx:recv_op() end
		function feed:close(reason)
			if self.closed then return true end
			self.closed = true
			followers[id] = nil
			if self._tx and type(self._tx.close) == 'function' then self._tx:close(reason or 'monitor_follow_closed') end
			return true
		end
		followers[id] = { feed = feed, filter = filter }
		local replay = payload.replay ~= false
		if replay then
			local result = query_records({
				limit = payload.limit,
				boot = payload.boot,
				min_level = payload.min_level,
				service = payload.service,
				since_id = payload.since_id,
				contains = payload.contains or payload.q,
			})
			for _, rec in ipairs(result.records or {}) do
				local ok = queue.try_send_now(tx, { kind = 'log', replay = true, record = rec })
				if ok ~= true then feed.dropped = feed.dropped + 1 end
			end
		end
		queue.try_send_now(tx, { kind = 'ready', follower_id = id, last_record_id = next_record_id })
		return feed
	end

	local function publish_status(extra)
		local payload = {
			profile = profile,
			min_level = min_level,
			ring_records = #ring,
			ring_max_records = ring_max,
			boot_records = #boot,
			boot_max_records = boot_max,
			boot_window_s = boot_window_s,
			storage_source = storage_source,
			counts = counts,
		}
		if type(extra) == 'table' then for k, v in pairs(extra) do payload[k] = v end end
		retain_summary(extra)
		svc:status('running', payload)
	end

	local function apply_storage_config(raw, reason)
		local cfg = monitor_storage_cfg(raw)
		local override = storage_env_cfg('DEVICECODE_MONITOR')
		if not cfg and not override then return false end
		cfg = cfg or {}

		local new_boot = field_num(override, 'boot_records') or field_num(cfg, 'boot_records')
		local new_ring = field_num(override, 'ring_records') or field_num(cfg, 'ring_records')
		local new_window = field_num(override, 'boot_seconds') or field_num(cfg, 'boot_seconds')
		local new_source = override and 'env_override' or 'config'

		local changed = false
		if new_boot ~= nil and new_boot ~= boot_max then
			boot_max = new_boot
			trim_first_records(boot, boot_max)
			changed = true
		end
		if new_ring ~= nil and new_ring ~= ring_max then
			ring_max = new_ring
			local evicted = trim_latest_records(ring, ring_max)
			if evicted > 0 then counts.ring_evicted = counts.ring_evicted + evicted end
			changed = true
		end
		if new_window ~= nil and new_window ~= boot_window_s then
			boot_window_s = new_window
			changed = true
		end
		if storage_source ~= new_source then
			storage_source = new_source
			changed = true
		end

		if changed then
			publish_status({ storage_configured = true, storage_reason = reason or 'config_changed' })
			svc:info('monitor_storage_configured', {
				summary = string.format('monitor storage configured boot=%d ring=%d source=%s', boot_max, ring_max, storage_source),
				boot_records = boot_max,
				ring_records = ring_max,
				boot_seconds = boot_window_s,
				storage_source = storage_source,
				reason = reason or 'config_changed',
			})
		else
			svc:debug('monitor_storage_config_unchanged', {
				boot_records = boot_max,
				ring_records = ring_max,
				boot_seconds = boot_window_s,
				storage_source = storage_source,
				reason = reason or 'config_changed',
			})
		end
		return changed
	end

	local function store_record(rec)
		next_record_id = next_record_id + 1
		rec.id = next_record_id
		counts.logs = counts.logs + 1
		period.logs = period.logs + 1
		local appended, evicted = ring_append(ring, rec, ring_max)
		if appended then
			counts.stored = counts.stored + 1
			period.stored = period.stored + 1
			if evicted and evicted > 0 then counts.ring_evicted = counts.ring_evicted + evicted end
		else
			counts.dropped = counts.dropped + 1
			period.dropped = period.dropped + 1
		end
		local age = rec.mono - start_mono
		local capture_boot = boot_max > 0 and (boot_window_s <= 0 or age <= boot_window_s)
		if capture_boot and #boot < boot_max then boot[#boot + 1] = rec end
		local serialised = nil
		for id, follower in pairs(followers) do
			if record_matches(rec, follower.filter) then
				serialised = serialised or serialise_record(rec)
				local ok = queue.try_send_now(follower.feed._tx, { kind = 'log', replay = false, record = serialised })
				if ok ~= true then follower.feed.dropped = (follower.feed.dropped or 0) + 1 end
			end
		end
	end

	local function note_received(category, service)
		counts.received = counts.received + 1
		period.received = period.received + 1
		inc_count(period.received_by_category, category or 'unknown')
		inc_count(period.received_by_service, service or 'unknown')
	end

	local function note_printed()
		counts.printed = counts.printed + 1
		period.printed = period.printed + 1
	end

	local function note_suppressed(category, service)
		counts.suppressed = counts.suppressed + 1
		period.suppressed = period.suppressed + 1
		inc_count(period.suppressed_by_category, category or 'unknown')
		inc_count(period.suppressed_by_service, service or 'unknown')
	end

	local function maybe_summary()
		local now = (runtime.now and runtime.now()) or 0
		if summary_period_s <= 0 or now - last_summary < summary_period_s then return end
		local elapsed = now - last_summary
		last_summary = now
		if period.received > 0 or period.suppressed > 0 or period.dropped > 0 then
			write_line(string.format('%s  STA  %-10s %-12s  +%.0fs received=%d printed=%d stored=%d suppressed=%d dropped=%d',
				fmt_time(now), name, 'summary', elapsed, period.received, period.printed, period.stored, period.suppressed, period.dropped))
			if period.suppressed > 0 then
				write_line(string.format('%s  STA  %-10s %-12s  suppressed_by_category=%s suppressed_by_service=%s',
					fmt_time(now), name, 'summary', top_counts(period.suppressed_by_category, 6), top_counts(period.suppressed_by_service, 6)))
			end
		end
		period = new_period_counts()
		publish_status()
	end

	local endpoints = {}
	local function add_endpoint(label, method, opts)
		local ep, berr = bus_cleanup.bind(conn, monitor_rpc_topic(method, 'main'), opts or { queue_len = 32, full = 'reject_newest' })
		if not ep then error(berr or ('monitor endpoint bind failed: ' .. tostring(method)), 0) end
		endpoints[#endpoints + 1] = { label = label, method = method, ep = ep }
	end
	add_endpoint('rpc_query_logs', 'query-logs')
	add_endpoint('rpc_follow_logs', 'follow-logs')
	add_endpoint('rpc_set_profile', 'set-profile')

	local cfg_watch = nil
	if conn then
		local werr
		cfg_watch, werr = config_watch.open(conn, name, {
			queue_len = 4,
			full = 'reject_newest',
			changed_kind = 'monitor_config_changed',
			closed_kind = 'monitor_config_closed',
		})
		if not cfg_watch then error(werr or 'monitor config watch failed', 2) end
	end

	local subscriptions = {}
	local subscribed_topics = {}
	local function add_sub(label, plane, topic, opts)
		subscriptions[#subscriptions + 1] = {
			label = label,
			plane = plane,
			topic = topic,
			sub = conn:subscribe(topic, opts or { queue_len = 500, full = 'drop_oldest' }),
		}
		subscribed_topics[#subscribed_topics + 1] = topic_to_string(topic)
	end

	if raw then
		add_sub('canonical_raw', 'canonical', { 'obs', OBS_VER, '#' }, { queue_len = 500, full = 'drop_oldest' })
	else
		add_sub('canonical_event_log', 'canonical', { 'obs', OBS_VER, '+', 'event', 'log' }, { queue_len = 500, full = 'drop_oldest' })
		add_sub('canonical_direct_log', 'canonical', { 'obs', OBS_VER, '+', 'log', '#' }, { queue_len = 500, full = 'drop_oldest' })
	end
	if legacy_detect then
		add_sub('legacy', 'legacy', { 'obs', '#' }, { queue_len = 200, full = 'drop_oldest' })
	end

	local subscribed = table.concat(subscribed_topics, ',')
	publish_status({ subscribed = subscribed })

	write_line(string.format('%s  STA  %-10s %-12s  profile=%s min_level=%s subscribed=%s boot=%d ring=%d storage=%s',
		fmt_time(start_mono), name, 'start', profile, min_level, subscribed, boot_max, ring_max, storage_source))

	local canonical_seen = {}
	local legacy_count = {}
	local LEGACY_WARN_THRESHOLD = 2
	local legacy_to_canonical_kind = { log = 'event', event = 'event', state = 'metric' }

	while true do
		local choices = {}
		for i, entry in ipairs(subscriptions) do
			choices['sub:' .. entry.label] = entry.sub:recv_op():wrap(function(msg, err) return 'sub', i, msg, err end)
		end
		for i, entry in ipairs(endpoints) do
			choices['rpc:' .. entry.label] = entry.ep:recv_op():wrap(function(req, err) return 'rpc', i, req, err end)
		end
		if cfg_watch then
			choices['cfg:monitor'] = cfg_watch:recv_op():wrap(function(ev) return 'config', 0, ev, nil end)
		end
		local _, source, idx, msg, err = perform(named_choice(choices))
		maybe_summary()
			if source == 'config' then
				local ev = msg
				if type(ev) == 'table' and ev.kind == 'monitor_config_changed' then
					apply_storage_config(ev.raw, 'config_changed')
				elseif type(ev) == 'table' and ev.kind == 'monitor_config_closed' then
					svc:warn('monitor_config_watch_closed', { summary = 'monitor config watch closed', err = ev.err })
				end
			elseif source == 'rpc' then
				local endpoint = idx and endpoints[idx] or nil
				if not endpoint then
					write_line(string.format('%s  STA  %-10s %-12s  monitor rpc dispatch failed', fmt_time(), name, 'stop'))
					break
				end
				local req = msg
				if req == nil then
					write_line(string.format('%s  STA  %-10s %-12s  %s endpoint ended: %s', fmt_time(), name, 'stop', tostring(endpoint.label), tostring(err or 'closed')))
					break
				end
				local payload = type(req.payload) == 'table' and req.payload or {}
				if endpoint.method == 'query-logs' then
					req:reply(query_records(payload))
				elseif endpoint.method == 'follow-logs' then
					local feed = make_feed(payload)
					req:reply({ ok = true, feed = feed, follower_id = feed._id, summary = last_summary_payload or public_summary() })
				elseif endpoint.method == 'set-profile' then
					local requested_profile = payload.profile and tostring(payload.profile) or profile
					local requested_level = payload.min_level and norm_level(payload.min_level) or nil
					if requested_profile == 'raw' then
						req:reply({ ok = false, err = 'raw_profile_requires_restart', profile = profile, min_level = min_level })
					else
						local changed = false
						if requested_profile == 'operator' or requested_profile == 'debug' or requested_profile == 'trace' then
							profile = requested_profile
							min_level = requested_level or (profile == 'debug' and 'debug' or profile == 'trace' and 'trace' or 'info')
							changed = true
						elseif requested_level then
							min_level = requested_level
							changed = true
						end
						if changed then
							publish_status({ profile_changed = true })
							svc:info('monitor_profile_changed', { summary = string.format('monitor profile changed profile=%s min_level=%s', tostring(profile), tostring(min_level)), profile = profile, min_level = min_level })
							req:reply({ ok = true, profile = profile, min_level = min_level })
						else
							req:reply({ ok = false, err = 'invalid_profile', profile = profile, min_level = min_level })
						end
					end
				else
					req:reply({ ok = false, err = 'unknown_monitor_method', method = endpoint.method })
				end
			else
				local entry = idx and subscriptions[idx] or nil
				if not entry then
					write_line(string.format('%s  STA  %-10s %-12s  monitor subscription dispatch failed', fmt_time(), name, 'stop'))
					break
				end
				if msg == nil then
					write_line(string.format('%s  STA  %-10s %-12s  %s subscription ended: %s',
						fmt_time(), name, 'stop', tostring(entry.label), tostring(err or 'closed')))
					break
				end

				if entry.plane == 'canonical' then
					local kind, svc_name, lvl_or_name = classify_canonical(msg)
					note_received(kind == 'log' and log_category(lvl_or_name) or kind, svc_name)
					if type(svc_name) == 'string' and type(kind) == 'string' then
						canonical_seen[svc_name] = canonical_seen[svc_name] or {}
						canonical_seen[svc_name][kind] = true
					end
					local rec = normalise_log_record(msg, 'canonical')
					if rec then
						store_record(rec)
						if raw or level_enabled(rec.level, min_level) then
							write_line(format_log_line(rec))
							note_printed()
						else
							note_suppressed(log_category(rec.level), rec.service)
						end
					elseif raw then
						write_line(format_canonical_line(msg))
						note_printed()
					else
						note_suppressed(kind or 'obs', svc_name)
					end
				elseif entry.plane == 'legacy' then
					local topic = msg.topic or {}
					local kind, svc_name = topic[2], topic[3]
					note_received(kind == 'log' and 'legacy_log' or ('legacy_' .. tostring(kind or 'obs')), svc_name)
					if kind ~= OBS_VER then
						local rec = normalise_log_record(msg, 'legacy')
						-- service_base dual-publishes legacy and canonical logs.  Operator/debug
						-- profiles therefore ignore legacy log payloads to avoid duplicate lines;
						-- raw mode keeps the old firehose behaviour.
						if rec then
							if raw then
								write_line(format_log_line(rec))
								note_printed()
							else
								note_suppressed('legacy_log', rec.service)
							end
						elseif legacy_detect then
							if legacy_to_canonical_kind[kind] then
								local can_kind = legacy_to_canonical_kind[kind]
								local svc_seen = canonical_seen[svc_name]
								if not (svc_seen and svc_seen[can_kind]) then
									legacy_count[svc_name] = legacy_count[svc_name] or {}
									local count = (legacy_count[svc_name][kind] or 0) + 1
									legacy_count[svc_name][kind] = count
									if count >= LEGACY_WARN_THRESHOLD then
										write_line(format_legacy_warn(msg, 'legacy-only'))
										note_printed()
									else
										note_suppressed('legacy_probe', svc_name)
									end
								else
									note_suppressed('legacy_duplicate', svc_name)
								end
							else
								write_line(format_legacy_warn(msg, 'unknown-endpoint'))
								note_printed()
							end
						else
							note_suppressed('legacy_' .. tostring(kind or 'obs'), svc_name)
						end
					end
				end
			end
	end
end

return M
