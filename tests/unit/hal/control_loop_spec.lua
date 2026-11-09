local fibers       = require 'fibers'
local runtime      = require 'fibers.runtime'
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


function T.run_request_loop_cancels_handler_op_when_request_cancel_op_fires()
	runfibers.run(function(scope)
		local ch = channel.new()
		local reply_ch = channel.new()
		local cancel_ch = channel.new()
		local entered = channel.new()
		local aborted = false

		local ok_spawn, err = scope:spawn(function()
			control_loop.run_request_loop(ch, {
				slow = function()
					entered:put(true)
					return op.never():on_abort(function () aborted = true end)
				end,
			}, nil, 'test_loop')
		end)
		assert(ok_spawn, tostring(err))

		local cancel_op = cancel_ch:get_op():wrap(function (reason) return reason or 'caller_abandoned' end)
		local req = assert(types.new.ControlRequest('slow', {}, reply_ch, cancel_op))
		assert(fibers.perform(ch:put_op(req)) ~= false)
		assert(fibers.perform(entered:get_op()) == true)
		assert(fibers.perform(cancel_ch:put_op('caller_abandoned')) ~= false)

		for _ = 1, 4 do runtime.yield() end
		assert(aborted == true)

		local got = fibers.perform(reply_ch:get_op():or_else(function () return nil, 'not_ready' end))
		assert(got == nil)
	end)
end


function T.run_request_loop_detaches_caller_after_admission_when_policy_requests_it()
	runfibers.run(function(scope)
		local ch = channel.new()
		local reply_ch = channel.new()
		local cancel_ch = channel.new(1)
		local entered = channel.new(1)
		local release = channel.new(1)
		local aborted = false
		local completed = false
		local logs = {}
		local logger = {
			warn = function(_, payload) logs[#logs + 1] = payload end,
			info = function(_, payload) logs[#logs + 1] = payload end,
			debug = function(_, payload) logs[#logs + 1] = payload end,
		}

		local ok_spawn, err = scope:spawn(function()
			control_loop.run_request_loop(ch, {
				__cancel_policy = { apply = 'detach_after_admission' },
				apply = function()
					fibers.perform(entered:put_op(true))
					return release:get_op():wrap(function () completed = true; return true, { applied = true } end)
						:on_abort(function () aborted = true end)
				end,
			}, logger, 'network_config')
		end)
		assert(ok_spawn, tostring(err))

		local cancel_op = cancel_ch:get_op():wrap(function (reason) return reason or 'caller_abandoned' end)
		local req = assert(types.new.ControlRequest('apply', {}, reply_ch, cancel_op))
		assert(fibers.perform(ch:put_op(req)) ~= false)
		assert(fibers.perform(entered:get_op()) == true)
		assert(fibers.perform(cancel_ch:put_op('caller_abandoned')) ~= false)
		for _ = 1, 4 do runtime.yield() end
		assert(aborted == false, 'admitted apply must not be aborted by caller abandonment')
		assert(fibers.perform(release:put_op(true)) ~= false)
		for _ = 1, 4 do runtime.yield() end
		assert(completed == true, 'admitted apply should complete after caller detaches')
		local got = fibers.perform(reply_ch:get_op():or_else(function () return nil, 'not_ready' end))
		assert(got == nil, 'detached caller should not receive a late reply')

		local saw_detached = false
		for _, rec in ipairs(logs) do
			if rec.what == 'network_config_request_detached' and rec.admitted == true then
				saw_detached = true
			end
		end
		assert(saw_detached == true, 'expected admitted caller detachment log')
	end)
end

return T
