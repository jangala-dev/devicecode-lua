-- tests/support/bus_probe.lua

local fibers = require 'fibers'
local sleep  = require 'fibers.sleep'
local op     = require 'fibers.op'

local M = {}

local function fail(msg)
	error(msg, 0)
end

function M.wait_until(pred, opts)
	opts = opts or {}
	local timeout  = opts.timeout or 1.0
	local interval = opts.interval or 0.005
	local deadline = fibers.now() + timeout

	while fibers.now() < deadline do
		if pred() then
			return true
		end
		sleep.sleep(interval)
	end

	return pred()
end

function M.wait_message(conn, topic, opts)
	opts = opts or {}
	local timeout = opts.timeout or 1.0
	local sub = conn:subscribe(topic, {
		queue_len = opts.queue_len or 8,
		full      = opts.full or 'drop_oldest',
	})

	local which, a, b = fibers.perform(op.named_choice({
		msg = sub:recv_op(),
		timeout = sleep.sleep_op(timeout):wrap(function()
			return true
		end),
	}))

	sub:unsubscribe()

	if which == 'timeout' then
		fail(('timed out waiting for topic %s'):format(tostring(topic[1] or '?')))
	end

	local msg, err = a, b
	if not msg then
		fail('subscription ended: ' .. tostring(err))
	end
	return msg
end

function M.wait_payload(conn, topic, opts)
	local msg = M.wait_message(conn, topic, opts)
	return msg.payload, msg
end

function M.wait_retained_message(conn, topic, opts)
	opts = opts or {}
	local timeout = opts.timeout or 1.0
	local watch = conn:watch_retained(topic, {
		replay = true,
		queue_len = opts.queue_len or 8,
		full = opts.full or 'drop_oldest',
	})

	local pred = opts.predicate
	local deadline = fibers.now() + timeout
	while fibers.now() < deadline do
		local remaining = deadline - fibers.now()
		local which, a, b = fibers.perform(op.named_choice({
			ev = watch:recv_op(),
			timeout = sleep.sleep_op(remaining):wrap(function() return true end),
		}))
		if which == 'timeout' then
			pcall(function() watch:unwatch() end)
			fail(('timed out waiting for retained topic %s'):format(tostring(topic[1] or '?')))
		end
		local ev, err = a, b
		if not ev then
			pcall(function() watch:unwatch() end)
			fail('retained watch ended: ' .. tostring(err))
		end
		if ev.op == 'retain' and (pred == nil or pred(ev.payload, ev)) then
			pcall(function() watch:unwatch() end)
			return ev
		end
	end
	pcall(function() watch:unwatch() end)
	fail(('timed out waiting for retained topic %s'):format(tostring(topic[1] or '?')))
end

function M.wait_retained_payload(conn, topic, opts)
	local ev = M.wait_retained_message(conn, topic, opts)
	return ev.payload, ev
end

function M.collect_messages(conn, topic, count, opts)
	opts = opts or {}
	local timeout = opts.timeout or 1.0
	local sub = conn:subscribe(topic, {
		queue_len = opts.queue_len or math.max(count, 8),
		full      = opts.full or 'drop_oldest',
	})

	local out = {}
	while #out < count do
		local which, a, b = fibers.perform(op.named_choice({
			msg = sub:recv_op(),
			timeout = sleep.sleep_op(timeout):wrap(function()
				return true
			end),
		}))

		if which == 'timeout' then
			sub:unsubscribe()
			fail(('timed out collecting %d messages; got %d'):format(count, #out))
		end

		local msg, err = a, b
		if not msg then
			sub:unsubscribe()
			fail('subscription ended: ' .. tostring(err))
		end
		out[#out + 1] = msg
	end

	sub:unsubscribe()
	return out
end

return M
