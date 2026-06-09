local fibers    = require 'fibers'
local op        = require 'fibers.op'
local scope_mod = require 'fibers.scope'

local hal_types = require 'services.hal.types.core'

local perform = fibers.perform

local M = {}

local function elapsed_ms(t0)
	if not t0 then return nil end
	return math.floor(((fibers.now() - t0) * 1000) + 0.5)
end

local function dlog(logger, level, payload)
	if logger and logger[level] then
		logger[level](logger, payload)
	end
end

local function err_text(v)
	if type(v) == 'table' then
		return tostring(v.err or v.reason or v.message or v.code or 'structured_error')
	end
	if v ~= nil then return tostring(v) end
	return nil
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
			if sent ~= false then
				return true, nil
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

	scope:finally(function (_, status, primary)
		dlog(logger, 'debug', {
			what    = tostring(what or 'control_loop') .. '_exiting',
			status  = tostring(status),
			primary = primary and tostring(primary) or nil,
		})
	end)

	while true do
		local request, req_err = perform(ch:get_op())
		if not request then
			dlog(logger, 'debug', {
				what = tostring(what or 'control_loop') .. '_closed',
				err  = tostring(req_err or 'control channel closed'),
			})
			return
		end

		local loop_name = tostring(what or 'control_loop')
		local trace_control = loop_name:match('^network_') ~= nil
		local req_t0 = fibers.now()
		if trace_control then
			dlog(logger, 'info', {
				what = loop_name .. '_request_begin',
				verb = tostring(request.verb),
			})
		end

		local ok, value_or_err
		local caller_cancelled = false
		if request.cancel_op ~= nil then
			local which, a, b = perform(op.named_choice({
				work = M.evaluate_request_op(methods, request),
				cancel = request.cancel_op,
			}))
			if which == 'cancel' and a ~= nil and a ~= false then
				caller_cancelled = true
				dlog(logger, trace_control and 'warn' or 'debug', {
					what = loop_name .. '_request_cancelled',
					verb = tostring(request.verb),
					reason = tostring(a),
					elapsed_ms = elapsed_ms(req_t0),
				})
			else
				ok, value_or_err = a, b
				if trace_control then
					dlog(logger, ok == true and 'info' or 'warn', {
						what = loop_name .. '_method_done',
						verb = tostring(request.verb),
						ok = ok == true,
						err = ok == true and nil or err_text(value_or_err),
						elapsed_ms = elapsed_ms(req_t0),
					})
				end
			end
		else
			ok, value_or_err = perform(M.evaluate_request_op(methods, request))
			if trace_control then
				dlog(logger, ok == true and 'info' or 'warn', {
					what = loop_name .. '_method_done',
					verb = tostring(request.verb),
					ok = ok == true,
					err = ok == true and nil or err_text(value_or_err),
					elapsed_ms = elapsed_ms(req_t0),
				})
			end
		end

		if not caller_cancelled then
			local reply_t0 = fibers.now()
			local replied, reply_err
			if request.cancel_op ~= nil then
				local which, a, b = perform(op.named_choice({
					reply = M.reply_op(request.reply_ch, ok, value_or_err),
					cancel = request.cancel_op,
				}))
				if which == 'cancel' and a ~= nil and a ~= false then
					caller_cancelled = true
					if trace_control then
						dlog(logger, 'warn', {
							what = loop_name .. '_reply_cancelled',
							verb = tostring(request.verb),
							reason = tostring(a),
							elapsed_ms = elapsed_ms(req_t0),
						})
					end
				else
					replied, reply_err = a, b
				end
			else
				replied, reply_err = perform(M.reply_op(request.reply_ch, ok, value_or_err))
			end
			if not caller_cancelled and not replied then
				dlog(logger, 'warn', {
					what = loop_name .. '_reply_failed',
					verb = tostring(request.verb),
					err  = tostring(reply_err),
					elapsed_ms = elapsed_ms(req_t0),
					reply_elapsed_ms = elapsed_ms(reply_t0),
				})
			elseif trace_control and not caller_cancelled then
				dlog(logger, 'info', {
					what = loop_name .. '_reply_done',
					verb = tostring(request.verb),
					elapsed_ms = elapsed_ms(req_t0),
					reply_elapsed_ms = elapsed_ms(reply_t0),
				})
			end
		end
	end
end

return M
