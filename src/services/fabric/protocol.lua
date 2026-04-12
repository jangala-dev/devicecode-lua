-- services/fabric/protocol.lua
--
-- Fabric control protocol.

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

local function require_bool(v, field)
    if type(v) ~= 'boolean' then
        return nil, field .. ' must be boolean'
    end
    return v, nil
end

local function require_nonneg_int(v, field)
    if type(v) ~= 'number' or v < 0 or v % 1 ~= 0 then
        return nil, field .. ' must be a non-negative integer'
    end
    return math.floor(v), nil
end

local function require_pos_int(v, field)
    if type(v) ~= 'number' or v <= 0 or v % 1 ~= 0 then
        return nil, field .. ' must be a positive integer'
    end
    return math.floor(v), nil
end

local function norm_proto(v)
    if v == nil then return M.PROTO_VERSION, nil end
    if type(v) ~= 'number' or v < 1 or v % 1 ~= 0 then
        return nil, 'proto must be a positive integer'
    end
    return math.floor(v), nil
end

local function optional_table(v)
    if v == nil then return nil end
    if type(v) ~= 'table' then return nil end
    return v
end

function M.validate_message(msg)
    if type(msg) ~= 'table' then
        return nil, 'message must be a table'
    end

    local tt = msg.t
    if type(tt) ~= 'string' or tt == '' then
        return nil, 'message requires non-empty t'
    end

    if tt == 'hello' then
        local node, err = require_nonempty_string(msg.node, 'hello.node')
        if not node then return nil, err end
        local peer, err2 = require_nonempty_string(msg.peer, 'hello.peer')
        if not peer then return nil, err2 end
        local sid, err3 = require_nonempty_string(msg.sid, 'hello.sid')
        if not sid then return nil, err3 end
        local proto, err4 = norm_proto(msg.proto)
        if not proto then return nil, err4 end
        local caps = (type(msg.caps) == 'table') and msg.caps or {}
        return { t = 'hello', node = node, peer = peer, sid = sid, proto = proto, caps = caps }, nil

    elseif tt == 'hello_ack' then
        local node, err = require_nonempty_string(msg.node, 'hello_ack.node')
        if not node then return nil, err end
        local sid, err2 = require_nonempty_string(msg.sid, 'hello_ack.sid')
        if not sid then return nil, err2 end
        local proto, err3 = norm_proto(msg.proto)
        if not proto then return nil, err3 end
        if msg.ok ~= nil and type(msg.ok) ~= 'boolean' then
            return nil, 'hello_ack.ok must be boolean'
        end
        return { t = 'hello_ack', node = node, sid = sid, proto = proto, ok = (msg.ok ~= false) }, nil

    elseif tt == 'ping' or tt == 'pong' then
        local sid, err = require_nonempty_string(msg.sid, tt .. '.sid')
        if not sid then return nil, err end
        return { t = tt, ts = msg.ts, sid = sid }, nil

    elseif tt == 'pub' then
        local topic, err = norm_topic(msg.topic, false, 'pub.topic')
        if not topic then return nil, err end
        if msg.retain ~= nil and type(msg.retain) ~= 'boolean' then
            return nil, 'pub.retain must be boolean'
        end
        return { t = 'pub', topic = topic, payload = msg.payload, retain = not not msg.retain }, nil

    elseif tt == 'unretain' then
        local topic, err = norm_topic(msg.topic, false, 'unretain.topic')
        if not topic then return nil, err end
        return { t = 'unretain', topic = topic }, nil

    elseif tt == 'call' then
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

    elseif tt == 'reply' then
        local corr, err = require_nonempty_string(msg.corr, 'reply.corr')
        if not corr then return nil, err end
        local _, err2 = require_bool(msg.ok, 'reply.ok')
        if err2 then return nil, err2 end
        if msg.ok == true then
            return { t = 'reply', corr = corr, ok = true, payload = msg.payload }, nil
        end
        return { t = 'reply', corr = corr, ok = false, err = tostring(msg.err or 'remote error') }, nil

    elseif tt == 'xfer_begin' then
        local id, err = require_nonempty_string(msg.id, 'xfer_begin.id')
        if not id then return nil, err end
        local kind, err2 = require_nonempty_string(msg.kind, 'xfer_begin.kind')
        if not kind then return nil, err2 end
        local name, err3 = require_nonempty_string(msg.name, 'xfer_begin.name')
        if not name then return nil, err3 end
        local format, err4 = require_nonempty_string(msg.format, 'xfer_begin.format')
        if not format then return nil, err4 end
        local enc, err5 = require_nonempty_string(msg.enc, 'xfer_begin.enc')
        if not enc then return nil, err5 end
        local size, err6 = require_nonneg_int(msg.size, 'xfer_begin.size')
        if not size then return nil, err6 end
        local chunk_raw, err7 = require_pos_int(msg.chunk_raw, 'xfer_begin.chunk_raw')
        if not chunk_raw then return nil, err7 end
        local chunks, err8 = require_nonneg_int(msg.chunks, 'xfer_begin.chunks')
        if not chunks then return nil, err8 end
        local sha256, err9 = require_nonempty_string(msg.sha256, 'xfer_begin.sha256')
        if not sha256 then return nil, err9 end
        return {
            t         = 'xfer_begin',
            id        = id,
            kind      = kind,
            name      = name,
            format    = format,
            enc       = enc,
            size      = size,
            chunk_raw = chunk_raw,
            chunks    = chunks,
            sha256    = sha256,
            meta      = optional_table(msg.meta),
        }, nil

    elseif tt == 'xfer_ready' then
        local id, err = require_nonempty_string(msg.id, 'xfer_ready.id')
        if not id then return nil, err end
        local _, err2 = require_bool(msg.ok, 'xfer_ready.ok')
        if err2 then return nil, err2 end
        local nextv = nil
        if msg.next ~= nil then
            nextv, err = require_nonneg_int(msg.next, 'xfer_ready.next')
            if not nextv then return nil, err end
        end
        return { t = 'xfer_ready', id = id, ok = msg.ok, next = nextv, err = (msg.ok == false) and tostring(msg.err or 'rejected') or nil }, nil

    elseif tt == 'xfer_chunk' then
        local id, err = require_nonempty_string(msg.id, 'xfer_chunk.id')
        if not id then return nil, err end
        local seq, err2 = require_nonneg_int(msg.seq, 'xfer_chunk.seq')
        if not seq then return nil, err2 end
        local off, err3 = require_nonneg_int(msg.off, 'xfer_chunk.off')
        if not off then return nil, err3 end
        local n, err4 = require_nonneg_int(msg.n, 'xfer_chunk.n')
        if not n then return nil, err4 end
        local crc32, err5 = require_nonempty_string(msg.crc32, 'xfer_chunk.crc32')
        if not crc32 then return nil, err5 end
        local data, err6 = require_nonempty_string(msg.data, 'xfer_chunk.data')
        if not data then return nil, err6 end
        return { t = 'xfer_chunk', id = id, seq = seq, off = off, n = n, crc32 = crc32, data = data }, nil

    elseif tt == 'xfer_need' then
        local id, err = require_nonempty_string(msg.id, 'xfer_need.id')
        if not id then return nil, err end
        local nextv, err2 = require_nonneg_int(msg.next, 'xfer_need.next')
        if not nextv then return nil, err2 end
        return { t = 'xfer_need', id = id, next = nextv, err = (msg.err ~= nil) and tostring(msg.err) or nil }, nil

    elseif tt == 'xfer_commit' then
        local id, err = require_nonempty_string(msg.id, 'xfer_commit.id')
        if not id then return nil, err end
        local size, err2 = require_nonneg_int(msg.size, 'xfer_commit.size')
        if not size then return nil, err2 end
        local sha256, err3 = require_nonempty_string(msg.sha256, 'xfer_commit.sha256')
        if not sha256 then return nil, err3 end
        return { t = 'xfer_commit', id = id, size = size, sha256 = sha256 }, nil

    elseif tt == 'xfer_done' then
        local id, err = require_nonempty_string(msg.id, 'xfer_done.id')
        if not id then return nil, err end
        local _, err2 = require_bool(msg.ok, 'xfer_done.ok')
        if err2 then return nil, err2 end
        return {
            t    = 'xfer_done',
            id   = id,
            ok   = msg.ok,
            info = optional_table(msg.info),
            err  = (msg.ok == false) and tostring(msg.err or 'transfer failed') or nil,
        }, nil

    elseif tt == 'xfer_abort' then
        local id, err = require_nonempty_string(msg.id, 'xfer_abort.id')
        if not id then return nil, err end
        local reason, err2 = require_nonempty_string(msg.reason, 'xfer_abort.reason')
        if not reason then return nil, err2 end
        return { t = 'xfer_abort', id = id, reason = reason }, nil
    end

    return nil, 'unknown message type: ' .. tostring(tt)
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
    return { t = 'ping', ts = os.time(), sid = opts.sid }
