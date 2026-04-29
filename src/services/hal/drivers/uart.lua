---@module 'services.hal.drivers.uart'

local fibers    = require 'fibers'
local sleep     = require 'fibers.sleep'
local op        = require 'fibers.op'
local channel   = require 'fibers.channel'
local file      = require 'fibers.io.file'
local uuid      = require 'uuid'

local hal_types = require 'services.hal.types.core'
local cap_types = require 'services.hal.types.capabilities'
local cap_args  = require 'services.hal.types.capability_args'

local unpack = rawget(table, 'unpack') or _G.unpack
local pack   = rawget(table, 'pack') or function (...)
	return { n = select('#', ...), ... }
end

local M = {}

local CONTROL_Q_LEN        = 8
local INTERNAL_Q_LEN       = 8
local DEFAULT_STOP_TIMEOUT = 5.0

---@class UARTSession
---@field lease_id string
---@field stream Stream
---@field internal_ch Channel
---@field closed boolean
local UARTSession = {}
UARTSession.__index = UARTSession

---@class UARTDriver
---@field id string
---@field path string
---@field default_baud integer|nil
---@field default_mode string|nil
---@field scope Scope|nil
---@field control_ch Channel
---@field internal_ch Channel
---@field emit_ch Channel|nil
---@field logger table|nil
---@field started boolean
---@field caps_applied boolean
---@field active_session UARTSession|nil
---@field active_lease_id string|nil
local Driver = {}
Driver.__index = Driver

local function dlog(self, level, payload)
    if self.logger and self.logger[level] then
        self.logger[level](self.logger, payload)
    end
end

local function emit_op(emit_ch, class, id, mode, key, data)
    return op.guard(function ()
        local payload, err = hal_types.new.Emit(class, id, mode, key, data)
        if not payload then
            return op.always(false, tostring(err))
        end

        return emit_ch:put_op(payload):wrap(function ()
            return true, nil
        end)
    end)
end

local function status_payload(self)
    return {
        state         = 'available',
        available     = true,
        open          = self.active_session ~= nil,
        lease_id      = self.active_lease_id,
        path          = self.path,
        baud          = self.default_baud,
        mode          = self.default_mode,
        config_source = 'devicetree',
    }
end

local function meta_payload(self)
    return {
        kind          = 'uart',
        path          = self.path,
        baud          = self.default_baud,
        mode          = self.default_mode,
        config_source = 'devicetree',
    }
end

local function reply_request_op(reply_ch, ok, value_or_err)
    return op.guard(function ()
        local reply, err = hal_types.new.Reply(ok, value_or_err)
        if not reply then
            return op.always(false, 'invalid reply: ' .. tostring(err))
        end

        return reply_ch:put_op(reply):wrap(function (sent, send_err)
            if sent == true then
                return true, nil
            end
            if sent == nil then
                return false, tostring(send_err or 'reply channel closed')
            end
            return false, tostring(send_err or 'reply delivery failed')
        end)
    end)
end

local function new_session(lease_id, stream, internal_ch)
    return setmetatable({
        lease_id    = lease_id,
        stream      = stream,
        internal_ch = internal_ch,
        closed      = false,
    }, UARTSession)
end

function UARTSession:read_some_op(max)
    return op.guard(function ()
        if self.closed then
            return op.always(nil, 'uart session closed')
        end
        return self.stream:read_some_op(max)
    end)
end

function UARTSession:read_exactly_op(n)
    return op.guard(function ()
        if self.closed then
            return op.always(nil, 'uart session closed')
        end
        return self.stream:read_exactly_op(n)
    end)
end

function UARTSession:read_line_op(opts)
    return op.guard(function ()
        if self.closed then
            return op.always(nil, 'uart session closed')
        end
        return self.stream:read_line_op(opts)
    end)
end

function UARTSession:read_all_op()
    return op.guard(function ()
        if self.closed then
            return op.always('', 'uart session closed')
        end
        return self.stream:read_all_op()
    end)
end

function UARTSession:write_op(...)
    local parts = { ... }
    return op.guard(function ()
        if self.closed then
            return op.always(nil, 'uart session closed')
        end
        return self.stream:write_op(unpack(parts))
    end)
end

function UARTSession:flush_op()
    return op.guard(function ()
        if self.closed then
            return op.always(nil, 'uart session closed')
        end
        return self.stream:flush_op()
    end)
end

-- Close the underlying stream and best-effort notify the driver shell.
-- If notification fails because the shell is already stopping, close still
-- succeeds; the session is closed regardless.
function UARTSession:close_op()
    return fibers.run_scope_op(function ()
        if self.closed then
            return true, nil
        end

        local ok, err = fibers.perform(self.stream:close_op())
        if ok == nil then
            return false, tostring(err)
        end

        self.closed = true

        local sent, send_err = fibers.perform(self.internal_ch:put_op({
            kind     = 'session_closed',
            lease_id = self.lease_id,
        }))

        -- Explicit best-effort semantics: close wins even if shell notification
        -- cannot be delivered because the driver is already shutting down.
        if sent ~= true then
            return true, nil
        end

        return true, nil
    end):wrap(function (st, rep, ok, err)
        if st ~= 'ok' then
            return false, tostring(err or rep)
        end
        return ok, err
    end)
