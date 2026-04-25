-- services/fabric/protocol.lua
--
-- Line-oriented protocol helpers for the fabric link.
--
-- Responsibilities:
--   * validate wire shape only
--   * encode/decode JSON lines
--   * classify frames into writer priority classes
--   * dispatch validated frames to their in-process owner lanes
--   * encode/decode bulk chunk payloads for transport-safe transfer
--
-- This module does not interpret session semantics or service policy.

local cjson  = require 'cjson.safe'
local b64url = require 'shared.encoding.b64url'

local M = {}

-- Writer priority class (used by writer.lua).
local FRAME_CLASS = {
	hello = 'control',
	hello_ack = 'control',
	ping = 'control',
	pong = 'control',
	xfer_begin = 'control',
	xfer_ready = 'control',
	xfer_need = 'control',
	xfer_commit = 'control',
	xfer_done = 'control',
	xfer_abort = 'control',

	pub = 'rpc',
	unretain = 'rpc',
	call = 'rpc',
	reply = 'rpc',

	xfer_chunk = 'bulk',
}

-- In-process owner lane (used by reader.lua).
local FRAME_LANE = {
	hello = 'session_control',
	hello_ack = 'session_control',
	ping = 'session_control',
	pong = 'session_control',

	xfer_begin = 'transfer',
	xfer_ready = 'transfer',
	xfer_need = 'transfer',
	xfer_commit = 'transfer',
	xfer_done = 'transfer',
	xfer_abort = 'transfer',
	xfer_chunk = 'transfer',

	pub = 'rpc',
	unretain = 'rpc',
	call = 'rpc',
	reply = 'rpc',
}

local function topic_ok(topic)
	if type(topic) ~= 'table' then return false end
	for i = 1, #topic do
		local tv = type(topic[i])
		if tv ~= 'string' and tv ~= 'number' then
			return false
		end
	end
	return true
end

local function frame_type_ok(frame)
	return type(frame) == 'table'
		and type(frame.type) == 'string'
		and frame.type ~= ''
end

local function require_xfer_id(frame)
	return type(frame.xfer_id) == 'string' and frame.xfer_id ~= ''
end

local function require_nonneg_number(v)
	return type(v) == 'number' and v >= 0
end

local function validate_control(frame)
	local t = frame.type

	if t == 'hello' or t == 'hello_ack' then
		if type(frame.sid) ~= 'string' or frame.sid == '' then
			return nil, 'missing_sid'
		end
	end

	if t == 'ping' or t == 'pong' then
		if frame.sid ~= nil and type(frame.sid) ~= 'string' then
			return nil, 'invalid_sid'
		end
	end

	if t == 'xfer_begin' then
		if not require_xfer_id(frame) then
			return nil, 'missing_xfer_id'
		end
		if not require_nonneg_number(frame.size) then
			return nil, 'invalid_xfer_size'
		end
		if type(frame.checksum) ~= 'string' or frame.checksum == '' then
			return nil, 'invalid_xfer_checksum'
		end
	end

	if t == 'xfer_ready' then
		if not require_xfer_id(frame) then
			return nil, 'missing_xfer_id'
		end
	end

	if t == 'xfer_need' then
		if not require_xfer_id(frame) then
			return nil, 'missing_xfer_id'
		end
		if not require_nonneg_number(frame.next) then
			return nil, 'invalid_next'
		end
	end

	if t == 'xfer_commit' then
		if not require_xfer_id(frame) then
			return nil, 'missing_xfer_id'
		end
		if not require_nonneg_number(frame.size) then
			return nil, 'invalid_xfer_size'
		end
		if type(frame.checksum) ~= 'string' or frame.checksum == '' then
			return nil, 'invalid_xfer_checksum'
		end
	end

	if t == 'xfer_done' then
		if not require_xfer_id(frame) then
			return nil, 'missing_xfer_id'
		end
	end

	if t == 'xfer_abort' then
		if not require_xfer_id(frame) then
			return nil, 'missing_xfer_id'
		end
		if frame.err ~= nil and type(frame.err) ~= 'string' then
			return nil, 'invalid_xfer_err'
		end
	end

	if t == 'xfer_chunk' then
		return nil, 'xfer_chunk_not_control'
	end

	return frame, nil
end

