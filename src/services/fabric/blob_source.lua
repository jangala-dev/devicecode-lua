-- services/fabric/blob_source.lua
--
-- Simple blob source/sink adapters used by fabric transfer management.

local checksum = require 'services.fabric.checksum'

local M = {}

local StringSource = {}
StringSource.__index = StringSource

function StringSource:size()
	return #self._data
end

function StringSource:checksum()
	return checksum.digest_hex(self._data)
end

function StringSource:read_chunk(offset, max_bytes)
	offset = offset or 0
	max_bytes = max_bytes or #self._data
	if offset < 0 then return nil, 'invalid_offset' end
	if offset >= #self._data then return '', nil end
	local from = offset + 1
	local to = math.min(#self._data, offset + max_bytes)
	return self._data:sub(from, to), nil
end

function StringSource:close()
	return true
end

function M.from_string(s)
	assert(type(s) == 'string', 'blob_source.from_string expects string')
	return setmetatable({ _data = s }, StringSource)
end

local MemorySink = {}
MemorySink.__index = MemorySink

function MemorySink:write_chunk(offset, data)
	if self._closed then return nil, 'closed' end
	if offset ~= self._size then return nil, 'unexpected_offset' end
	if type(data) ~= 'string' then return nil, 'invalid_chunk' end
	self._parts[#self._parts + 1] = data
	self._size = self._size + #data
	return true
end

function MemorySink:size()
	return self._size
end

function MemorySink:tostring()
	return table.concat(self._parts)
end

function MemorySink:checksum()
	return checksum.digest_hex(self:tostring())
end

function MemorySink:commit()
	if self._closed then return nil, 'closed' end
	self._committed = true
	return true
end

function MemorySink:abort()
	self._closed = true
	self._aborted = true
	return true
end

function MemorySink:status()
	return {
		size = self._size,
		committed = self._committed,
		aborted = self._aborted,
	}
end

function M.memory_sink()
	return setmetatable({
		_parts = {},
		_size = 0,
		_closed = false,
		_committed = false,
		_aborted = false,
	}, MemorySink)
end

function M.normalise_source(source)
	if source == nil then return nil, 'missing_source' end
	if type(source) == 'string' then
		return M.from_string(source), nil
	end
	if type(source) == 'table' and type(source.read_chunk) == 'function' and type(source.size) == 'function' then
		return source, nil
	end
	return nil, 'unsupported_source'
end

return M
