-- services/http/body.lua
-- Descriptor validation and service-owned source/sink lease registries. Bytes do
-- not travel over the bus; descriptors are resolved to local leases inside
-- operation scopes.

local fibers = require 'fibers'
local op     = require 'fibers.op'

local M = {}
local Registry = {}
Registry.__index = Registry

local function copy(t)
	local out = {}
	for k, v in pairs(t or {}) do out[k] = v end
	return out
end

local function is_descriptor(desc)
	return type(desc) == 'table' and type(desc.kind) == 'string' and desc.kind ~= ''
end

function M.validate_descriptor(desc, direction)
	if desc == nil then return nil, nil end
	if type(desc) ~= 'table' then return nil, 'invalid_args' end
	if type(desc.kind) ~= 'string' or desc.kind == '' then return nil, 'invalid_args' end
	-- Keep raw bytes, hidden iterators and handles off the bus/control plane.
	if desc.data ~= nil or desc.chunk ~= nil or desc.chunks ~= nil or desc.body ~= nil then return nil, 'invalid_args' end
	if desc.handle ~= nil or desc.object ~= nil or desc.iterator ~= nil or desc.file ~= nil then return nil, 'invalid_args' end
	if desc.bytes ~= nil and (type(desc.bytes) ~= 'number' or desc.bytes < 0) then return nil, 'invalid_args' end
	if desc.direction ~= nil and direction ~= nil and desc.direction ~= direction then return nil, 'invalid_args' end
	local out = copy(desc)
	out.direction = direction or out.direction
	return out, nil
end

function M.validate_exchange_descriptors(args)
	args = args or {}
	if args.body ~= nil or args.body_chunks ~= nil or args.response_body ~= nil or args.body_string ~= nil then
		return nil, 'invalid_args'
	end
	local source, serr = M.validate_descriptor(args.body_source or args.source, 'source')
	if serr then return nil, serr end
	local sink, skerr = M.validate_descriptor(args.response_sink or args.sink, 'sink')
	if skerr then return nil, skerr end
	return { source = source, sink = sink }, nil
end

local function normalise_resolver_result(value, err)
	if value == nil then return nil, err or 'invalid_args' end
	if type(value) ~= 'table' then return nil, 'invalid_args' end
	return value, nil
end

function M.new_registry(opts)
	opts = opts or {}
	local self = setmetatable({ _resolvers = {} }, Registry)
	for kind, resolver in pairs(opts.resolvers or opts or {}) do
		if type(kind) == 'string' and type(resolver) == 'function' then
			self:register_resolver(kind, resolver)
		end
	end
	return self
end

function Registry:register_resolver(kind, resolver)
	if type(kind) ~= 'string' or kind == '' then return nil, 'invalid_args' end
	if type(resolver) ~= 'function' then return nil, 'invalid_args' end
	self._resolvers[kind] = resolver
	return true
end

function Registry:resolve_op(desc, ctx)
	return op.guard(function ()
		if desc == nil then return op.always(nil, nil) end
		local checked, err = M.validate_descriptor(desc, ctx and ctx.direction)
		if not checked then return op.always(nil, err) end

		local resolver = self._resolvers[checked.kind]
		if not resolver then return op.always(nil, 'invalid_args') end

		local ok, result, rerr = pcall(function ()
			return resolver(checked, ctx or {})
		end)
		if not ok then
			return op.always(nil, 'invalid_args')
		end

		if type(result) == 'table' and type(result.wrap) == 'function' then
			return result:wrap(normalise_resolver_result)
		end

		return op.always(normalise_resolver_result(result, rerr))
	end)
end

local default_registry = M.new_registry()

-- Compatibility only for direct unit construction. Services should use their
-- own registry instance so authority and provider state are service-owned.
function M.register_resolver(kind, resolver) return default_registry:register_resolver(kind, resolver) end
function M.clear_resolvers_for_test() default_registry = M.new_registry(); return true end
function M.resolve_op(desc, ctx) return default_registry:resolve_op(desc, ctx) end

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

M.is_descriptor = is_descriptor
M.Registry = Registry
return M