end

function M.pong(opts)
    opts = opts or {}
    return { t = 'pong', ts = os.time(), sid = opts.sid }
end

function M.pub(topic, payload, retain)
    return { t = 'pub', topic = topic, payload = payload, retain = not not retain }
end

function M.unretain(topic)
    return { t = 'unretain', topic = topic }
end

function M.call(id, topic, payload, timeout_ms)
    return { t = 'call', id = id, topic = topic, payload = payload, timeout_ms = timeout_ms }
end

function M.reply_ok(corr, payload)
    return { t = 'reply', corr = corr, ok = true, payload = payload }
end

function M.reply_err(corr, err)
    return { t = 'reply', corr = corr, ok = false, err = tostring(err) }
end

function M.xfer_begin(id, kind, name, format, enc, size, chunk_raw, chunks, sha256, meta)
    return {
        t         = 'xfer_begin',
        id        = id,
        kind      = kind,
        name      = name,
        format    = format,
        enc       = enc,
        size      = size,
        chunk_raw = chunk_raw,
        chunks    = chunks,
        sha256    = sha256,
        meta      = meta,
    }
end

function M.xfer_ready(id, ok, nextv, err)
    return { t = 'xfer_ready', id = id, ok = not not ok, next = nextv, err = (ok == false) and tostring(err or 'rejected') or nil }
end

function M.xfer_chunk(id, seq, off, n, crc32, data)
    return { t = 'xfer_chunk', id = id, seq = seq, off = off, n = n, crc32 = crc32, data = data }
end

function M.xfer_need(id, nextv, err)
    return { t = 'xfer_need', id = id, next = nextv, err = err }
end

function M.xfer_commit(id, size, sha256)
    return { t = 'xfer_commit', id = id, size = size, sha256 = sha256 }
end

function M.xfer_done(id, ok, info, err)
    return { t = 'xfer_done', id = id, ok = not not ok, info = info, err = (ok == false) and tostring(err or 'transfer failed') or nil }
end

function M.xfer_abort(id, reason)
    return { t = 'xfer_abort', id = id, reason = tostring(reason or 'aborted') }
end

return M
