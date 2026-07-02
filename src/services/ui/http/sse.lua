-- services/ui/http/sse.lua
--
-- Server-sent-event response owner for UI read-model watches.
--
-- SSE is request-owned streaming HTTP work.  It observes the local UI read-model
-- watch owner and writes framed events through the response owner.  It does not
-- subscribe to retained bus state directly and it does not know about the HTTP
-- backend implementation.

local fibers   = require 'fibers'
local resource = require 'devicecode.support.resource'
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
	return local_model.allowed(ev.topic)
end

local function project_event(ev)
	if type(ev) ~= 'table' or ev.topic == nil then return ev end
	return local_model.project_event(ev)
end

function M.run(scope, owner, route, opts)
	opts = opts or {}
	local watch_owner = assert(opts.watch_owner, 'SSE requires watch_owner')
	local encode = opts.encode_json or opts.encode or default_encode
	local pattern = route.pattern or (opts.sse and opts.sse.pattern) or { '#' }
	local replay = (opts.sse and opts.sse.replay == true) or false
	local watch, err = watch_owner:watch_open(pattern, {
		replay = replay,
		queue_len = (opts.sse and opts.sse.queue_len) or 32,
		full = 'drop_oldest',
		max_replay = opts.sse and opts.sse.max_replay,
	})
	if not watch then
		perform_required(owner:reply_error_op(503, err or 'watch_open_failed'), 'SSE watch-open error response failed')
		return { status = 'failed', err = err or 'watch_open_failed' }
	end

	local watch_res = resource.owned(watch, { label = 'SSE watch cleanup' })
	scope:finally(function (_, status, primary)
		watch_res:terminate_checked(primary or status or 'sse_closed', 'SSE watch cleanup')
	end)

	perform_required(owner:write_headers_op(200, {
		['content-type'] = 'text/event-stream',
		['cache-control'] = 'no-cache',
		['connection'] = 'keep-alive',
	}), 'SSE headers write failed')

	while true do
		local ev, rerr = fibers.perform(watch:recv_op())
		if ev == nil then
			return { status = 'closed', err = rerr }
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
return M
