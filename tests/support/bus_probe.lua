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


function M.wait_changed_until(label, changed_op_fn, version_fn, pred, opts)
	opts = opts or {}
	local timeout = opts.timeout or 1.0
	local v = pred()
	if v then return v end

	local seen = version_fn()
	while true do
		local which = fibers.perform(op.named_choice({
			changed = changed_op_fn(seen):wrap(function(version)
				seen = version or seen
			end),
			timeout = sleep.sleep_op(timeout),
		}))
		if which == 'timeout' then
			fail('timed out waiting for ' .. tostring(label))
		end
		v = pred()
		if v then return v end
	end
end

function M.wait_holder(label, holder, pred, opts)
	return M.wait_changed_until(label,
		function(seen) return holder:changed_op(seen) end,
		function() return holder:version() end,
		pred,
		opts)
end


local function topic_label(topic)
	local parts = {}
	for i = 1, #(topic or {}) do parts[#parts + 1] = tostring(topic[i]) end
	return table.concat(parts, '/')
end

function M.wait_versioned_until(label, version_fn, changed_op_fn, pred, opts)
	opts = opts or {}
	local timeout = opts.timeout or 1.0

	local v = pred()
	if v then return v end

	local seen = version_fn()
	while true do
		local which, version, reason = fibers.perform(op.named_choice({
			changed = changed_op_fn(seen),
			timeout = sleep.sleep_op(timeout),
		}))

		if which == 'timeout' then
			fail('timed out waiting for ' .. tostring(label))
		end
		if version == nil then
			fail(tostring(label) .. ' closed: ' .. tostring(reason or 'closed'))
		end

		seen = version
		v = pred()
		if v then return v end
	end
end

local function retained_view_for(conn, topic, opts)
	local view = opts.view
	if view then return view, false end

	if type(conn.retained_view) ~= 'function' then
		fail('retained_view support is required for retained-state assertions')
	end

	return conn:retained_view(opts.view_topic or topic, opts.view_opts), true
end

function M.wait_retained_message(conn, topic, opts)
	opts = opts or {}

	local view, own_view = retained_view_for(conn, topic, opts)
	local msg = M.wait_versioned_until(
		'retained topic ' .. topic_label(topic),
		function() return view:version() end,
		function(seen) return view:changed_op(seen) end,
		function() return view:get(topic) end,
		opts
	)

	if own_view then view:close() end
	return msg
end

function M.wait_retained_payload(conn, topic, opts)
	local msg = M.wait_retained_message(conn, topic, opts)
	return msg.payload, msg
end

function M.wait_retained_absent(conn, topic, opts)
	opts = opts or {}

	local view, own_view = retained_view_for(conn, topic, opts)

	local function absent()
		if view:get(topic) == nil then return true end
		return nil
	end

	if opts.since == nil then
		local v = absent()
		if v then
			if own_view then view:close() end
			return v
		end
	end

	local timeout = opts.timeout or 1.0
	local seen = opts.since or view:version()
	while true do
		local which, version, reason = fibers.perform(op.named_choice({
			changed = view:changed_op(seen),
			timeout = sleep.sleep_op(timeout),
		}))

		if which == 'timeout' then
			fail('timed out waiting for retained removal ' .. topic_label(topic))
		end
		if version == nil then
			fail('retained view closed: ' .. tostring(reason or 'closed'))
		end

		seen = version
		local v = absent()
		if v then
			if own_view then view:close() end
			return v
		end
	end
end

function M.wait_message(conn, topic, opts)
	opts = opts or {}
	local timeout = opts.timeout or 1.0
	local sub = opts.sub or conn:subscribe(topic, {
		queue_len = opts.queue_len or 8,
		full      = opts.full or 'drop_oldest',
	})
	local own_sub = (opts.sub == nil)

	local which, a, b = fibers.perform(op.named_choice({
		msg = sub:recv_op(),
		timeout = sleep.sleep_op(timeout):wrap(function()
			return true
		end),
	}))

	if own_sub then
		sub:unsubscribe()
	end

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
