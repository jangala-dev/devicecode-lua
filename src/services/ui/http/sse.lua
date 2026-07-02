-- services/ui/http/sse.lua
--
-- Server-sent-event response owner for UI read-model watches.
--
-- SSE is request-owned streaming HTTP work.  It observes the local UI read-model
-- watch owner and writes framed events through the response owner.  It does not
-- subscribe to retained bus state directly and it does not know about the HTTP
-- backend implementation.

local fibers   = require 'fibers'
local local_model = require 'services.ui.local_model'

local M = {}

local function default_encode(v)
	local tv = type(v)
	if tv == 'nil' then return 'null' end
	if tv == 'boolean' or tv == 'number' then return tostring(v) end
	if tv == 'string' then return string.format('%q', v) end
	if tv == 'table' then
		local parts = {}
		local is_array = true
		local n = 0
		for k in pairs(v) do
			if type(k) ~= 'number' or k < 1 or k % 1 ~= 0 then is_array = false end
			if type(k) == 'number' and k > n then n = k end
		end
		if is_array then
			for i = 1, n do parts[#parts + 1] = default_encode(v[i]) end
			return '[' .. table.concat(parts, ',') .. ']'
		end
		for k, vv in pairs(v) do parts[#parts + 1] = default_encode(tostring(k)) .. ':' .. default_encode(vv) end
		return '{' .. table.concat(parts, ',') .. '}'
	end
	return default_encode(tostring(v))
end

local function perform_required(ev, label)
	local ok, err = fibers.perform(ev)
	if ok ~= true then error(err or label or 'sse write failed', 0) end
	return true
end

local function topic_to_string(topic)
	local parts = {}
	for i = 1, #(topic or {}) do parts[i] = tostring(topic[i]) end
	return table.concat(parts, '/')
end

local function copy_topic(topic)
	local out = {}
	for i = 1, #(topic or {}) do out[i] = topic[i] end
	return out
end

local function pattern_from_prefix(prefix)
	local out = copy_topic(prefix)
	out[#out + 1] = '#'
	return out
end

local function copy_patterns(patterns)
	local out = {}
	for i, pattern in ipairs(patterns or {}) do out[i] = copy_topic(pattern) end
	return out
end

local function default_patterns()
	local out = {}
	for _, prefix in ipairs(local_model.ALLOW_PREFIXES or {}) do
		if #prefix > 0 then out[#out + 1] = pattern_from_prefix(prefix) end
	end
	for _, pattern in ipairs(local_model.LIVE_EVENT_PATTERNS or {}) do
		if #pattern > 0 then out[#out + 1] = copy_topic(pattern) end
	end
	return out
end

local function patterns_for(route, opts)
	route = route or {}
	opts = opts or {}
	local sse_cfg = opts.sse or {}
	if route.pattern then return { copy_topic(route.pattern) } end
	if route.patterns then return copy_patterns(route.patterns) end
	if sse_cfg.pattern then return { copy_topic(sse_cfg.pattern) } end
	if sse_cfg.patterns then return copy_patterns(sse_cfg.patterns) end
	return default_patterns()
end

local function frame_event(ev, encode)
	local name = (ev and ev.op) or (ev and ev.kind) or 'message'
	local data = encode(ev or {})
	local id = ev and ev.topic and topic_to_string(ev.topic) or nil
	local out = {}
	if id and id ~= '' then out[#out + 1] = 'id: ' .. id .. '\n' end
	out[#out + 1] = 'event: ' .. tostring(name) .. '\n'
	data = tostring(data)
	if data == '' then
		out[#out + 1] = 'data: \n'
	else
		local start = 1
		while start <= #data do
			local nl = data:find('\n', start, true)
			local line
			if nl then
				line = data:sub(start, nl - 1)
				start = nl + 1
			else
				line = data:sub(start)
				start = #data + 1
			end
			out[#out + 1] = 'data: ' .. line .. '\n'
		end
	end
	out[#out + 1] = '\n'
	return table.concat(out)
end

local function event_allowed(ev)
	if type(ev) ~= 'table' or ev.topic == nil then return true end
	return local_model.allowed_event(ev.topic)
end

local function project_event(ev)
	if type(ev) ~= 'table' or ev.topic == nil then return ev end
	return local_model.project_event(ev)
end

local function terminate_watches(watches, reason)
	for i = #watches, 1, -1 do
		local watch = watches[i]
		if watch and type(watch.terminate) == 'function' then
			pcall(function () watch:terminate(reason or 'sse_closed') end)
		end
	end
end

local function open_watches(watch_owner, patterns, opts)
	local watches = {}
	for _, pattern in ipairs(patterns) do
		local watch, err = watch_owner:watch_open(pattern, opts)
		if not watch then
			terminate_watches(watches, err or 'watch_open_failed')
			return nil, err or 'watch_open_failed'
		end
		watches[#watches + 1] = watch
	end
	return watches, nil
end

local function next_event_op(watches)
	local ops = {}
	for i, watch in ipairs(watches) do
		ops[i] = watch:recv_op()
	end
	return fibers.first_ready(ops)
end

function M.run(scope, owner, route, opts)
	opts = opts or {}
	local watch_owner = assert(opts.watch_owner, 'SSE requires watch_owner')
	local encode = opts.encode_json or opts.encode or default_encode
	local patterns = patterns_for(route, opts)
	local replay = (opts.sse and opts.sse.replay == true) or false
	if #patterns == 0 then
		perform_required(owner:reply_error_op(503, 'no_sse_patterns'), 'SSE no-patterns error response failed')
		return { status = 'failed', err = 'no_sse_patterns' }
	end

	local watch_opts = {
		replay = replay,
		queue_len = (opts.sse and opts.sse.queue_len) or 32,
		full = 'drop_oldest',
		max_replay = opts.sse and opts.sse.max_replay,
	}
	local watches, err = open_watches(watch_owner, patterns, watch_opts)
	if not watches then
		perform_required(owner:reply_error_op(503, err or 'watch_open_failed'), 'SSE watch-open error response failed')
		return { status = 'failed', err = err or 'watch_open_failed' }
	end

	scope:finally(function (_, status, primary)
		terminate_watches(watches, primary or status or 'sse_closed')
	end)

	perform_required(owner:write_headers_op(200, {
		['content-type'] = 'text/event-stream',
		['cache-control'] = 'no-cache',
		['connection'] = 'keep-alive',
	}), 'SSE headers write failed')

	while true do
		local idx, ev, rerr = fibers.perform(next_event_op(watches))
		if ev == nil then
			terminate_watches(watches, rerr or 'sse_watch_closed')
			return { status = 'closed', err = rerr, pattern = patterns[idx] }
		end
		local projected = project_event(ev)
		if projected then
			perform_required(owner:write_chunk_op(frame_event(projected, encode)), 'SSE event write failed')
		end
	end
end

M.frame_event = frame_event
M.event_allowed = event_allowed
M.project_event = project_event
M.default_patterns = default_patterns
M.patterns_for = patterns_for
return M