local function validate_rpc(frame)
	local t = frame.type

	if t == 'pub' then
		if not topic_ok(frame.topic) then
			return nil, 'invalid_topic'
		end
		if type(frame.retain) ~= 'boolean' then
			return nil, 'missing_retain'
		end
	elseif t == 'unretain' then
		if not topic_ok(frame.topic) then
			return nil, 'invalid_topic'
		end
	elseif t == 'call' then
		if type(frame.id) ~= 'string' or frame.id == '' then
			return nil, 'missing_id'
		end
		if not topic_ok(frame.topic) then
			return nil, 'invalid_topic'
		end
	elseif t == 'reply' then
		if type(frame.id) ~= 'string' or frame.id == '' then
			return nil, 'missing_id'
		end
		if type(frame.ok) ~= 'boolean' then
			return nil, 'missing_ok'
		end
	end

	return frame, nil
end

local function validate_bulk(frame)
	if not require_xfer_id(frame) then
		return nil, 'missing_xfer_id'
	end
	if not require_nonneg_number(frame.offset) then
		return nil, 'invalid_offset'
	end
	if type(frame.data) ~= 'string' then
		return nil, 'invalid_chunk_data'
	end
	return frame, nil
end

local function validate(frame)
	if not frame_type_ok(frame) then
		return nil, 'invalid_frame_type'
	end

	local class = FRAME_CLASS[frame.type]
	if class == 'control' then
		return validate_control(frame)
	end
	if class == 'rpc' then
		return validate_rpc(frame)
	end
	if class == 'bulk' then
		return validate_bulk(frame)
	end
	return nil, 'unknown_frame_type'
end

function M.validate(frame)
	return validate(frame)
end

function M.classify(frame)
	return frame and FRAME_CLASS[frame.type] or nil
end

function M.dispatch_lane(frame)
	return frame and FRAME_LANE[frame.type] or nil
end

function M.encode_line(frame)
	local ok, err = validate(frame)
	if not ok then
		return nil, err
	end

	local line, jerr = cjson.encode(frame)
	if not line then
		return nil, 'encode_failed: ' .. tostring(jerr)
	end

	return line, nil
end

function M.decode_line(line)
	if type(line) ~= 'string' then
		return nil, 'line_must_be_string'
	end

	local frame, err = cjson.decode(line)
	if not frame then
		return nil, 'decode_failed: ' .. tostring(err)
	end

	return validate(frame)
end

function M.writer_item(class, frame)
	assert(class == 'control' or class == 'rpc' or class == 'bulk', 'invalid writer class')

	local line, err = M.encode_line(frame)
	if not line then
		return nil, err
	end

	return {
		class = class,
		frame = frame,
		cost = #line,
		line = line,
	}, nil
end

----------------------------------------------------------------------
-- Bulk chunk helpers
----------------------------------------------------------------------

-- Encode raw binary chunk data into the transport-safe wire representation.
---@param raw string
---@return string|nil encoded
---@return string|nil err
function M.encode_chunk_data(raw)
	if type(raw) ~= 'string' then
		return nil, 'chunk_data_must_be_string'
	end
	return b64url.encode(raw), nil
end

-- Decode transport-safe wire chunk data back into raw binary bytes.
---@param encoded string
---@return string|nil raw
---@return string|nil err
function M.decode_chunk_data(encoded)
	if type(encoded) ~= 'string' then
		return nil, 'chunk_data_must_be_string'
	end
	return b64url.decode(encoded)
end

-- Build a validated xfer_chunk frame from raw binary bytes.
---@param xfer_id string
---@param offset integer
---@param raw string
---@return table|nil frame
---@return string|nil err
function M.make_xfer_chunk(xfer_id, offset, raw)
	local data, err = M.encode_chunk_data(raw)
	if not data then
		return nil, err
	end

	local frame = {
		type = 'xfer_chunk',
		xfer_id = xfer_id,
		offset = offset,
		data = data,
	}

	return validate(frame)
end

-- Extract raw binary bytes from a validated xfer_chunk frame.
---@param frame table
---@return string|nil raw
---@return string|nil err
function M.read_xfer_chunk(frame)
	local ok, err = validate_bulk(frame)
	if not ok then
		return nil, err
	end
	return M.decode_chunk_data(frame.data)
end

return M
