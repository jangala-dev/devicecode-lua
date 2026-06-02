-- services/fabric/protocol.lua
--
-- Pure Fabric wire/semantic protocol helpers.

local cjson    = require 'cjson.safe'
local b64url   = require 'shared.encoding.b64url'
local xxhash32 = require 'shared.hash.xxhash32'
local tablex   = require 'shared.table'

local M = {}

M.PROTO = 'fabric-jsonl/1'
M.DIGEST_ALG = 'xxhash32'
M.DEFAULT_CHUNK_SIZE = 2048

function M.proto_supported(proto)
	return proto == M.PROTO
end

function M.is_wire_protocol_error(err)
	if err == nil then return false end
	if type(err) == 'table' then
		err = err.err or err.reason or err.last_decode_error
	end

	local s = tostring(err)

	return s:match('^decode_failed') ~= nil
		or s:match('^encode_failed') ~= nil
		or s:match('^invalid_') ~= nil
		or s:match('^missing_') ~= nil
		or s:match('^unknown_frame_field') ~= nil
		or s:match('^unsupported_') ~= nil
		or s:match('^chunk_digest_mismatch') ~= nil
		or s:match('^non_canonical_base64url') ~= nil
		or s:match('^line_must_be_string') ~= nil
end

--------------------------------------------------------------------------------
-- Frame vocabulary and validation spec
--------------------------------------------------------------------------------

local FRAME_SPECS = {

	hello = {
		class = 'session_control',
		lane = 'session_control',
		fields = { 'type', 'proto', 'sid', 'node', 'identity', 'auth' },
		required = {
			{ 'proto', 'missing_proto' },
			{ 'sid',   'missing_sid' },
			{ 'node',  'missing_node' },
		},
		optional_objects = {
			identity = true,
			auth     = true,
		},
	},

	hello_ack = {
		class = 'session_control',
		lane = 'session_control',
		fields = { 'type', 'proto', 'sid', 'node', 'identity', 'auth' },
		required = {
			{ 'proto', 'missing_proto' },
			{ 'sid',   'missing_sid' },
			{ 'node',  'missing_node' },
		},
		optional_objects = {
			identity = true,
			auth     = true,
		},
	},

	ping = {
		class = 'session_control',
		lane = 'session_control',
		fields = { 'type', 'sid' },
		required = {
			{ 'sid', 'missing_sid' },
		},
	},

	pong = {
		class = 'session_control',
		lane = 'session_control',
		fields = { 'type', 'sid' },
		required = {
			{ 'sid', 'missing_sid' },
		},
	},

	pub = {
		class = 'rpc',
		lane = 'rpc',
		fields = { 'type', 'topic', 'retain', 'payload' },
		required = {
			{ 'topic',  'invalid_topic' },
			{ 'retain', 'missing_retain' },
		},
	},

	unretain = {
		class = 'rpc',
		lane = 'rpc',
		fields = { 'type', 'topic' },
		required = {
			{ 'topic', 'invalid_topic' },
		},
	},

	call = {
		class = 'rpc',
		lane = 'rpc',
		fields = { 'type', 'id', 'topic', 'payload' },
		required = {
			{ 'id',    'missing_id' },
			{ 'topic', 'invalid_topic' },
		},
	},

	reply = {
		class = 'rpc',
		lane = 'rpc',
		fields = { 'type', 'id', 'ok', 'payload', 'err' },
		required = {
			{ 'id', 'missing_id' },
			{ 'ok', 'missing_ok' },
		},
	},

	xfer_begin = {
		class = 'transfer_control',
		lane = 'transfer',
		fields = { 'type', 'xfer_id', 'target', 'size', 'digest_alg', 'digest', 'meta' },
		required = {
			{ 'xfer_id', 'missing_xfer_id' },
			{ 'target',  'missing_target' },
			{ 'size',    'invalid_xfer_size' },
		},
		digest = true,
	},

	xfer_ready = {
		class = 'transfer_control',
		lane = 'transfer',
		fields = { 'type', 'xfer_id' },
		required = {
			{ 'xfer_id', 'missing_xfer_id' },
		},
	},

	xfer_need = {
		class = 'transfer_control',
		lane = 'transfer',
		fields = { 'type', 'xfer_id', 'next' },
		required = {
			{ 'xfer_id', 'missing_xfer_id' },
			{ 'next',    'invalid_next' },
		},
	},

	xfer_chunk = {
		class = 'transfer_bulk',
		lane = 'transfer',
		fields = { 'type', 'xfer_id', 'offset', 'data', 'chunk_digest' },
		required = {
			{ 'xfer_id',      'missing_xfer_id' },
			{ 'offset',       'invalid_offset' },
			{ 'data',         'invalid_chunk_data' },
			{ 'chunk_digest', 'missing_chunk_digest' },
		},
		semantic = 'chunk',
	},

	xfer_commit = {
		class = 'transfer_control',
		lane = 'transfer',
		fields = { 'type', 'xfer_id', 'size', 'digest_alg', 'digest' },
		required = {
			{ 'xfer_id', 'missing_xfer_id' },
			{ 'size',    'invalid_xfer_size' },
		},
		digest = true,
	},

	xfer_done = {
		class = 'transfer_control',
		lane = 'transfer',
		fields = { 'type', 'xfer_id' },
		required = {
			{ 'xfer_id', 'missing_xfer_id' },
		},
	},

	xfer_abort = {
		class = 'transfer_control',
		lane = 'transfer',
		fields = { 'type', 'xfer_id', 'err' },
		required = {
			{ 'xfer_id', 'missing_xfer_id' },
		},
	},
}

