local fibers      = require 'fibers'
local file        = require 'fibers.io.file'
local cjson       = require 'cjson.safe'
local uuid        = require 'uuid'
local checksum    = require 'services.fabric.checksum'
local blob_source = require 'services.fabric.blob_source'

local perform = fibers.perform

local M = {}
local Store = {}
Store.__index = Store

local function dlog(logger, level, payload)
    if logger and logger[level] then
        logger[level](logger, payload)
    end
end

local function join_path(...)
    local parts = { ... }
    return table.concat(parts, '/')
end

local function dirname(path)
    local d = tostring(path or ''):match('^(.*)/[^/]+$')
    if d == nil or d == '' then return '.' end
    return d
end

local function ensure_dir(path)
    local ok, err = file.mkdir_p(path)
    if not ok then
        return false, tostring(err or 'mkdir_failed')
    end
    return true, ''
end

local function remove_tree(path)
    local cmd = require('fibers.io.exec').command('rm', '-rf', path)
    local st = perform(cmd:run_op())
    return st == 'exited'
end

local function adler32_stream(stream)
    local a, b = 1, 0
    local mod = 65521
    while true do
        local chunk, err = stream:read_some(64 * 1024)
        if err ~= nil then return nil, tostring(err) end
        if chunk == nil then break end
        for i = 1, #chunk do
            a = (a + chunk:byte(i)) % mod
            b = (b + a) % mod
        end
    end
    return ('%08x'):format(b * 65536 + a), ''
end

local function read_file(path)
    local f, err = file.open(path, 'r')
    if not f then return nil, tostring(err) end
    local raw, rerr = f:read_all()
    f:close()
    if raw == nil then return nil, tostring(rerr or 'read_failed') end
    return raw, ''
end

local function write_file(path, data)
    local ok, derr = ensure_dir(dirname(path))
    if not ok then return false, derr end
    local tmp, terr = file.tmpfile(384, dirname(path))
    if not tmp then return false, tostring(terr) end
    local n, werr = tmp:write(data)
    if n == nil then
        tmp:close()
        return false, tostring(werr or 'write_failed')
    end
    local okf, ferr = tmp:flush()
    if okf == nil then
        tmp:close()
        return false, tostring(ferr or 'flush_failed')
    end
    local okr, rerr = tmp:rename(path)
    if not okr then
        tmp:close()
        return false, tostring(rerr)
    end
    local okc, cerr = tmp:close()
    if okc == nil then return false, tostring(cerr) end
    return true, ''
end

local function read_json(path)
    local raw, err = read_file(path)
    if raw == nil then return nil, err end
    local obj, derr = cjson.decode(raw)
    if obj == nil then return nil, tostring(derr or 'decode_failed') end
    return obj, ''
end

local function write_json(path, obj)
    local raw, err = cjson.encode(obj)
    if not raw then return false, tostring(err or 'encode_failed') end
    return write_file(path, raw)
end

local function copy_table(t)
    local out = {}
    if type(t) ~= 'table' then return out end
    for k, v in pairs(t) do out[k] = v end
    return out
end

local function valid_ref(ref)
    return type(ref) == 'string' and ref ~= '' and ref:match('^[A-Za-z0-9_.-]+$') ~= nil
end

local function choose_durability(self, policy)
    policy = policy or 'transient_only'
    if policy == 'require_durable' then
        if not self.durable_enabled then return nil, 'durable_disabled' end
        return 'durable', ''
    elseif policy == 'prefer_durable' then
        if self.durable_enabled then return 'durable', '' end
        return 'transient', ''
    elseif policy == 'transient_only' then
        return 'transient', ''
    end
    return nil, 'invalid_policy'
end

local function root_for(self, durability)
    if durability == 'durable' then return self.durable_root end
    return self.transient_root
end

local function artifact_dir(self, ref, durability)
    return join_path(root_for(self, durability), ref)
end

local function meta_path(self, ref, durability)
    return join_path(artifact_dir(self, ref, durability), 'meta.json')
end

local function blob_path(self, ref, durability)
    return join_path(artifact_dir(self, ref, durability), 'blob.bin')
end

local function clone_record(rec)
    local out = copy_table(rec)
    out.meta = copy_table(rec.meta)
    return out
end

local FileArtefactSource = {}
FileArtefactSource.__index = FileArtefactSource

function FileArtefactSource:size()
    return self._size
end

