-- services/fabric/protocol.lua
--
-- First-pass control protocol:
--   * one JSON object per line
--   * suitable for stream transports
--
-- This version carries explicit session identity in hello/ack/ping/pong.

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