end

local function open_stream_op(path)
    return fibers.run_scope_op(function ()
        -- Box the currently synchronous file.open(...) impurity inside one
        -- operation-owned subtree. Surface remains op-native.
        local stream, err = file.open(path, 'r+')
        if not stream then
            return false, tostring(err)
        end
        return true, stream
    end):wrap(function (st, rep, ok, value_or_err)
        if st ~= 'ok' then
            return false, tostring(value_or_err or rep)
        end
        return ok, value_or_err
    end)
end

local function open_session_op(self)
    return fibers.run_scope_op(function ()
        local ok, stream_or_err = fibers.perform(open_stream_op(self.path))
        if not ok then
            return false, stream_or_err
        end

        local lease_id = uuid.new()
        local session = new_session(lease_id, stream_or_err, self.internal_ch)

        local reply, rerr = hal_types.new.UARTOpenReply(
            lease_id,
            session,
            self.path,
            self.default_baud,
            self.default_mode
        )
        if not reply then
            local _ = fibers.perform(stream_or_err:close_op())
            _ = _
            return false, tostring(rerr)
        end

        return true, reply
    end):wrap(function (st, rep, ok, value_or_err)
        if st ~= 'ok' then
            return false, tostring(value_or_err or rep)
        end
        return ok, value_or_err
    end)
end

local function publish_status_op(self)
    return emit_op(self.emit_ch, 'uart', self.id, 'state', 'status', status_payload(self))
end

local function publish_event_op(self, event_name, data)
    return emit_op(self.emit_ch, 'uart', self.id, 'event', event_name, data)
end

local function close_active_session_op(self, emit_closed_event)
    return fibers.run_scope_op(function ()
        local session = self.active_session
        local lease_id = self.active_lease_id

        if not session then
            return true, nil
        end

        if not session.closed then
            local ok, err = fibers.perform(session.stream:close_op())
            if ok == nil then
                return false, tostring(err)
            end
            session.closed = true
        end

        self.active_session  = nil
        self.active_lease_id = nil

        local ok_status, status_err = fibers.perform(publish_status_op(self))
        if not ok_status then
            return false, tostring(status_err)
        end

        if emit_closed_event then
            local ok_event, event_err = fibers.perform(publish_event_op(self, 'closed', {
                lease_id = lease_id,
                path     = self.path,
            }))
            if not ok_event then
                return false, tostring(event_err)
            end
        end

        return true, nil
    end):wrap(function (st, rep, ok, err)
        if st ~= 'ok' then
            return false, tostring(err or rep)
        end
        return ok, err
    end)
end

local function methods_for(self)
    return {
        status = function (_opts, _request)
            return op.always(true, status_payload(self))
        end,

        open = function (opts, _request)
            if opts ~= nil and (type(opts) ~= 'table' or getmetatable(opts) ~= cap_args.UARTOpenOpts) then
                return op.always(false, 'invalid open opts')
            end

            if self.active_session ~= nil then
                return op.always(false, 'busy')
            end

            return fibers.run_scope_op(function ()
                local ok, reply_or_err = fibers.perform(open_session_op(self))
                if not ok then
                    return false, reply_or_err
                end

                self.active_session  = reply_or_err.session
                self.active_lease_id = reply_or_err.lease_id

                local ok_status, status_err = fibers.perform(publish_status_op(self))
                if not ok_status then
                    return false, tostring(status_err)
                end

                local ok_event, event_err = fibers.perform(publish_event_op(self, 'opened', {
                    lease_id = reply_or_err.lease_id,
                    path     = self.path,
                }))
                if not ok_event then
                    return false, tostring(event_err)
                end

                return true, reply_or_err
            end):wrap(function (st, rep, ok, value_or_err)
                if st ~= 'ok' then
                    return false, tostring(value_or_err or rep)
                end
                return ok, value_or_err
            end)
        end,
    }
end

local function handle_internal_event_op(self, ev)
    return op.guard(function ()
        if type(ev) ~= 'table' then
            return op.always(true, nil)
        end

        if ev.kind ~= 'session_closed' then
            return op.always(true, nil)
        end

        if self.active_lease_id ~= ev.lease_id then
            return op.always(true, nil)
        end

        return close_active_session_op(self, true)
    end)
end

local function handle_request_op(self, request)
    return fibers.run_scope_op(function ()
        local methods = methods_for(self)
        local fn = methods[request.verb]

        local ok, value_or_err
        if type(fn) ~= 'function' then
            ok = false
            value_or_err = 'unsupported verb: ' .. tostring(request.verb)
        else
            ok, value_or_err = fibers.perform(fn(request.opts, request))
        end

        local replied, reply_err =
            fibers.perform(reply_request_op(request.reply_ch, ok, value_or_err))

        if not replied then
            return false, tostring(reply_err)
        end

        return true, nil
    end):wrap(function (st, rep, ok, err)
        if st ~= 'ok' then
            return false, tostring(err or rep)
        end
        return ok, err
    end)
