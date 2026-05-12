-- services/ui/update/artifact_ingest.lua
--
-- Strict boundary around artifact ingest providers.
--
-- Production ingest providers must expose Op-returning methods for all
-- potentially blocking work and an immediate abort_now() method for finalisers.
-- This module deliberately does not wrap raw append/write/commit/close methods
-- in guards, because that would hide blocking provider calls behind an Op shape.

local op = require 'fibers.op'

local M = {}

local function is_op(v)
	return type(v) == 'table' and getmetatable(v) == op.Op
end

local function require_op_method(obj, method, owner)
	if type(obj) ~= 'table' or type(obj[method]) ~= 'function' then
		return nil, (owner or 'artifact ingest object') .. ' must expose ' .. method
	end
	return obj[method], nil
end

local function call_op_method(obj, method, owner, ...)
	local fn, err = require_op_method(obj, method, owner)
	if not fn then return op.always(nil, err) end

	local ok, ev_or_err = pcall(function (...)
		return fn(obj, ...)
	end, ...)

	if not ok then
		return op.always(nil, tostring(ev_or_err))
	end
	if not is_op(ev_or_err) then
		return op.always(nil, (owner or 'artifact ingest object') .. ' ' .. method .. ' must return an Op')
	end
	return ev_or_err
end

function M.open_ingest_op(client, opts)
	return call_op_method(client, 'open_ingest_op', 'artifact ingest client', opts)
end

function M.append_chunk_op(handle, chunk)
	return call_op_method(handle, 'append_chunk_op', 'artifact ingest handle', chunk)
end

function M.commit_op(handle)
	return call_op_method(handle, 'commit_op', 'artifact ingest handle')
end

function M.abort_now(handle, reason)
	if handle == nil then return true, nil end
	if type(handle) ~= 'table' or type(handle.abort_now) ~= 'function' then
		return nil, 'artifact ingest handle must expose immediate abort_now'
	end

	local ok, a, b = pcall(function ()
		return handle:abort_now(reason)
	end)
	if not ok then
		return nil, tostring(a)
	end
	if is_op(a) then
		return nil, 'artifact ingest abort_now must be immediate and must not return an Op'
	end
	if a == nil and b == nil then return true, nil end
	if a == true then return true, nil end
	if a == false or a == nil then return nil, b or 'artifact ingest abort_now failed' end
	return true, nil
end


local BusHandle = {}
BusHandle.__index = BusHandle

local function ingest_rpc(method)
	return { 'cap', 'artifact-ingest', 'main', 'rpc', method }
end

local function request_timeout(opts)
	opts = opts or {}
	return { timeout = opts.timeout or opts.call_timeout or 10.0 }
end

local function ingest_id_from(reply, fallback)
	local rec = type(reply) == 'table' and (reply.ingest or reply.record or reply) or nil
	return rec and (rec.ingest_id or rec.id) or fallback
end

local function artifact_ref_from(value, depth)
	if type(value) == 'string' and value ~= '' then return value end
	if type(value) ~= 'table' or (depth or 0) > 4 then return nil end
	depth = (depth or 0) + 1

	for _, key in ipairs({ 'artifact_ref', 'artifact_id', 'ref', 'id' }) do
		if type(value[key]) == 'string' and value[key] ~= '' then return value[key] end
	end

	if type(value.ref) == 'function' then
		local ok, ref = pcall(value.ref, value)
		if ok and type(ref) == 'string' and ref ~= '' then return ref end
	end

	if type(value.describe) == 'function' then
		local ok, desc = pcall(value.describe, value)
		if ok then
			local ref = artifact_ref_from(desc, depth)
			if ref then return ref end
		end
	end

	for _, key in ipairs({ 'artifact', 'commit', 'result', 'record', 'value' }) do
		local ref = artifact_ref_from(value[key], depth)
		if ref then return ref end
	end

	return nil
end

function BusHandle:append_chunk_op(chunk)
	if self._closed then return op.always(nil, 'artifact_ingest_handle_closed') end
	return self._conn:call_op(ingest_rpc('append'), {
		ingest_id = self.ingest_id,
		chunk = chunk,
	}, request_timeout(self._opts))
end

function BusHandle:commit_op()
	if self._closed then return op.always(nil, 'artifact_ingest_handle_closed') end
	self._closed = true
	return self._conn:call_op(ingest_rpc('commit'), {
		ingest_id = self.ingest_id,
	}, request_timeout(self._opts)):wrap(function (reply, err)
		if reply == nil or err ~= nil then return nil, err end
		if type(reply) ~= 'table' then return reply end
		local committed = reply.commit or reply.artifact or reply.result or reply
		if type(committed) == 'table' then
			return artifact_ref_from(committed) or committed
		end
		return committed
	end)
end

function BusHandle:abort_now(reason)
	self._closed = true
	self._abort_reason = reason or 'artifact_ingest_aborted'
	return true, nil
end

local BusClient = {}
BusClient.__index = BusClient

function BusClient:open_ingest_op(opts)
	opts = opts or {}
	local ingest_id = opts.ingest_id or opts.id or ('ui-upload-' .. tostring(math.floor((os.clock() or 0) * 1000000)))
	local sink = opts.sink or opts.artifact_sink
	return self._conn:call_op(ingest_rpc('create'), {
		ingest_id = ingest_id,
		id = ingest_id,
		component = opts.component or opts.target_component or opts.update_component,
		sink = sink,
		metadata = opts.metadata or opts.meta,
	}, request_timeout(opts)):wrap(function (reply, err)
		if reply == nil or err ~= nil then return nil, err end
		return setmetatable({
			_conn = self._conn,
			_opts = opts,
			ingest_id = ingest_id_from(reply, ingest_id),
			_closed = false,
		}, BusHandle)
	end)
end

function M.bus_client(conn)
	if not conn then return nil, 'artifact ingest bus client requires conn' end
	return setmetatable({ _conn = conn }, BusClient)
end

M._test = { is_op = is_op }

return M
