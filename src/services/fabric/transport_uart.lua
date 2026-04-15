-- services/fabric/transport_uart.lua
--
-- UART fabric transport using a HAL UART capability.
--
-- The transport owns both capability discovery and the capability open call.
-- A successful open control reply is expected to be:
--   Reply { ok = true, reason = <Stream>, code = nil }
--
-- The returned stream is then used directly in-process.

local protocol = require 'services.fabric.protocol'
local checksum = require 'services.fabric.checksum'
local cap_sdk  = require 'services.hal.sdk.cap'
local op       = require 'fibers.op'

local M = {}
local UartTransport = {}
UartTransport.__index = UartTransport

local function is_transfer_message(msg)
    return type(msg) == 'table'
        and type(msg.t) == 'string'
        and msg.t:sub(1, 5) == 'xfer_'
end

local function line_crc32(line)
    if type(line) ~= 'string' then
        return nil
    end
    return checksum.crc32_hex(line)
end

local function resolve_uart_cap(conn, cfg)
    local cap_id = cfg.cap_id
    local timeout_s = cfg.open_timeout_s or 30.0

    local listener = cap_sdk.new_cap_listener(conn, 'uart', cap_id)
    local cap_ref, err = listener:wait_for_cap({ timeout = timeout_s })
    listener:close()

    if not cap_ref then
        return nil, err or ('uart capability not found: ' .. tostring(cap_id))
    end

    return cap_ref, nil
end

function M.new(conn, svc, cfg)
    cfg = cfg or {}
    return setmetatable({
        _conn           = assert(conn, 'uart transport requires a bus connection'),
        _svc            = svc,
        _cfg            = cfg,
        _cap            = nil,
        _stream         = nil,
        _link_id        = cfg.link_id,
        _max_line_bytes = (type(cfg.max_line_bytes) == 'number' and cfg.max_line_bytes > 0)
            and math.floor(cfg.max_line_bytes)
            or 4096,
    }, UartTransport)
end

function UartTransport:obs_log(level, payload)
    local svc = self._svc
    if not svc or type(svc.obs_log) ~= 'function' then
        return
    end
    payload = payload or {}
    if payload.link_id == nil then
        payload.link_id = self._link_id
    end
    if payload.cap_id == nil then
        payload.cap_id = self._cfg.cap_id
    end
    svc:obs_log(level, payload)
end

function UartTransport:open()
    if self._cap == nil then
        local cap_ref, err = resolve_uart_cap(self._conn, self._cfg)
        if not cap_ref then
            return nil, tostring(err)
        end
        self._cap = cap_ref
    end
    local opts, oerr = cap_sdk.args.new.UARTOpenOpts(true, true)
    if not opts then
        return nil, tostring(oerr)
    end

    local rep, err = self._cap:call_control('open', opts)
    if not rep then
        return nil, ('uart open control failed for %s: %s'):format(tostring(self._cap.id), tostring(err))
    end
    if rep.ok ~= true then
        return nil, ('uart open rejected for %s: %s'):format(
            tostring(self._cap.id),
            tostring(rep.reason or 'uart open failed')
        )
    end
    if type(rep.reason) ~= 'table' then
        return nil, ('uart open returned no stream in reply.reason for %s (reason type %s)'):format(
            tostring(self._cap.id),
            type(rep.reason)
        )
    end

    self._stream = rep.reason
    return true, nil
end

function UartTransport:close()
    local s = self._stream
    self._stream = nil

    if s and s.close_op then
        local ok, err = require('fibers').perform(s:close_op())
        return ok, err
    end
    return true, nil
end

