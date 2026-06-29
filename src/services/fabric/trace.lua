-- services/fabric/trace.lua
--
-- Lightweight opt-in Fabric wire/event tracing.  Disabled unless
-- DEVICECODE_FABRIC_TRACE or FABRIC_TRACE is set to a truthy value.
-- Trace events are published through the Fabric state projector to:
--   obs/event/fabric/wire
--   obs/v1/fabric/event/wire
-- Payloads intentionally exclude frame bodies unless preview is explicitly on.

local fibers = require 'fibers'

local M = {}

local function truthy(v)
	if v == nil or v == '' then return false end
	v = tostring(v):lower()
	return not (v == '0' or v == 'false' or v == 'no' or v == 'off')
end

local function split_set(v)
	local out = {}
	if type(v) ~= 'string' or v == '' then return out end
	for token in v:gmatch('[^,%s]+') do out[token] = true end
	return out
end

M.enabled = truthy(os.getenv('DEVICECODE_FABRIC_TRACE') or os.getenv('FABRIC_TRACE'))
M.preview_enabled = truthy(os.getenv('DEVICECODE_FABRIC_TRACE_PREVIEW') or os.getenv('FABRIC_TRACE_PREVIEW'))
M.types = split_set(os.getenv('DEVICECODE_FABRIC_TRACE_TYPES') or os.getenv('FABRIC_TRACE_TYPES'))

local function type_allowed(frame_type)
	if not M.enabled then return false end
	if next(M.types) == nil then return true end
	return M.types[frame_type or ''] == true or M.types['*'] == true or M.types.all == true
end

local function topic_path(topic)
	if type(topic) ~= 'table' then return nil end
	local out = {}
	for i, v in ipairs(topic) do out[i] = tostring(v) end
	return table.concat(out, '/')
end

local function preview(frame)
	if not M.preview_enabled then return nil end
	local ok, cjson = pcall(require, 'cjson.safe')
	if not ok then return nil end
	local s = cjson.encode(frame)
	if type(s) ~= 'string' then return nil end
	if #s > 240 then s = s:sub(1, 240) .. '...' end
	return s
end

local function frame_summary(frame)
	local f = type(frame) == 'table' and frame or {}
	local t = f.type
	return {
		frame_type = t,
		sid = f.sid,
		node = f.node,
		xfer_id = f.xfer_id,
		offset = f.offset,
		next = f.next,
		size = f.size,
		target = f.target,
		call_id = f.id,
		ok = f.ok,
		err = f.err,
		topic = topic_path(f.topic),
		data_len = type(f.data) == 'string' and #f.data or nil,
		chunk_digest = f.chunk_digest,
		preview = preview(frame),
	}
end

local function emit(state_tx, payload)
	if state_tx == nil then return true, nil end
	local ok, state_mod = pcall(require, 'services.fabric.state')
	if not ok then return nil, state_mod end
	return state_mod.admit_wire_trace_now(state_tx, payload, 'fabric_trace_admit_failed')
end

function M.frame(state_tx, base, direction, frame, extra)
	local t = type(frame) == 'table' and frame.type or nil
	if not type_allowed(t) then return true, nil end
	local payload = {
		direction = direction,
		component = base and base.component,
		link_id = base and base.link_id,
		link_generation = base and base.link_generation,
		lane = extra and extra.lane,
		ts = fibers.now(),
	}
	local s = frame_summary(frame)
	for k, v in pairs(s) do payload[k] = v end
	for k, v in pairs(extra or {}) do payload[k] = v end
	return emit(state_tx, payload)
end

function M.error(state_tx, base, direction, err, extra)
	if not M.enabled then return true, nil end
	local payload = {
		direction = direction,
		component = base and base.component,
		link_id = base and base.link_id,
		link_generation = base and base.link_generation,
		err = tostring(err or 'unknown'),
		event = extra and extra.event or 'wire_error',
		ts = fibers.now(),
	}
	for k, v in pairs(extra or {}) do payload[k] = v end
	return emit(state_tx, payload)
end

return M
