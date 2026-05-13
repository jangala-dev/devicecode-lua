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
	return { timeout = opts.timeout or 10.0 }
end

local function ingest_id_from(reply, fallback)
	local rec = type(reply) == 'table' and (reply.ingest or reply.record or reply) or nil
	return rec and rec.ingest_id or fallback
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
		if type(reply) ~= 'table' then return nil, 'invalid_artifact_ingest_commit_reply' end
		local committed = reply.commit
		if type(committed) ~= 'table' then return nil, 'invalid_artifact_ingest_commit_reply' end
		local artifact = committed.artifact
		if type(artifact) == 'table' then
			return artifact.artifact_id or artifact.ref or artifact.id or artifact
		end
		return committed.artifact_id or committed.ref or committed.id or artifact
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
	local ingest_id = opts.ingest_id or ('ui-upload-' .. tostring(math.floor((os.clock() or 0) * 1000000)))
	local sink = opts.sink
	return self._conn:call_op(ingest_rpc('create'), {
		ingest_id = ingest_id,
		component = opts.component,
		sink = sink,
		metadata = opts.metadata,
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