local FRAME_TYPES = {}
local FRAME_FIELDS = {}

for type_name, spec in pairs(FRAME_SPECS) do
	FRAME_TYPES[type_name] = true

	local fields = {}
	for _, field in ipairs(spec.fields) do
		fields[field] = true
	end
	FRAME_FIELDS[type_name] = fields
end

function M.known_type(t)
	return FRAME_TYPES[t] == true
end

function M.classify(frame_or_type)
	local t = type(frame_or_type) == 'table'
		and frame_or_type.type
		or frame_or_type

	local spec = FRAME_SPECS[t]
	return spec and spec.class or nil
end

function M.dispatch_lane(frame_or_type)
	local t = type(frame_or_type) == 'table'
		and frame_or_type.type
		or frame_or_type

	local spec = FRAME_SPECS[t]
	return spec and spec.lane or nil
end

--------------------------------------------------------------------------------
-- Small pure helpers
--------------------------------------------------------------------------------

local shallow_copy = tablex.shallow_copy

function M.copy(frame)
	if type(frame) ~= 'table' then
		return nil, 'frame_must_be_table'
	end

	return shallow_copy(frame), nil
end

local function is_finite_number(v)
	return type(v) == 'number'
		and v == v
		and v ~= math.huge
		and v ~= -math.huge
end

local function is_nonneg_integer(v)
	return is_finite_number(v)
		and v >= 0
		and v % 1 == 0
end

local function is_nonempty_string(v)
	return type(v) == 'string' and v ~= ''
end

local function scalar_token_ok(v)
	if type(v) == 'string' then
		return true
	end

	if type(v) == 'number' then
		return is_finite_number(v)
	end

	return false
end

local function dense_array_len(t)
	if type(t) ~= 'table' then
		return nil
	end

	local n = #t

	for i = 1, n do
		if not scalar_token_ok(t[i]) then
			return nil
		end
	end

	for k in pairs(t) do
		if type(k) ~= 'number'
			or k < 1
			or k % 1 ~= 0
			or k > n
		then
			return nil
		end
	end

	return n
end

function M.validate_topic(topic)
	if dense_array_len(topic) == nil then
		return nil, 'invalid_topic'
	end

	return topic, nil
end

function M.topic_ok(topic) return dense_array_len(topic) ~= nil end

local function is_xxhash32_hex(v)
	return type(v) == 'string'
		and v:match('^[0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]$') ~= nil
end

--------------------------------------------------------------------------------
-- Digest helpers
--------------------------------------------------------------------------------

function M.digest_hex(bytes)
	assert(type(bytes) == 'string', 'protocol.digest_hex expects string')
	return xxhash32.digest_hex(bytes)
end

function M.digest_ok(digest)
	return is_xxhash32_hex(digest)
end

function M.verify_digest(bytes, digest)
	if type(bytes) ~= 'string' or not is_xxhash32_hex(digest) then
		return false
	end

	return M.digest_hex(bytes) == digest
end

function M.chunk_digest(bytes)
	return M.digest_hex(bytes)
end

function M.verify_chunk_digest(bytes, digest)
	return M.verify_digest(bytes, digest)
end

--------------------------------------------------------------------------------
-- Validation
--------------------------------------------------------------------------------

local function validate_frame_header(frame)
	if type(frame) ~= 'table' then
		return nil, 'invalid_frame_type'
	end

	if not is_nonempty_string(frame.type) then
		return nil, 'invalid_frame_type'
	end

	local spec = FRAME_SPECS[frame.type]
	if spec == nil then
		return nil, 'invalid_frame_type'
	end

	for k in pairs(frame) do
		if type(k) ~= 'string' or k == '' then
			return nil, 'invalid_frame_type'
		end
	end

	local allowed = FRAME_FIELDS[frame.type]
	for k in pairs(frame) do
		if not allowed[k] then
			return nil, 'unknown_frame_field: ' .. tostring(k)
		end
	end

	return spec, nil
