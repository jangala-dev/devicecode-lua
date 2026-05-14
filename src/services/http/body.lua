-- services/http/body.lua
-- Shared HTTP body object-capability helpers.  The bus may carry local Lua
-- capabilities with the right shape.  It must not carry inline bulk bytes in
-- control-plane fields.

local fibers = require 'fibers'

local M = {}

local function has_method(obj, name)
	return type(obj) == 'table' and type(obj[name]) == 'function'
end

local function reject_inline_bytes(args)
	args = args or {}
	if args.body ~= nil or args.body_string ~= nil or args.body_chunks ~= nil or args.response_body ~= nil then return nil, 'invalid_args' end
	if args.data ~= nil or args.chunk ~= nil or args.chunks ~= nil or args.bytes ~= nil then return nil, 'invalid_args' end
	return true, nil
end

function M.validate_source(source)
	if source == nil then return nil, nil end
	if not has_method(source, 'read_chunk_op') then return nil, 'invalid_args' end
	if not has_method(source, 'terminate') then return nil, 'invalid_args' end
	return source, nil
end

function M.validate_sink(sink)
	if sink == nil then return nil, nil end
	if not has_method(sink, 'write_chunk_op') then return nil, 'invalid_args' end
	if not has_method(sink, 'terminate') then return nil, 'invalid_args' end
	if sink.finish_op ~= nil and type(sink.finish_op) ~= 'function' then return nil, 'invalid_args' end
	if sink.commit_op ~= nil and type(sink.commit_op) ~= 'function' then return nil, 'invalid_args' end
	return sink, nil
end

function M.validate_exchange_bodies(args)
	args = args or {}
	local ok, berr = reject_inline_bytes(args)
	if not ok then return nil, berr end
	local source, serr = M.validate_source(args.body_source)
	if serr then return nil, serr end
	local sink, skerr = M.validate_sink(args.response_sink)
	if skerr then return nil, skerr end
	return { source = source, sink = sink }, nil
end

local function terminate(obj, reason)
	if obj and type(obj.terminate) == 'function' then return obj:terminate(reason) end
	return true
end

function M.terminate(obj, reason)
	return terminate(obj, reason)
end

local function unwrap_scope_result(scope_op)
	return scope_op:wrap(function (st, _rep, result_or_primary, err)
		if st == 'ok' then
			if result_or_primary == nil and err ~= nil then return nil, err end
			return result_or_primary, nil
		end
		return nil, result_or_primary or st
	end)
end

function M.copy_response_to_sink_op(response, sink, opts)
	opts = opts or {}
	return unwrap_scope_result(fibers.run_scope_op(function ()
		local max_chunk = opts.max_chunk or 65536
		local limit = opts.max_bytes or math.huge
		local copied = 0
		while true do
			local chunk, err = fibers.perform(response:read_chunk_op(max_chunk))
			if chunk == nil then
				if err then return nil, err end
				break
			end
			copied = copied + #chunk
			if copied > limit then return nil, opts.too_large_error or 'response_body_too_large' end
			local ok, werr = fibers.perform(sink:write_chunk_op(chunk))
			if not ok then return nil, werr end
		end
		if sink.finish_op then
			local ok, ferr = fibers.perform(sink:finish_op())
			if not ok then return nil, ferr end
		elseif sink.commit_op then
			local ok, ferr = fibers.perform(sink:commit_op())
			if not ok then return nil, ferr end
		end
		return { bytes = copied }
	end))
end

function M.drain_response_op(response, opts)
	opts = opts or {}
	return unwrap_scope_result(fibers.run_scope_op(function ()
		local max_chunk = opts.max_chunk or 65536
		local limit = opts.max_bytes or math.huge
		local copied = 0
		while true do
			local chunk, err = fibers.perform(response:read_chunk_op(max_chunk))
			if chunk == nil then
				if err then return nil, err end
				break
			end
			copied = copied + #chunk
			if copied > limit then return nil, opts.too_large_error or 'response_body_too_large' end
		end
		return { bytes = copied }
	end))
end

function M.copy_source_to_sink_op(source, sink, opts)
	opts = opts or {}
	return unwrap_scope_result(fibers.run_scope_op(function ()
		local max_chunk = opts.max_chunk or 65536
		local limit = opts.max_bytes or math.huge
		local copied = 0
		while true do
			local chunk, err = fibers.perform(source:read_chunk_op(max_chunk))
			if chunk == nil then
				if err then return nil, err end
				break
			end
			copied = copied + #chunk
			if copied > limit then return nil, opts.too_large_error or 'request_body_too_large' end
			local ok, werr = fibers.perform(sink:write_chunk_op(chunk))
			if not ok then return nil, werr end
		end
		if sink.finish_op then
			local ok, ferr = fibers.perform(sink:finish_op())
			if not ok then return nil, ferr end
		elseif sink.commit_op then
			local ok, ferr = fibers.perform(sink:commit_op())
			if not ok then return nil, ferr end
		end
		return { bytes = copied }
	end))
end

return M
