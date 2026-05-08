-- services/support/bus_cleanup.lua
--
-- Immediate local-bus cleanup and publication helpers.
--
-- Fabric treats the in-process bus methods named here as immediate and
-- non-yielding. These wrappers make that assumption explicit at call sites and
-- keep finalisers/coordinators away from Op-based close or receive paths.
--
-- This module must not call fibers.perform, op.perform_raw, sleep, close_op, or
-- any other readiness wait.

local M = {}

local function stringify(err, fallback)
	if err == nil then
		return fallback or 'bus cleanup failed'
	end
	return tostring(err)
end

local function labelled_error(label, err)
	local msg = stringify(err, label or 'bus cleanup failed')
	if label ~= nil and msg ~= tostring(label) then
		return tostring(label) .. ': ' .. msg
	end
	return msg
end

local function normalise_result(a, b, fallback)
	if a == false then
		return nil, labelled_error(fallback, b)
	end

	-- Most bus methods return true on success. Some legacy immediate cleanup
	-- methods are idempotent and return no values; accept nil,nil as success.
	if a == nil and b ~= nil then
		return nil, labelled_error(fallback, b)
	end

	return true, nil
end

local function invoke(label, target, method, ...)
	if target == nil then
		return true, nil
	end

	local fn
	local self

	if type(target) == 'function' and method == nil then
		fn = target
		self = nil
	elseif type(target) == 'table' and type(method) == 'string' then
		fn = target[method]
		self = target
	elseif type(method) == 'function' then
		fn = method
		self = target
	else
		return nil, (label or 'bus_cleanup') .. ': invalid target/method'
	end

	if type(fn) ~= 'function' then
		return nil, (label or 'bus_cleanup') .. ': method not available'
	end

	if type(target) == 'table' and type(target.close_op) == 'function'
		and (method == 'close' or method == 'unsubscribe' or method == 'unbind' or method == 'unwatch')
		and type(target[method]) ~= 'function'
	then
		return nil, (label or 'bus_cleanup') .. ': close_op-only resources are not immediate bus cleanup'
	end

	local ok, a, b = pcall(function (...)
		if self ~= nil then
			return fn(self, ...)
		end
		return fn(...)
	end, ...)

	if not ok then
		return nil, (label or 'bus_cleanup') .. ': ' .. stringify(a, 'raised')
	end

	return normalise_result(a, b, label or 'bus_cleanup')
end

function M.call_now(label, target, method, ...)
	return invoke(label, target, method, ...)
end

function M.checked(label, target, method, ...)
	local ok, err = invoke(label, target, method, ...)
	if ok ~= true then
		error(err or label or 'bus cleanup failed', 2)
	end
	return true, nil
end

function M.publish(conn, topic, payload, opts)
	return invoke('bus publish failed', conn, 'publish', topic, payload, opts)
end

function M.retain(conn, topic, payload, opts)
	return invoke('bus retain failed', conn, 'retain', topic, payload, opts)
end

function M.unretain(conn, topic, opts)
	return invoke('bus unretain failed', conn, 'unretain', topic, opts)
end

function M.subscribe(conn, topic, opts)
	if conn == nil or type(conn.subscribe) ~= 'function' then
		return nil, 'bus subscribe failed: method not available'
	end

	local ok, sub_or_err = pcall(function ()
		return conn:subscribe(topic, opts)
	end)

	if not ok then
		return nil, 'bus subscribe failed: ' .. stringify(sub_or_err, 'raised')
	end

	if sub_or_err == nil then
		return nil, 'bus subscribe failed'
	end

	return sub_or_err, nil
end

function M.bind(conn, topic, opts)
	if conn == nil or type(conn.bind) ~= 'function' then
		return nil, 'bus bind failed: method not available'
	end

	local ok, ep_or_err = pcall(function ()
		return conn:bind(topic, opts)
	end)

	if not ok then
		return nil, 'bus bind failed: ' .. stringify(ep_or_err, 'raised')
	end

	if ep_or_err == nil then
		return nil, 'bus bind failed'
	end

	return ep_or_err, nil
end

function M.watch_retained(conn, topic, opts)
	if conn == nil or type(conn.watch_retained) ~= 'function' then
		return nil, 'bus watch_retained failed: method not available'
	end

	local ok, watch_or_err = pcall(function ()
		return conn:watch_retained(topic, opts)
	end)

	if not ok then
		return nil, 'bus watch_retained failed: ' .. stringify(watch_or_err, 'raised')
	end

	if watch_or_err == nil then
		return nil, 'bus watch_retained failed'
	end

	return watch_or_err, nil
end

function M.unsubscribe(conn, sub)
	if conn ~= nil and type(conn.unsubscribe) == 'function' then
		return invoke('bus unsubscribe failed', conn, 'unsubscribe', sub)
	end
	return invoke('bus unsubscribe failed', sub, 'unsubscribe')
end

function M.unwatch_retained(conn, watch)
	if conn ~= nil and type(conn.unwatch_retained) == 'function' then
		return invoke('bus unwatch_retained failed', conn, 'unwatch_retained', watch)
	end
	return invoke('bus unwatch_retained failed', watch, 'unwatch')
end

function M.unbind(conn, ep)
	if conn ~= nil and type(conn.unbind) == 'function' then
		return invoke('bus unbind failed', conn, 'unbind', ep)
	end
	return invoke('bus unbind failed', ep, 'unbind')
end

function M.disconnect(conn)
	return invoke('bus disconnect failed', conn, 'disconnect')
end

function M.close_feed(feed)
	return invoke('bus feed close failed', feed, 'close')
end

function M.reply(req, value)
	local ok, err = invoke('bus reply failed', req, 'reply', value)
	if ok ~= true then
		return nil, err
	end
	return true, nil
end

function M.fail(req, reason)
	local ok, err = invoke('bus fail failed', req, 'fail', reason)
	if ok ~= true then
		return nil, err
	end
	return true, nil
end

return M
