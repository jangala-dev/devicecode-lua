-- services/monitor.lua
--
-- Monitor service:
--   * subscribes to obs/# and prints messages
--   * bounded, drop-oldest

local fibers  = require 'fibers'
local runtime = require 'fibers.runtime'
local file    = require 'fibers.io.file'
local sleep   = require 'fibers.sleep'

local perform      = fibers.perform
local named_choice = fibers.named_choice

local base = require 'devicecode.service_base'

local M = {}

-- pretty printer kept as-is (it is purely a dev/operator tool)

local function is_array(t)
	local n = 0
	for _ in ipairs(t) do n = n + 1 end
	for k in pairs(t) do
		if type(k) ~= 'number' or k < 1 or k % 1 ~= 0 or k > n then
			return false
		end
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

local function classify(msg)
	local t = msg.topic or {}
	local kind = t[3]
	if kind == 'log' then
		return 'log', t[4] or 'unknown', t[5] or 'info'
	elseif kind == 'metric' then
		return 'metric', t[4] or 'unknown', nil
	elseif kind == 'event' then
		return 'event', t[4] or 'unknown', t[5] or 'event'
	elseif kind == 'state' then
		return 'state', t[4] or 'unknown', t[5] or 'state'
	end
	return 'obs', t[3] or 'unknown', nil
end

local function format_line(msg)
	local kind, svc, lvl_or_name = classify(msg)

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

	if kind == 'state' then
		return string.format('%s  STA  %-10s %-12s  %s',
			fmt_time(), tostring(svc), tostring(lvl_or_name or 'state'), payload_s)
	end

	return string.format('%s  OBS  %-10s %-24s  %s',
		fmt_time(), tostring(svc), topic_to_string(msg.topic), payload_s)
end

function M.start(conn, ctx)
	ctx = ctx or {}
	local svc = base.new(conn, { name = ctx.name or 'monitor', env = ctx.env })
	local name = svc.name

	local out = file.fdopen(1, 'w', 'stdout')
	out:setvbuf('line')

	local function write_line(line)
		local which, a, b = perform(named_choice {
			wrote = out:write_op(line, '\n'),
			timeout = sleep.sleep_op(0.5):wrap(function () return nil, 'write timeout' end),
		})
		if which == 'wrote' then
			local n, err = a, b
			if n == nil and err ~= nil then error(err) end
		end
	end

	svc:status('running', { subscribed = 'obs/#' })

	local sub = conn:subscribe({ 'obs', '#' }, { queue_len = 500, full = 'drop_oldest' })

	write_line(string.format('%s  STA  %-10s %-12s  %s',
		fmt_time(), name, 'start', 'subscribed to obs/#'))

	for msg in sub:iter() do
		write_line(format_line(msg))
	end

	local why = tostring(sub:why() or 'closed')
	write_line(string.format('%s  STA  %-10s %-12s  %s',
		fmt_time(), name, 'stop', 'subscription ended: ' .. why))
end

return M