end

local function validate_required_field(frame, field, err)
	local v = frame[field]

	if field == 'topic' then
		if not M.topic_ok(v) then return nil, err end
		return true, nil
	end

	if field == 'retain' then
		if type(v) ~= 'boolean' then return nil, err end
		return true, nil
	end

	if field == 'ok' then
		if type(v) ~= 'boolean' then return nil, err end
		return true, nil
	end

	if field == 'size' or field == 'next' or field == 'offset' then
		if not is_nonneg_integer(v) then return nil, err end
		return true, nil
	end

	if field == 'data' then
		if type(v) ~= 'string' then return nil, err end
		return true, nil
	end

	if field == 'chunk_digest' then
		if v == nil then return nil, 'missing_chunk_digest' end
		if not is_xxhash32_hex(v) then return nil, 'invalid_chunk_digest' end
		return true, nil
	end

	if not is_nonempty_string(v) then
		return nil, err
	end

	return true, nil
end

local function validate_optional_objects(frame, spec)
	for field in pairs(spec.optional_objects or {}) do
		local v = frame[field]

		if v ~= nil and v ~= cjson.null and type(v) ~= 'table' then
			return nil, 'invalid_' .. field
		end
	end

	return true, nil
end

local function validate_digest_fields(frame)
	if frame.digest_alg ~= M.DIGEST_ALG then
		return nil, 'unsupported_digest_alg'
	end

	if not is_xxhash32_hex(frame.digest) then
		return nil, 'invalid_digest'
	end

	return true, nil
end

local function validate_special_cases(frame)
	if frame.type == 'reply'
		and frame.ok == false
		and frame.err ~= nil
		and type(frame.err) ~= 'string'
	then
		return nil, 'invalid_reply_err'
	end

	if frame.type == 'xfer_abort'
		and frame.err ~= nil
		and type(frame.err) ~= 'string'
	then
		return nil, 'invalid_xfer_err'
	end

	if frame.type == 'xfer_begin'
		and frame.meta ~= nil
		and type(frame.meta) ~= 'table'
	then
		return nil, 'invalid_meta'
	end

	return true, nil
end

local function validate_by_spec(frame, opts)
	local spec, err = validate_frame_header(frame)
	if not spec then
		return nil, err
	end

	for _, req in ipairs(spec.required or {}) do
		local field, field_err = req[1], req[2]

		local ok, verr = validate_required_field(frame, field, field_err)
		if not ok then
			return nil, verr
		end
	end

	local ok, oerr = validate_optional_objects(frame, spec)
	if not ok then
		return nil, oerr
	end

	if spec.digest then
		ok, oerr = validate_digest_fields(frame)
		if not ok then
			return nil, oerr
		end
	end

	ok, oerr = validate_special_cases(frame)
	if not ok then
		return nil, oerr
	end

	if spec.semantic == 'chunk'
		and not (opts and opts.wire)
		and not M.verify_chunk_digest(frame.data, frame.chunk_digest)
	then
		return nil, 'chunk_digest_mismatch'
	end

	return frame, nil
end

function M.validate(frame) return validate_by_spec(frame) end
function M.validate_wire(frame) return validate_by_spec(frame, { wire = true }) end

-- Put near the cjson helpers / small pure helpers section.
function M.is_json_null(v)
	return v == cjson.null
end

function M.normalise_json_null(v)
	if v == cjson.null then return nil end
	return v
end

local function copy_json_value(v, seen)
	if v == cjson.null then return nil end
	if type(v) ~= 'table' then return v end

	seen = seen or {}
	if seen[v] then return seen[v] end

	local out = {}
	seen[v] = out

	for k, subv in pairs(v) do
		local copied = copy_json_value(subv, seen)
		if copied ~= nil then out[k] = copied end
	end

	return out
end

function M.copy_json_value(v) return copy_json_value(v) end
function M.normalise_reserved_claim(v) return copy_json_value(v) end
function M.copy_reserved_claim(v) return copy_json_value(v) end

-- Put after dispatch_lane().
function M.writer_lane(frame_or_type)
	local t = type(frame_or_type) == 'table'
		and frame_or_type.type
		or frame_or_type

	local lane = M.dispatch_lane(t)

	if lane == 'rpc' then
		return 'rpc', nil
	end

	if lane == 'transfer' then
		if t == 'xfer_chunk' then
			return 'bulk', nil
		end
		return 'control', nil
	end

	if lane == 'session_control' then
		return nil, 'session_control_frames_are_session_owned'
	end

	return nil, 'unknown_frame_lane'
end


--------------------------------------------------------------------------------
-- Constructors
--------------------------------------------------------------------------------