function FileArtefactSource:checksum()
    if self._checksum then return self._checksum end
    local f, err = file.open(self._path, 'r')
    if not f then error(tostring(err), 0) end
    local sum, serr = adler32_stream(f)
    f:close()
    if not sum then error(tostring(serr), 0) end
    self._checksum = sum
    return self._checksum
end

function FileArtefactSource:read_chunk(offset, max_bytes)
    offset = offset or 0
    max_bytes = max_bytes or self._size
    if offset < 0 then return nil, 'invalid_offset' end
    if offset >= self._size then return '', nil end
    local f, err = file.open(self._path, 'r')
    if not f then return nil, tostring(err) end
    local pos, serr = f:seek('set', offset)
    if pos == nil then
        f:close()
        return nil, tostring(serr or 'seek_failed')
    end
    local n = math.min(max_bytes, self._size - offset)
    local data, rerr = f:read_exactly(n)
    f:close()
    if data == nil then return nil, tostring(rerr or 'read_failed') end
    return data, nil
end

function FileArtefactSource:close()
    return true
end

local Artifact = {}
Artifact.__index = Artifact

function Artifact:ref()
    return self._rec.artifact_ref
end

function Artifact:meta()
    return copy_table(self._rec.meta)
end

function Artifact:size()
    return self._rec.size
end

function Artifact:checksum()
    return self._rec.checksum
end

function Artifact:open_source()
    return setmetatable({
        _path = self._blob_path,
        _size = self._rec.size,
        _checksum = self._rec.checksum,
    }, FileArtefactSource)
end

function Artifact:delete()
    return self._store:delete(self._rec.artifact_ref)
end

function Artifact:describe()
    return clone_record(self._rec)
end

function Artifact:local_path()
    return self._blob_path
end

local ArtifactSink = {}
ArtifactSink.__index = ArtifactSink

function ArtifactSink:write_chunk(offset, data)
    if self._closed then return nil, 'closed' end
    if self._committed then return nil, 'committed' end
    if type(data) ~= 'string' then return nil, 'invalid_chunk' end
    if offset ~= self._rec.size then return nil, 'unexpected_offset' end
    local f, err = file.open(self._blob_path, 'a+')
    if not f then return nil, tostring(err) end
    local n, werr = f:write(data)
    f:close()
    if n == nil then return nil, tostring(werr or 'write_failed') end
    self._rec.size = self._rec.size + #data
    self._rec.updated_at = os.time()
    local mok, merr = write_json(self._meta_path, self._rec)
    if not mok then return nil, merr end
    self._checksum = nil
    return true
end

function ArtifactSink:size()
    return self._rec.size
end

function ArtifactSink:checksum()
    if self._checksum then return self._checksum end
    local src = setmetatable({
        _path = self._blob_path,
        _size = self._rec.size,
    }, FileArtefactSource)
    self._checksum = src:checksum()
    return self._checksum
end

function ArtifactSink:commit()
    if self._closed then return nil, 'closed' end
    if self._committed then return nil, 'committed' end
    self._rec.state = 'ready'
    self._rec.checksum = self:checksum()
    self._rec.updated_at = os.time()
    local ok, err = write_json(self._meta_path, self._rec)
    if not ok then return nil, err end
    self._committed = true
    self._closed = true
    return setmetatable({
        _store = self._store,
        _rec = clone_record(self._rec),
        _blob_path = self._blob_path,
    }, Artifact), ''
end

function ArtifactSink:abort()
    if self._closed then return true end
    self._closed = true
    self._aborted = true
    remove_tree(self._dir)
    return true
end

function ArtifactSink:close()
    if self._closed then return true end
    self._closed = true
    return true
end

function ArtifactSink:status()
    return {
        artifact_ref = self._rec.artifact_ref,
        state = self._rec.state,
        durability = self._rec.durability,
        size = self._rec.size,
        checksum = self._rec.checksum,
        committed = self._committed,
        aborted = self._aborted,
    }
end

function Store:create_sink(meta, opts)
    opts = opts or {}
    local durability, err = choose_durability(self, opts.policy)
    if not durability then return nil, err end
    local ref = tostring(uuid.new()):gsub('[^A-Za-z0-9_.-]', '-')
    local dir = artifact_dir(self, ref, durability)
    local ok, derr = ensure_dir(dir)
    if not ok then return nil, derr end
    local blob = blob_path(self, ref, durability)
    local f, ferr = file.open(blob, 'w+')
    if not f then
        remove_tree(dir)
        return nil, tostring(ferr)
    end
    f:close()
    local rec = {
        artifact_ref = ref,
        state = 'writing',
        durability = durability,
        size = 0,
        checksum = nil,
        created_at = os.time(),
        updated_at = os.time(),
        meta = type(meta) == 'table' and copy_table(meta) or {},
    }
    local mp = meta_path(self, ref, durability)
    local mok, merr = write_json(mp, rec)
    if not mok then
        remove_tree(dir)
        return nil, merr
    end
    return setmetatable({
        _store = self,
        _rec = rec,
        _dir = dir,
        _blob_path = blob,
        _meta_path = mp,
        _committed = false,
        _aborted = false,
        _closed = false,
        _checksum = nil,
    }, ArtifactSink), ''
