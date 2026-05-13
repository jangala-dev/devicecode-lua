local fibers       = require 'fibers'
local op           = require 'fibers.op'
local channel      = require 'fibers.channel'
local runfibers    = require 'tests.support.run_fibers'
local control_loop = require 'services.hal.support.control_loop'
local types        = require 'services.hal.types.core'

local T = {}

function T.evaluate_request_op_rejects_unknown_verbs()
    runfibers.run(function()
        local req = assert(types.new.ControlRequest('missing', {}, channel.new()))
        local ok, err = fibers.perform(control_loop.evaluate_request_op({}, req))
        assert(ok == false)
        assert(tostring(err):match('unsupported verb'))
    end)
end

function T.evaluate_request_op_requires_op_handlers()
    runfibers.run(function()
        local req = assert(types.new.ControlRequest('bad', {}, channel.new()))
        local ok, err = pcall(function()
            fibers.perform(control_loop.evaluate_request_op({
                bad = function() return true, 'nope' end,
            }, req))
        end)
        assert(ok == false)
        assert(tostring(err):match('must return an Op'))
    end)
end

function T.run_request_loop_handles_requests_and_replies()
    runfibers.run(function(scope)
        local ch = channel.new()

        local ok_spawn, err = scope:spawn(function()
            control_loop.run_request_loop(ch, {
                echo = function(opts)
                    return op.always(true, { echoed = opts.value })
                end,
            }, nil, 'test_loop')
        end)
        assert(ok_spawn, tostring(err))

        local reply_ch = channel.new()
        local req = assert(types.new.ControlRequest('echo', { value = 42 }, reply_ch))

        local sent, send_err = fibers.perform(ch:put_op(req))
        assert(sent ~= false, tostring(send_err))

        local reply, reply_err = fibers.perform(reply_ch:get_op())
        assert(reply, tostring(reply_err))
        assert(reply.ok == true)
        assert(type(reply.reason) == 'table')
        assert(reply.reason.echoed == 42)
    end)
end

function T.run_request_loop_returns_error_reply_for_unsupported_verbs()
    runfibers.run(function(scope)
        local ch = channel.new()

        local ok_spawn, err = scope:spawn(function()
            control_loop.run_request_loop(ch, {}, nil, 'test_loop')
        end)
        assert(ok_spawn, tostring(err))

        local reply_ch = channel.new()
        local req = assert(types.new.ControlRequest('nope', {}, reply_ch))

        local sent, send_err = fibers.perform(ch:put_op(req))
        assert(sent ~= false, tostring(send_err))

        local reply = fibers.perform(reply_ch:get_op())
        assert(reply ~= nil)
        assert(reply.ok == false)
        assert(tostring(reply.reason):match('unsupported verb'))
    end)
end

function T.run_request_loop_exits_when_scope_is_cancelled()
    runfibers.run(function(scope)
        local loop_scope, cerr = scope:child()
        assert(loop_scope, tostring(cerr))

        local ch = channel.new()

        local ok_spawn, err = loop_scope:spawn(function()
            control_loop.run_request_loop(ch, {
                echo = function(opts)
                    return op.always(true, opts)
                end,
            }, nil, 'test_loop')
        end)
        assert(ok_spawn, tostring(err))

        loop_scope:cancel('stop test')

        local st, rep, primary = fibers.perform(loop_scope:join_op())
        assert(st == 'cancelled', tostring(primary))
    end)
end

return T
