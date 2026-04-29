local fibers    = require 'fibers'
local op        = require 'fibers.op'
local scope_mod = require 'fibers.scope'

local hal_types = require 'services.hal.types.core'

local perform = fibers.perform

local M = {}

local function dlog(logger, level, payload)
	if logger and logger[level] then
		logger[level](logger, payload)
	end
end

---@param ev any
---@param verb string
---@return Op
local function assert_op_result(ev, verb)
	if type(ev) ~= 'table' or getmetatable(ev) ~= op.Op then
		error(
			('control method %q must return an Op, got %s (%s)'):format(
				tostring(verb),
				type(ev),
				tostring(ev)
			),
			3
		)
	end
	return ev
end

--- Evaluate a control request against an op-returning method table.
---
--- Contract:
---   methods[verb](opts, request) -> Op
---
--- The returned Op must resolve to:
---   ok:boolean, value_or_err:any
---
---@param methods table<string, fun(opts:any, request:ControlRequest): Op>
---@param request ControlRequest
---@return Op
function M.evaluate_request_op(methods, request)
	return op.guard(function ()
		local fn = methods[request.verb]
		if type(fn) ~= 'function' then
			return op.always(false, 'unsupported verb: ' .. tostring(request.verb))
		end

		return assert_op_result(fn(request.opts, request), tostring(request.verb))
	end)
end

--- Reply to a control request via its reply channel.
---
--- Returns:
---   true, nil           on successful delivery
---   false, reason       on validation/delivery failure
---
---@param reply_ch Channel
---@param ok boolean
---@param value_or_err any
---@return Op
function M.reply_op(reply_ch, ok, value_or_err)
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

--- Canonical shell loop for HAL request/reply control channels.
---
--- This is intentionally the semantic boundary where blocking policy is visible:
---   * wait for the next request or scope shutdown/failure
---   * perform exactly one request Op
---   * perform exactly one reply Op
---
--- Request handlers must return Ops and must not hide blocking behind
--- immediate helper methods.
---
---@param ch Channel
---@param methods table<string, fun(opts:any, request:ControlRequest): Op>
---@param logger table|nil
---@param what string|nil
function M.run_request_loop(ch, methods, logger, what)
	local scope = scope_mod.current()

	scope:finally(function ()
		dlog(logger, 'debug', {
			what = tostring(what or 'control_loop') .. '_exiting',
		})
	end)

	while true do
		local which, a, b = perform(fibers.named_choice{
			request = ch:get_op(),
			stop    = scope:not_ok_op(),
		})

		if which == 'stop' then
			local status, reason_or_primary = a, b
			dlog(logger, 'debug', {
				what   = tostring(what or 'control_loop') .. '_stopping',
				status = tostring(status),
				reason = tostring(reason_or_primary),
			})
			return
		end

		local request, req_err = a, b
		if not request then
			dlog(logger, 'debug', {
				what = tostring(what or 'control_loop') .. '_closed',
				err  = tostring(req_err or 'control channel closed'),
			})
			return
		end

		local ok, value_or_err = perform(M.evaluate_request_op(methods, request))

		local replied, reply_err = perform(M.reply_op(request.reply_ch, ok, value_or_err))
		if not replied then
			dlog(logger, 'warn', {
				what = tostring(what or 'control_loop') .. '_reply_failed',
				verb = tostring(request.verb),
				err  = tostring(reply_err),
			})
		end
	end
end

return M
