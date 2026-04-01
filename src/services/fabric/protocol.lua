-- services/fabric/protocol.lua
--
-- First-pass control protocol:
--   * one JSON object per line
--   * suitable for stream transports
--
-- This version carries explicit session identity in hello/ack/ping/pong,
-- and provides strict validation helpers for session code.

local cjson = require 'cjson.safe'
local uuid  = require 'uuid'

local M = {}

M.PROTO_VERSION = 1

function M.next_id()
	return tostring(uuid.new())
end

function M.encode_line(msg)
	local s, err = cjson.encode(msg)
	if s == nil then
		return nil, 'json_encode_failed: ' .. tostring(err)
	end
	return s, nil
end

function M.decode_line(line)
	local obj, err = cjson.decode(line)
	if obj == nil then
		return nil, 'json_decode_failed: ' .. tostring(err)
	end
	if type(obj) ~= 'table' then
		return nil, 'protocol line must decode to table'
	end
	if type(obj.t) ~= 'string' or obj.t == '' then
		return nil, 'protocol line requires non-empty t'
	end
	return obj, nil
end

local function is_dense_array(t)
	if type(t) ~= 'table' then return false end
	local n = 0
	for _ in ipairs(t) do n = n + 1 end
	for k in pairs(t) do
		if type(k) ~= 'number' or k < 1 or k % 1 ~= 0 or k > n then
			return false
		end
	end
	return true
end

local function norm_topic(topic, concrete, field)
	field = field or 'topic'

	if not is_dense_array(topic) then
		return nil, field .. ' must be a dense array'
	end

	local out = {}
	for i = 1, #topic do
		local v = topic[i]
		if type(v) ~= 'string' or v == '' then
			return nil, ('%s[%d] must be a non-empty string'):format(field, i)
		end
		if concrete and (v == '+' or v == '#') then
			return nil, field .. ' must be concrete'
		end
		out[i] = v
	end

	return out, nil
end

local function require_nonempty_string(v, field)
	if type(v) ~= 'string' or v == '' then
		return nil, field .. ' must be a non-empty string'
	end
	return v, nil
end

local function norm_proto(v)
	if v == nil then return M.PROTO_VERSION, nil end
	if type(v) ~= 'number' or v < 1 or v % 1 ~= 0 then
		return nil, 'proto must be a positive integer'
	end
	return math.floor(v), nil
end

