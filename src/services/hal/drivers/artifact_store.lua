local fibers   = require "fibers"
local file     = require "fibers.io.file"
local exec     = require "fibers.io.exec"
local cjson    = require "cjson.safe"
local uuid     = require "uuid"
local checksum = require 'services.fabric.checksum'

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
    local cmd = exec.command('mkdir', '-p', path)
    local st = perform(cmd:run_op())
    if st ~= 'exited' then
        return false, 'mkdir_failed:' .. tostring(path)
    end
    return true, ''
end

local function read_file(path)
    local f, err = file.open(path, 'r')
    if not f then return nil, tostring(err) end
    local raw, rerr = f:read_all()
    f:close()
    if raw == nil then return nil, tostring(rerr) end
    return raw, ''
end

local function write_file(path, data)
    local ok, derr = ensure_dir(dirname(path))
    if not ok then return false, derr end
    local tmp = path .. '.tmp-' .. tostring(os.time()) .. '-' .. tostring(math.random(1000000))
    local f, err = file.open(tmp, 'w')
    if not f then return false, tostring(err) end
    local n, werr = f:write(data)
    f:close()
    if n == nil then
        os.remove(tmp)
        return false, tostring(werr)
    end
    local ok_rename, rerr = os.rename(tmp, path)
    if not ok_rename then
        os.remove(tmp)
        return false, tostring(rerr)
    end
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

local function remove_tree(path)
    local cmd = exec.command('rm', '-rf', path)
    local st = perform(cmd:run_op())
    return st == 'exited'
end

function Store:create(meta, opts)
    opts = opts or {}
    local durability, err = choose_durability(self, opts.policy)
    if not durability then return nil, err end
    local ref = tostring(uuid.new()):gsub('[^A-Za-z0-9_.-]', '-')
    local dir = artifact_dir(self, ref, durability)
    local ok, derr = ensure_dir(dir)
    if not ok then return nil, derr end
    local f, ferr = file.open(blob_path(self, ref, durability), 'w')
    if not f then return nil, tostring(ferr) end
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
    local mok, merr = write_json(meta_path(self, ref, durability), rec)
    if not mok then
        remove_tree(dir)
        return nil, merr
    end
    return copy_table(rec), ''
end

function Store:append(ref, data)
    if not valid_ref(ref) then return nil, 'invalid_artifact_ref' end
    if type(data) ~= 'string' then return nil, 'invalid_data' end
    local rec, err = self:describe(ref)
    if not rec then return nil, err end
    if rec.state ~= 'writing' then return nil, 'artifact_not_writable' end
    local f, ferr = file.open(blob_path(self, ref, rec.durability), 'a')
    if not f then return nil, tostring(ferr) end
    local n, werr = f:write(data)
    f:close()
    if n == nil then return nil, tostring(werr) end
    rec.size = (rec.size or 0) + #data
    rec.updated_at = os.time()
    local ok, merr = write_json(meta_path(self, ref, rec.durability), rec)
    if not ok then return nil, merr end
    return copy_table(rec), ''
end

function Store:finalise(ref)
    if not valid_ref(ref) then return nil, 'invalid_artifact_ref' end
    local rec, err = self:describe(ref)
    if not rec then return nil, err end
    local raw, rerr = read_file(blob_path(self, ref, rec.durability))
    if raw == nil then return nil, rerr end
    rec.state = 'ready'
    rec.size = #raw
    rec.checksum = checksum.digest_hex(raw)
    rec.updated_at = os.time()
    local ok, merr = write_json(meta_path(self, ref, rec.durability), rec)
    if not ok then return nil, merr end
    return copy_table(rec), ''
end

function Store:import_path(path, meta, opts)
    if type(path) ~= 'string' or path == '' then
        return nil, 'invalid_path'
    end
    if path:sub(1, 1) ~= '/' then
        if path:find('..', 1, true) or path:find('/', 1, true) or path:find('\\', 1, true) then
            return nil, 'invalid_path'
        end
        local import_root = os.getenv('DEVICECODE_IMPORT_ARTIFACT_ROOT') or os.getenv('DEVICECODE_ARTIFACT_DIR') or self.durable_root or self.transient_root
        path = join_path(import_root, path)
    end
    local raw, err = read_file(path)
    if raw == nil then return nil, err end
    local rec, cerr = self:create(meta, opts)
    if not rec then return nil, cerr end
    local f, ferr = file.open(blob_path(self, rec.artifact_ref, rec.durability), 'w')
    if not f then
        self:delete(rec.artifact_ref)
        return nil, tostring(ferr)
    end
    local n, werr = f:write(raw)
    f:close()
    if n == nil then
        self:delete(rec.artifact_ref)
        return nil, tostring(werr)
    end
    rec.size = #raw
    rec.checksum = checksum.digest_hex(raw)
    rec.state = 'ready'
    rec.updated_at = os.time()
    local ok, merr = write_json(meta_path(self, rec.artifact_ref, rec.durability), rec)
    if not ok then
        self:delete(rec.artifact_ref)
        return nil, merr
    end
    return copy_table(rec), ''
end

function Store:describe(ref)
    if not valid_ref(ref) then return nil, 'invalid_artifact_ref' end
    for _, durability in ipairs({ 'transient', 'durable' }) do
        local rec, err = read_json(meta_path(self, ref, durability))
        if rec then return rec, '' end
        local msg = tostring(err or '')
        if not (msg:find('No such file', 1, true) or msg:find('ENOENT', 1, true) or msg:find('no such file', 1, true)) then
            return nil, err
        end
    end
    return nil, 'not_found'
end

function Store:resolve_local(ref)
    local rec, err = self:describe(ref)
    if not rec then return nil, err end
    if rec.state ~= 'ready' and rec.state ~= 'writing' then
        return nil, 'artifact_unavailable'
    end
    return {
        artifact_ref = ref,
        path = blob_path(self, ref, rec.durability),
        durability = rec.durability,
        meta = rec,
    }, ''
end

function Store:delete(ref)
    if not valid_ref(ref) then return false, 'invalid_artifact_ref' end
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
