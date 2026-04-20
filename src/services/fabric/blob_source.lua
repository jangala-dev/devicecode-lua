-- services/fabric/blob_source.lua
--
-- Small, OS-agnostic object source/sink helpers shared by fabric transfer
-- and higher-level services. File-backed artefacts belong behind HAL/host
-- capabilities; this module only defines abstract sources/sinks plus small
-- in-memory helpers for tests and simple local flows.

local checksum = require 'services.fabric.checksum'

local M = {}

local function copy_table(t)
    local out = {}
    if type(t) ~= 'table' then return out end
    for k, v in pairs(t) do out[k] = v end
    return out
end

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

local MemoryArtefact = {}
MemoryArtefact.__index = MemoryArtefact

function MemoryArtefact:ref()
    return nil
end

function MemoryArtefact:meta()
    return copy_table(self._meta)
end

function MemoryArtefact:size()
    return #self._data
end

function MemoryArtefact:checksum()
    if not self._checksum then
        self._checksum = checksum.digest_hex(self._data)
    end
    return self._checksum
end

function MemoryArtefact:open_source()
    return M.from_string(self._data)
end

function MemoryArtefact:delete()
    self._deleted = true
    return true
end

function MemoryArtefact:describe()
    return {
        artifact_ref = nil,
        state = 'ready',
        durability = 'memory',
        size = #self._data,
        checksum = self:checksum(),
        meta = copy_table(self._meta),
        kind = 'memory',
    }
end

local MemorySink = {}
MemorySink.__index = MemorySink

function MemorySink:write_chunk(offset, data)
    if self._closed then return nil, 'closed' end
    if offset ~= self._size then return nil, 'unexpected_offset' end
    if type(data) ~= 'string' then return nil, 'invalid_chunk' end
    self._parts[#self._parts + 1] = data
    self._size = self._size + #data
    self._checksum = nil
    return true
end

function MemorySink:size()
    return self._size
end

function MemorySink:checksum()
    if not self._checksum then
        self._checksum = checksum.digest_hex(table.concat(self._parts))
    end
    return self._checksum
end

function MemorySink:commit()
    if self._closed then return nil, 'closed' end
    if self._committed then return nil, 'committed' end
    self._committed = true
    self._closed = true
    return setmetatable({
        _data = table.concat(self._parts),
        _meta = copy_table(self._meta),
    }, MemoryArtefact), ''
end

function MemorySink:abort()
    if self._closed then return true end
    self._closed = true
    self._aborted = true
    return true
end

function MemorySink:close()
    if self._closed then return true end
    self._closed = true
    return true
end

function MemorySink:status()
    return {
        size = self._size,
        committed = self._committed,
        aborted = self._aborted,
        kind = 'memory',
    }
end

function M.memory_sink(meta)
    return setmetatable({
        _parts = {},
        _size = 0,
        _closed = false,
        _committed = false,
        _aborted = false,
        _meta = copy_table(meta),
        _checksum = nil,
    }, MemorySink)
end

function M.is_source(v)
    return type(v) == 'table'
        and type(v.read_chunk) == 'function'
        and type(v.size) == 'function'
        and type(v.checksum) == 'function'
end

function M.is_sink(v)
    return type(v) == 'table'
        and type(v.write_chunk) == 'function'
        and type(v.commit) == 'function'
        and type(v.abort) == 'function'
end

function M.is_stored_artefact(v)
    return type(v) == 'table'
        and type(v.open_source) == 'function'
        and type(v.ref) == 'function'
        and type(v.describe) == 'function'
end

function M.normalise_source(source)
    if source == nil then return nil, 'missing_source' end
    if type(source) == 'string' then
        return M.from_string(source), nil
    end
    if M.is_stored_artefact(source) then
        return source:open_source(), nil
    end
    if M.is_source(source) then
        return source, nil
    end
    return nil, 'unsupported_source'
end

function M.copy(source, sink, opts)
    opts = opts or {}
    local src, err = M.normalise_source(source)
    if not src then return nil, err end
    assert(M.is_sink(sink), 'blob_source.copy expects sink')
    local offset = 0
    local chunk_size = tonumber(opts.chunk_size) or 64 * 1024
    local expected_size = opts.expected_size or src:size()
    local expected_checksum = opts.expected_checksum or src:checksum()

    while true do
        local chunk, rerr = src:read_chunk(offset, chunk_size)
        if chunk == nil then
            pcall(function() sink:abort() end)
            return nil, rerr or 'read_failed'
        end
        if chunk == '' then break end
        local ok, werr = sink:write_chunk(offset, chunk)
        if not ok then
            pcall(function() sink:abort() end)
            return nil, werr or 'write_failed'
        end
        offset = offset + #chunk
    end
    if offset ~= expected_size then
        pcall(function() sink:abort() end)
        return nil, 'size_mismatch'
    end
    if sink:checksum() ~= expected_checksum then
        pcall(function() sink:abort() end)
        return nil, 'checksum_mismatch'
    end
    return sink:commit()
end

return M