function M.validate_message(msg)
	if type(msg) ~= 'table' then
		return nil, 'message must be a table'
	end

	local t = msg.t
	if type(t) ~= 'string' or t == '' then
		return nil, 'message requires non-empty t'
	end

	if t == 'hello' then
		local node, err = require_nonempty_string(msg.node, 'hello.node')
		if not node then return nil, err end

		local peer, err2 = require_nonempty_string(msg.peer, 'hello.peer')
		if not peer then return nil, err2 end

		local sid, err3 = require_nonempty_string(msg.sid, 'hello.sid')
		if not sid then return nil, err3 end

		local proto, err4 = norm_proto(msg.proto)
		if not proto then return nil, err4 end

		local caps = (type(msg.caps) == 'table') and msg.caps or {}

		return {
			t     = 'hello',
			node  = node,
			peer  = peer,
			sid   = sid,
			proto = proto,
			caps  = caps,
		}, nil

	elseif t == 'hello_ack' then
		local node, err = require_nonempty_string(msg.node, 'hello_ack.node')
		if not node then return nil, err end

		local sid, err2 = require_nonempty_string(msg.sid, 'hello_ack.sid')
		if not sid then return nil, err2 end

		local proto, err3 = norm_proto(msg.proto)
		if not proto then return nil, err3 end

		if msg.ok ~= nil and type(msg.ok) ~= 'boolean' then
			return nil, 'hello_ack.ok must be boolean'
		end

		return {
			t     = 'hello_ack',
			node  = node,
			sid   = sid,
			proto = proto,
			ok    = (msg.ok ~= false),
		}, nil

	elseif t == 'ping' or t == 'pong' then
		local sid, err = require_nonempty_string(msg.sid, t .. '.sid')
		if not sid then return nil, err end

		return {
			t   = t,
			ts  = msg.ts,
			sid = sid,
		}, nil

	elseif t == 'pub' then
		local topic, err = norm_topic(msg.topic, false, 'pub.topic')
		if not topic then return nil, err end
		if msg.retain ~= nil and type(msg.retain) ~= 'boolean' then
			return nil, 'pub.retain must be boolean'
		end

		return {
			t       = 'pub',
			topic   = topic,
			payload = msg.payload,
			retain  = not not msg.retain,
		}, nil

	elseif t == 'unretain' then
		local topic, err = norm_topic(msg.topic, false, 'unretain.topic')
		if not topic then return nil, err end

		return {
			t     = 'unretain',
			topic = topic,
		}, nil

	elseif t == 'call' then
		local id, err = require_nonempty_string(msg.id, 'call.id')
		if not id then return nil, err end

		local topic, err2 = norm_topic(msg.topic, true, 'call.topic')
		if not topic then return nil, err2 end

		if msg.timeout_ms ~= nil then
			if type(msg.timeout_ms) ~= 'number' or msg.timeout_ms <= 0 then
				return nil, 'call.timeout_ms must be a positive number'
			end
		end

		return {
			t          = 'call',
			id         = id,
			topic      = topic,
			payload    = msg.payload,
			timeout_ms = msg.timeout_ms,
		}, nil

	elseif t == 'reply' then
		local corr, err = require_nonempty_string(msg.corr, 'reply.corr')
		if not corr then return nil, err end

		if type(msg.ok) ~= 'boolean' then
			return nil, 'reply.ok must be boolean'
		end

		if msg.ok == true then
			return {
				t       = 'reply',
				corr    = corr,
				ok      = true,
				payload = msg.payload,
			}, nil
		end

		return {
			t    = 'reply',
			corr = corr,
			ok   = false,
			err  = tostring(msg.err or 'remote error'),
		}, nil
	end

	return nil, 'unknown message type: ' .. tostring(t)
end

function M.hello(node_id, peer_id, caps, opts)
	opts = opts or {}
	return {
		t     = 'hello',
		node  = node_id,
		peer  = peer_id,
		sid   = opts.sid or M.next_id(),
		proto = opts.proto or M.PROTO_VERSION,
		caps  = caps or {},
	}
end

function M.hello_ack(node_id, opts)
	opts = opts or {}
	return {
		t     = 'hello_ack',
		node  = node_id,
		sid   = opts.sid,
		proto = opts.proto or M.PROTO_VERSION,
		ok    = (opts.ok ~= false),
	}
end

function M.ping(opts)
	opts = opts or {}
	return {
		t   = 'ping',
		ts  = os.time(),
		sid = opts.sid,
	}
end

function M.pong(opts)
	opts = opts or {}
	return {
		t   = 'pong',
		ts  = os.time(),
		sid = opts.sid,
	}
end

function M.pub(topic, payload, retain)
	return {
		t       = 'pub',
		topic   = topic,
		payload = payload,
		retain  = not not retain,
	}
end

function M.unretain(topic)
	return {
		t     = 'unretain',
		topic = topic,
	}
end

function M.call(id, topic, payload, timeout_ms)
	return {
		t          = 'call',
		id         = id,
		topic      = topic,
		payload    = payload,
		timeout_ms = timeout_ms,
	}
end

function M.reply_ok(corr, payload)
	return {
		t       = 'reply',
		corr    = corr,
		ok      = true,
		payload = payload,
	}
end

function M.reply_err(corr, err)
	return {
		t    = 'reply',
		corr = corr,
		ok   = false,
		err  = tostring(err),
	}
end

return M