end

local function shell_main(self)
    assert(self.scope, 'uart shell without scope')
    assert(self.emit_ch, 'uart shell without emit channel')

    local ok_meta, meta_err =
        fibers.perform(emit_op(self.emit_ch, 'uart', self.id, 'meta', 'details', meta_payload(self)))
    if ok_meta ~= true then
        error(tostring(meta_err or 'initial uart meta emit failed'), 0)
    end

    local ok_status, status_err = fibers.perform(publish_status_op(self))
    if ok_status ~= true then
        error(tostring(status_err or 'initial uart status emit failed'), 0)
    end

    while true do
        local which, a, b = fibers.perform(fibers.named_choice{
            req  = self.control_ch:get_op(),
            evt  = self.internal_ch:get_op(),
            stop = self.scope:not_ok_op(),
        })

        if which == 'stop' then
            local ok_close, close_err = fibers.perform(close_active_session_op(self, false))
            if not ok_close then
                dlog(self, 'warn', {
                    what = 'uart_close_on_stop_failed',
                    err  = tostring(close_err),
                })
            end
            return
        end

        if which == 'evt' then
            local ok_evt, evt_err = fibers.perform(handle_internal_event_op(self, a))
            if not ok_evt then
                error(tostring(evt_err), 0)
            end
        end

        if which == 'req' then
            local request, req_err = a, b
            if not request then
                return
            end

            local ok_req, req_err2 = fibers.perform(handle_request_op(self, request))
            if not ok_req then
                dlog(self, 'warn', {
                    what = 'uart_request_failed',
                    err  = tostring(req_err2),
                })
            end
        end
    end
end

function Driver:capabilities_op(emit_ch)
    return op.guard(function ()
        if self.caps_applied then
            return op.always(false, 'capabilities already applied')
        end

        self.emit_ch = emit_ch

        local cap, err = cap_types.new.UARTCapability(self.id, self.control_ch)
        if not cap then
            return op.always(false, tostring(err))
        end

        self.caps_applied = true
        return op.always(true, { cap })
    end)
end

---@param owner_scope Scope
function Driver:start_op(owner_scope)
    assert(owner_scope ~= nil, 'uart driver start_op: owner_scope is required')

    return op.guard(function ()
        if self.started then
            return op.always(false, 'already started')
        end
        if not self.caps_applied then
            return op.always(false, 'capabilities not applied')
        end
        if not self.emit_ch then
            return op.always(false, 'missing emit channel')
        end

        local shell_scope, serr = owner_scope:child()
        if not shell_scope then
            return op.always(false, tostring(serr))
        end

        self.scope = shell_scope

        local ok, err = shell_scope:spawn(function ()
            return shell_main(self)
        end)
        if not ok then
            self.scope = nil
            return op.always(false, tostring(err))
        end

        self.started = true
        return op.always(true, nil)
    end)
end

function Driver:stop_op(timeout)
    timeout = timeout or DEFAULT_STOP_TIMEOUT

    return op.guard(function ()
        if not self.started or not self.scope then
            return op.always(true, nil)
        end

        local shell_scope = self.scope
        local session = self.active_session

        shell_scope:cancel()

        return fibers.boolean_choice(
            shell_scope:join_op():wrap(function ()
                -- Make the post-stop contract explicit: any previously returned
                -- session wrapper is no longer usable, even if the shell stop
                -- path did not get to mark it in time.
                if session then
                    session.closed = true
                end

                self.started         = false
                self.scope           = nil
                self.active_session  = nil
                self.active_lease_id = nil
                return true, nil
            end),
            sleep.sleep_op(timeout):wrap(function ()
                return false, 'uart driver stop timeout'
            end)
        ):wrap(function (completed, _a, b)
            if completed then
                return true, nil
            end
            return false, b
        end)
    end)
end

function Driver:fault_op()
    if self.scope and self.started then
        return self.scope:fault_op()
    end
    return op.never()
end

---@param id string
---@param path string
---@param baud integer|nil
---@param mode string|nil
---@param logger table|nil
---@return UARTDriver
function M.new(id, path, baud, mode, logger)
    assert(type(id) == 'string' and id ~= '', 'uart.new: invalid id')
    assert(type(path) == 'string' and path ~= '', 'uart.new: invalid path')

    return setmetatable({
        id              = id,
        path            = path,
        default_baud    = baud,
        default_mode    = mode,
        scope           = nil,
        control_ch      = channel.new(CONTROL_Q_LEN),
        internal_ch     = channel.new(INTERNAL_Q_LEN),
        emit_ch         = nil,
        logger          = logger,
        started         = false,
        caps_applied    = false,
        active_session  = nil,
        active_lease_id = nil,
    }, Driver)
end

M.Driver = Driver
M.UARTSession = UARTSession
return M