function UartTransport:send_msg_op(msg)
    local s = assert(self._stream, 'uart transport is not open')
    return op.guard(function()
        local line, err = protocol.encode_line(msg)
        if not line then
            self:obs_log('warn', {
                what = 'uart_tx_encode_failed',
                t    = type(msg) == 'table' and msg.t or nil,
                id   = type(msg) == 'table' and msg.id or nil,
                err  = tostring(err),
            })
            return op.always(nil, err)
        end
        if #line > self._max_line_bytes then
            self:obs_log('warn', {
                what           = 'uart_tx_frame_too_large',
                t              = type(msg) == 'table' and msg.t or nil,
                id             = type(msg) == 'table' and msg.id or nil,
                seq            = type(msg) == 'table' and msg.seq or nil,
                off            = type(msg) == 'table' and msg.off or nil,
                line_len       = #line,
                line_crc32     = line_crc32(line),
                max_line_bytes = self._max_line_bytes,
            })
            return op.always(nil, 'frame_too_large')
        end
        return s:write_op(line, '\n'):wrap(function(n, werr)
            if n == nil then
                self:obs_log('warn', {
                    what       = 'uart_tx_failed',
                    t          = type(msg) == 'table' and msg.t or nil,
                    id         = type(msg) == 'table' and msg.id or nil,
                    seq        = type(msg) == 'table' and msg.seq or nil,
                    off        = type(msg) == 'table' and msg.off or nil,
                    n_bytes    = type(msg) == 'table' and msg.n or nil,
                    line_len   = #line,
                    line_crc32 = line_crc32(line),
                    err        = tostring(werr),
                })
                return nil, tostring(werr)
            end
            if is_transfer_message(msg) then
                self:obs_log('info', {
                    what          = 'uart_tx_line',
                    t             = msg.t,
                    id            = msg.id,
                    seq           = msg.seq,
                    off           = msg.off,
                    n_bytes       = msg.n,
                    next          = msg.next,
                    err           = msg.err or msg.reason,
                    data_len      = type(msg.data) == 'string' and #msg.data or nil,
                    line_len      = #line,
                    line_crc32    = line_crc32(line),
                    bytes_written = n,
                })
            end
            return true, nil
        end)
    end)
end

function UartTransport:recv_line_op()
    local s = assert(self._stream, 'uart transport is not open')
    return s:read_line_op():wrap(function(line, err)
        if err ~= nil then
            self:obs_log('warn', {
                what = 'uart_rx_failed',
                err  = tostring(err),
            })
            return nil, tostring(err)
        end
        if line == nil then
            self:obs_log('warn', {
                what = 'uart_rx_eof',
            })
            return nil, 'eof'
        end
        if #line > self._max_line_bytes then
            self:obs_log('warn', {
                what           = 'uart_rx_frame_too_large',
                line_len       = #line,
                line_crc32     = line_crc32(line),
                max_line_bytes = self._max_line_bytes,
            })
            return nil, 'frame_too_large'
        end

        local msg, derr = protocol.decode_line(line)
        if msg and is_transfer_message(msg) then
            self:obs_log('info', {
                what       = 'uart_rx_line',
                t          = msg.t,
                id         = msg.id,
                seq        = msg.seq,
                off        = msg.off,
                n_bytes    = msg.n,
                next       = msg.next,
                err        = msg.err or msg.reason,
                data_len   = type(msg.data) == 'string' and #msg.data or nil,
                line_len   = #line,
                line_crc32 = line_crc32(line),
            })
        elseif not msg then
            self:obs_log('warn', {
                what       = 'uart_rx_decode_failed',
                line_len   = #line,
                line_crc32 = line_crc32(line),
                err        = tostring(derr),
            })
        end

        return line, nil
    end)
end

function UartTransport:recv_msg_op()
    return self:recv_line_op():wrap(function(line, err)
        if not line then
            return nil, err
        end
        local msg, derr = protocol.decode_line(line)
        if not msg then
            return nil, derr
        end
        return msg, nil
    end)
end

function UartTransport:stats()
    return {
        kind   = 'uart',
        cap_id = (self._cap and self._cap.id) or self._cfg.cap_id,
    }
end

return M