end

function Store:open(ref)
    if not valid_ref(ref) then return nil, 'invalid_artifact_ref' end
    for _, durability in ipairs({ 'transient', 'durable' }) do
        local rec, err = read_json(meta_path(self, ref, durability))
        if rec then
            if rec.state ~= 'ready' then return nil, 'artifact_not_ready' end
            return setmetatable({
                _store = self,
                _rec = rec,
                _blob_path = blob_path(self, ref, durability),
            }, Artifact), ''
        end
    end
    return nil, 'not_found'
end

function Store:import_source(source, meta, opts)
    local sink, err = self:create_sink(meta, opts)
    if not sink then return nil, err end
    local artefact, cerr = blob_source.copy(source, sink)
    if not artefact then return nil, cerr end
    return artefact, ''
end

function Store:import_path(path, meta, opts)
    if type(path) ~= 'string' or path == '' then return nil, 'invalid_path' end
    if path:sub(1, 1) ~= '/' then
        if path:find('..', 1, true) or path:find('/', 1, true) or path:find('\\', 1, true) then
            return nil, 'invalid_path'
        end
        local import_root = os.getenv('DEVICECODE_IMPORT_ARTIFACT_ROOT') or os.getenv('DEVICECODE_ARTIFACT_DIR') or self.durable_root or self.transient_root
        path = join_path(import_root, path)
    end
    local f, err = file.open(path, 'r')
    if not f then return nil, tostring(err) end
    local sz, serr = f:seek('end')
    if sz == nil then f:close(); return nil, tostring(serr or 'seek_failed') end
    f:close()
    local src = setmetatable({ _path = path, _size = sz }, FileArtefactSource)
    return self:import_source(src, meta, opts)
end

function Store:describe(ref)
    local art, err = self:open(ref)
    if not art then return nil, err end
    return art:describe(), ''
end

function Store:resolve_local(ref)
    local art, err = self:open(ref)
    if not art then return nil, err end
    local rec = art:describe()
    return {
        artifact_ref = rec.artifact_ref,
        durability = rec.durability,
        path = art:local_path(),
        meta = rec.meta,
        size = rec.size,
        checksum = rec.checksum,
        state = rec.state,
    }, ''
end

function Store:delete(ref)
    if not valid_ref(ref) then return nil, 'invalid_artifact_ref' end
    local rec, err = self:describe(ref)
    if not rec then
        if err == 'not_found' then return true, '' end
        return false, err
    end
    remove_tree(artifact_dir(self, ref, rec.durability))
    return true, ''
end

function Store:status()
    return {
        transient_root = self.transient_root,
        durable_root = self.durable_root,
        durable_enabled = self.durable_enabled,
    }
end

function M.new(opts, logger)
    opts = opts or {}
    local transient_root = opts.transient_root or os.getenv('DEVICECODE_ARTIFACT_TRANSIENT_ROOT') or '/run/devicecode/artifacts'
    local durable_root = opts.durable_root or os.getenv('DEVICECODE_ARTIFACT_DURABLE_ROOT') or '/data/devicecode/artifacts'
    local durable_enabled = opts.durable_enabled
    if durable_enabled == nil then
        local env = os.getenv('DEVICECODE_DURABLE_ARTIFACTS')
        durable_enabled = not (env == '0' or env == 'false' or env == 'FALSE')
    end
    local ok, err = ensure_dir(transient_root)
    if not ok then
        dlog(logger, 'error', { what = 'artifact_store_transient_root_failed', err = tostring(err), root = transient_root })
        return nil, err
    end
    if durable_enabled then
        local dok, derr = ensure_dir(durable_root)
        if not dok then
            dlog(logger, 'warn', { what = 'artifact_store_durable_root_failed', err = tostring(derr), root = durable_root })
            durable_enabled = false
        end
    end
    return setmetatable({
        transient_root = transient_root,
        durable_root = durable_root,
        durable_enabled = durable_enabled,
        logger = logger,
    }, Store), ''
end

return M
