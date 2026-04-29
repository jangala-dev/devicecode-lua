---@module 'shared.blob_source'

local fibers = require 'fibers'
local op     = require 'fibers.op'

---@class BlobSource
local BlobSource = {}
BlobSource.__index = BlobSource

---@class BlobSink
local BlobSink = {}
BlobSink.__index = BlobSink

----------------------------------------------------------------------
-- String source
----------------------------------------------------------------------

---@class StringSource : BlobSource
---@field _data string
---@field _off integer
local StringSource = setmetatable({}, { __index = BlobSource })
StringSource.__index = StringSource

---@param max_bytes integer|nil
---@return Op  -- (chunk:string|nil, err:string|nil)
function StringSource:read_chunk_op(max_bytes)
	return op.guard(function ()
		if self._off >= #self._data then
			return op.always(nil, nil) -- EOF
		end

		local n = max_bytes or (#self._data - self._off)
		if type(n) ~= 'number' or n <= 0 then
			return op.always(nil, 'invalid max_bytes')
		end

		local chunk = self._data:sub(self._off + 1, self._off + n)
		self._off = self._off + #chunk
		return op.always(chunk, nil)
	end)
end

function StringSource:close_op()
	return op.always(true, nil)
end

----------------------------------------------------------------------
-- Stream source
----------------------------------------------------------------------

---@class StreamSource : BlobSource
---@field _stream Stream
local StreamSource = setmetatable({}, { __index = BlobSource })
StreamSource.__index = StreamSource

---@param max_bytes integer|nil
---@return Op  -- (chunk:string|nil, err:string|nil)
function StreamSource:read_chunk_op(max_bytes)
	local n = max_bytes or 65536
	return self._stream:read_some_op(n):wrap(function (chunk, err)
		return chunk, err
	end)
end

function StreamSource:close_op()
	return self._stream:close_op()
end

----------------------------------------------------------------------
-- Memory sink
----------------------------------------------------------------------

---@class MemorySink : BlobSink
---@field _parts string[]
local MemorySink = setmetatable({}, { __index = BlobSink })
MemorySink.__index = MemorySink

---@param chunk string
---@return Op  -- (ok:boolean|nil, err:string|nil)
function MemorySink:write_chunk_op(chunk)
	return op.guard(function ()
		if type(chunk) ~= 'string' then
			return op.always(nil, 'chunk must be a string')
		end
		self._parts[#self._parts + 1] = chunk
		return op.always(true, nil)
	end)
end

function MemorySink:close_op()
	return op.always(true, nil)
end

function MemorySink:result()
	return table.concat(self._parts)
end

----------------------------------------------------------------------
-- Stream sink
----------------------------------------------------------------------

---@class StreamSink : BlobSink
---@field _stream Stream
local StreamSink = setmetatable({}, { __index = BlobSink })
StreamSink.__index = StreamSink

---@param chunk string
---@return Op  -- (ok:boolean|nil, err:string|nil)
function StreamSink:write_chunk_op(chunk)
	return self._stream:write_op(chunk):wrap(function (n, err)
		if n == nil then
			return nil, err
		end
		return true, nil
	end)
end

function StreamSink:close_op()
	return self._stream:close_op()
end

----------------------------------------------------------------------
-- Structured copy
----------------------------------------------------------------------

---@param source BlobSource
---@param sink BlobSink
---@param opts? { chunk_size?: integer, close_source?: boolean, close_sink?: boolean }
---@return Op -- yields st, rep, bytes_or_primary via run_scope_op
local function copy_op(source, sink, opts)
	opts = opts or {}
	local chunk_size   = opts.chunk_size or 65536
	local close_source = opts.close_source ~= false
	local close_sink   = opts.close_sink ~= false

	return fibers.run_scope_op(function (scope)
		local bytes = 0

		scope:finally(function ()
			if close_source and source and source.close_op then
				op.perform_raw(source:close_op())
			end
			if close_sink and sink and sink.close_op then
				op.perform_raw(sink:close_op())
			end
		end)

		while true do
			local chunk, rerr = fibers.perform(source:read_chunk_op(chunk_size))
			if rerr ~= nil then
				error(rerr, 0)
			end
			if chunk == nil then
				return bytes
			end

			local ok, werr = fibers.perform(sink:write_chunk_op(chunk))
			if ok == nil then
				error(werr or 'write failed', 0)
			end

			bytes = bytes + #chunk
		end
	end)
end

----------------------------------------------------------------------
-- Constructors
----------------------------------------------------------------------

local M = {}

---@param data string
---@return BlobSource
function M.from_string(data)
	assert(type(data) == 'string', 'from_string: data must be string')
	return setmetatable({
		_data = data,
		_off  = 0,
	}, StringSource)
end

---@param stream Stream
---@return BlobSource
function M.from_stream(stream)
	return setmetatable({
		_stream = stream,
	}, StreamSource)
end

---@return BlobSink
function M.to_memory()
	return setmetatable({
		_parts = {},
	}, MemorySink)
end

---@param stream Stream
---@return BlobSink
function M.to_stream(stream)
	return setmetatable({
		_stream = stream,
	}, StreamSink)
end

M.copy_op = copy_op
M.BlobSource = BlobSource
M.BlobSink   = BlobSink

return M