local function checked(frame)
	local ok, err = M.validate(frame)
	if not ok then
		return nil, err
	end

	return frame, nil
end

local function put_reserved(frame, identity, auth)
	if identity ~= nil then frame.identity = identity end
	if auth ~= nil then frame.auth = auth end
	return frame
end

function M.hello(sid, node, identity, auth)
	return checked(put_reserved({
		type  = 'hello',
		proto = M.PROTO,
		sid   = sid,
		node  = node,
	}, identity, auth))
end

function M.hello_ack(sid, node, identity, auth)
	return checked(put_reserved({
		type  = 'hello_ack',
		proto = M.PROTO,
		sid   = sid,
		node  = node,
	}, identity, auth))
end

local CTORS = {
	ping        = { 'sid' },
	pong        = { 'sid' },

	pub         = { 'topic', 'payload', 'retain' },
	unretain    = { 'topic' },
	call        = { 'id', 'topic', 'payload' },
	reply       = { 'id', 'ok', 'payload', 'err' },

	xfer_begin  = { 'xfer_id', 'target', 'size', 'digest_alg', 'digest', 'meta' },
	xfer_ready  = { 'xfer_id' },
	xfer_need   = { 'xfer_id', 'next' },
	xfer_chunk  = { 'xfer_id', 'offset', 'data', 'chunk_digest' },
	xfer_commit = { 'xfer_id', 'size', 'digest_alg', 'digest' },
	xfer_done   = { 'xfer_id' },
	xfer_abort  = { 'xfer_id', 'err' },
}

local function make_ctor(type_name, fields)
	return function (...)
		local frame = { type = type_name }

		for i = 1, #fields do
			local v = select(i, ...)
			if v ~= nil then
				frame[fields[i]] = v
			end
		end

		return checked(frame)
	end
end

for type_name, fields in pairs(CTORS) do
	M[type_name] = make_ctor(type_name, fields)
end

--------------------------------------------------------------------------------
-- Bulk chunk payload encoding
--------------------------------------------------------------------------------

local function is_strict_unpadded_b64url(s)
	return type(s) == 'string'
		and not s:find('=', 1, true)
		and s:match('^[A-Za-z0-9_-]*$') ~= nil
		and (#s % 4) ~= 1
end

function M.encode_chunk(bytes)
	assert(type(bytes) == 'string', 'encode_chunk expects string')
	return b64url.encode(bytes)
end

function M.decode_chunk(encoded)
	if type(encoded) ~= 'string' then
		return nil, 'chunk_must_be_string'
	end

	if not is_strict_unpadded_b64url(encoded) then
		return nil, 'invalid_base64url_unpadded'
	end

	local bytes, err = b64url.decode(encoded)
	if bytes == nil then
		return nil, err
	end

	if M.encode_chunk(bytes) ~= encoded then
		return nil, 'non_canonical_base64url'
	end

	return bytes, nil
end

local function to_wire_frame(frame)
	if frame.type ~= 'xfer_chunk' then
		return frame, nil
	end

	local out = shallow_copy(frame)
	out.data = M.encode_chunk(frame.data)

	return out, nil
end

local function from_wire_frame(frame)
	if frame.type ~= 'xfer_chunk' then
		return frame, nil
	end

	local out = shallow_copy(frame)
	local bytes, err = M.decode_chunk(out.data)

	if not bytes then
		return nil, 'invalid_chunk_encoding: ' .. tostring(err)
	end

	-- Do not verify the chunk digest here. Decode-line is a wire parsing
	-- boundary; semantic chunk acceptance belongs to the transfer receiver so
	-- it can request a same-offset retry instead of treating the line as an
	-- unroutable wire error.
	out.data = bytes

	return out, nil
end

--------------------------------------------------------------------------------
-- Line encoding
--------------------------------------------------------------------------------

function M.encode_line(frame)
	local ok, err = M.validate(frame)
	if not ok then
		return nil, err
	end

	local wire_frame, wire_err = to_wire_frame(frame)
	if not wire_frame then
		return nil, wire_err
	end

	local line, json_err = cjson.encode(wire_frame)
	if not line then
		return nil, 'encode_failed: ' .. tostring(json_err)
	end

	return line, nil
end

function M.decode_line(line)
	if type(line) ~= 'string' then
		return nil, 'line_must_be_string'
	end

	local wire_frame, json_err = cjson.decode(line)
	if not wire_frame then
		return nil, 'decode_failed: ' .. tostring(json_err)
	end

	local valid_wire, valid_err = M.validate_wire(wire_frame)
	if not valid_wire then
		return nil, valid_err
	end

	local frame, frame_err = from_wire_frame(valid_wire)
	if not frame then
		return nil, frame_err
	end

	return validate_by_spec(frame, { wire = true })
end

return M
