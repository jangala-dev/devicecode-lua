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


local function topic_string(topic)
	if type(topic) ~= 'table' then return tostring(topic) end
	local parts = {}
	for i = 1, #topic do parts[i] = tostring(topic[i]) end
	return table.concat(parts, '/')
end

local function fail_with_context(prefix, topic, describe)
	local msg = prefix
	if topic ~= nil then
		msg = msg .. ' [' .. topic_string(topic) .. ']'
	end
	if type(describe) == 'function' then
		local ok, extra = pcall(describe)
		if ok and extra and extra ~= '' then
			msg = msg .. '\n' .. tostring(extra)
		end
	elseif describe ~= nil then
		msg = msg .. '\n' .. tostring(describe)
	end
	fail(msg)
end

function M.wait_retained_state(conn, topic, pred, opts)
	opts = opts or {}
	pred = pred or function() return true end
	local timeout = opts.timeout or 1.0
	local watch = conn:watch_retained(topic, {
		replay = (opts.replay ~= false),
		queue_len = opts.queue_len or 16,
		full = opts.full or 'drop_oldest',
	})
	local deadline = fibers.now() + timeout
	local last_predicate_err
	while true do
		local remaining = deadline - fibers.now()
		if remaining <= 0 then
			pcall(function() watch:unwatch() end)
			local function describe()
				local parts = {}
				if last_predicate_err ~= nil then
					parts[#parts + 1] = 'last predicate error: ' .. tostring(last_predicate_err)
				end
				if type(opts.describe) == 'function' then
					local ok, extra = pcall(opts.describe)
					if ok and extra and extra ~= '' then parts[#parts + 1] = tostring(extra) end
				elseif opts.describe ~= nil then
					parts[#parts + 1] = tostring(opts.describe)
				end
				return table.concat(parts, '\n')
			end
			fail_with_context('timed out waiting for retained state', topic, describe)
		end
		local which, a, b = fibers.perform(op.named_choice({
			ev = watch:recv_op(),
			timeout = sleep.sleep_op(remaining):wrap(function() return true end),
		}))
		if which == 'timeout' then
			pcall(function() watch:unwatch() end)
			local function describe()
				local parts = {}
				if last_predicate_err ~= nil then
					parts[#parts + 1] = 'last predicate error: ' .. tostring(last_predicate_err)
				end
				if type(opts.describe) == 'function' then
					local ok, extra = pcall(opts.describe)
					if ok and extra and extra ~= '' then parts[#parts + 1] = tostring(extra) end
				elseif opts.describe ~= nil then
					parts[#parts + 1] = tostring(opts.describe)
				end
				return table.concat(parts, '\n')
			end
			fail_with_context('timed out waiting for retained state', topic, describe)
		end
		local ev, err = a, b
		if not ev then
			pcall(function() watch:unwatch() end)
			fail_with_context('retained watch ended: ' .. tostring(err), topic, opts.describe)
		end
		if ev.op == 'retain' then
			local ok, matched = pcall(pred, ev.payload, ev)
			if ok then
				last_predicate_err = nil
				if matched then
					pcall(function() watch:unwatch() end)
					return ev.payload, ev
				end
			else
				last_predicate_err = matched
			end
		end
	end
end

function M.wait_service_running(conn, service_or_topic, opts)
	local topic = service_or_topic
	if type(service_or_topic) == 'string' then
		topic = { 'svc', service_or_topic, 'status' }
	end
	return M.wait_retained_state(conn, topic, function(payload)
		return type(payload) == 'table' and payload.state == 'running' and payload.ready == true
	end, opts)
end

function M.wait_workflow(conn, family, id, pred, opts)
	return M.wait_retained_state(conn, { 'state', 'workflow', family, id }, pred, opts)
end

function M.wait_update_job(conn, id, pred, opts)
	return M.wait_workflow(conn, 'update-job', id, function(payload, ev)
		return type(payload) == 'table' and type(payload.job) == 'table' and (pred == nil or pred(payload, ev))
	end, opts)
end

function M.wait_artifact_ingest(conn, id, pred, opts)
	return M.wait_workflow(conn, 'artifact-ingest', id, function(payload, ev)
		return type(payload) == 'table' and type(payload.ingest) == 'table' and (pred == nil or pred(payload, ev))
	end, opts)
end

function M.wait_device_component(conn, component, pred, opts)
	return M.wait_retained_state(conn, { 'state', 'device', 'component', component }, function(payload, ev)
		return type(payload) == 'table' and (pred == nil or pred(payload, ev))
	end, opts)
end

function M.wait_update_component(conn, component, pred, opts)
	return M.wait_retained_state(conn, { 'state', 'update', 'component', component }, function(payload, ev)
		return type(payload) == 'table' and (pred == nil or pred(payload, ev))
	end, opts)
end


function M.wait_raw_source_status(conn, kind, source, pred, opts)
	return M.wait_retained_state(conn, { 'raw', kind, source, 'status' }, function(payload, ev)
		return type(payload) == 'table' and (pred == nil or pred(payload, ev))
	end, opts)
end

function M.wait_raw_source_state(conn, kind, source, suffix, pred, opts)
	local topic = { 'raw', kind, source, 'state' }
	if type(suffix) == 'table' then
		for i = 1, #suffix do topic[#topic + 1] = suffix[i] end
	elseif suffix ~= nil then
		topic[#topic + 1] = suffix
	else
		pred, opts = pred or function() return true end, opts
	end
	return M.wait_retained_state(conn, topic, function(payload, ev)
		return type(payload) == 'table' and (pred == nil or pred(payload, ev))
	end, opts)
end

function M.wait_fabric_summary(conn, pred, opts)
	return M.wait_retained_state(conn, { 'state', 'fabric' }, function(payload, ev)
		return type(payload) == 'table' and (pred == nil or pred(payload, ev))
	end, opts)
end

function M.wait_fabric_link_component(conn, link_id, component, pred, opts)
	return M.wait_retained_state(conn, { 'state', 'fabric', 'link', link_id, component }, function(payload, ev)
		return type(payload) == 'table' and (pred == nil or pred(payload, ev))
	end, opts)
end

function M.wait_fabric_link_ready(conn, link_id, opts)
	return M.wait_fabric_link_component(conn, link_id, 'session', function(payload)
		local s = payload and payload.status
		return type(s) == 'table' and s.ready == true and s.state == 'ready'
	end, opts)
end


function M.wait_fabric_ready(conn, link_id, opts)
	return M.wait_fabric_link_session(conn, link_id, function(payload)
		local s = payload and payload.status
		return type(s) == 'table' and s.ready == true
	end, opts)
end

function M.wait_transfer_manager_status(conn, pred, opts)
	return M.wait_cap_status(conn, 'transfer-manager', 'main', pred, opts)
end

function M.wait_fabric_link_session(conn, link_id, pred, opts)
	return M.wait_retained_state(conn, { 'state', 'fabric', 'link', link_id, 'session' }, function(payload, ev)
		return type(payload) == 'table' and (pred == nil or pred(payload, ev))
	end, opts)
end

function M.wait_cap_status(conn, class, id, pred, opts)
	return M.wait_retained_state(conn, { 'cap', class, id, 'status' }, function(payload, ev)
		return type(payload) == 'table' and (pred == nil or pred(payload, ev))
	end, opts)
end

function M.wait_cap_event(conn, class, id, event_name, pred, opts)
	opts = opts or {}
	local msg = M.wait_message(conn, { 'cap', class, id, 'event', event_name }, {
		timeout = opts.timeout or 1.0,
		queue_len = opts.queue_len or 8,
		full = opts.full or 'drop_oldest',
	})
	local payload = msg.payload
	if pred and not pred(payload, msg) then
		fail_with_context('unexpected cap event payload', { 'cap', class, id, 'event', event_name }, opts.describe)
	end
	return payload, msg
end

function M.wait_component_cap_status(conn, component, pred, opts)
	return M.wait_cap_status(conn, 'component', component, pred, opts)
end

function M.wait_component_event(conn, component, event_name, pred, opts)
	return M.wait_cap_event(conn, 'component', component, event_name, pred, opts)
end

function M.wait_ui_summary(conn, pred, opts)
	return M.wait_retained_state(conn, { 'state', 'ui', 'summary' }, function(payload, ev)
		return type(payload) == 'table' and (pred == nil or pred(payload, ev))
	end, opts)
end

return M
