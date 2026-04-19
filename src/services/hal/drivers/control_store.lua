local fibers = require "fibers"
local file   = require "fibers.io.file"
local exec   = require "fibers.io.exec"
local cjson  = require "cjson.safe"

local perform = fibers.perform

local M = {}
local Store = {}
Store.__index = Store

local function dlog(logger, level, payload)
    if logger and logger[level] then
        logger[level](logger, payload)
    end
end

local function trim(s)
    return (s or ''):match('^%s*(.-)%s*$') or ''
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

local function valid_part(part)
    return type(part) == 'string' and part ~= '' and part:match('^[A-Za-z0-9_.-]+$') ~= nil
end

local function valid_ns(ns)
    if type(ns) ~= 'string' or ns == '' then return false end
    for part in ns:gmatch('[^/]+') do
        if not valid_part(part) then return false end
    end
    return true
end

local function valid_key(key)
    return valid_part(key)
end

local function ns_dir(self, ns)
    return join_path(self.root, ns)
end

local function index_path(self, ns)
    return join_path(ns_dir(self, ns), '.index.json')
end

local function record_path(self, ns, key)
    return join_path(ns_dir(self, ns), key .. '.json')
end

local function load_index(self, ns)
    local obj, err = read_json(index_path(self, ns))
    if not obj then
        local msg = tostring(err or '')
        if msg:find('No such file', 1, true) or msg:find('ENOENT', 1, true) or msg:find('no such file', 1, true) then
            return {}, ''
        end
        return nil, err
    end
    if type(obj) ~= 'table' then return {}, '' end
    local out = {}
    for _, key in ipairs(obj) do
        if valid_key(key) then out[#out + 1] = key end
    end
    return out, ''
end

local function save_index(self, ns, keys)
    return write_json(index_path(self, ns), keys)
end

function Store:get(ns, key)
    if not valid_ns(ns) then return nil, 'invalid_namespace' end
    if not valid_key(key) then return nil, 'invalid_key' end
    local obj, err = read_json(record_path(self, ns, key))
    if not obj then
        local msg = tostring(err or '')
        if msg:find('No such file', 1, true) or msg:find('ENOENT', 1, true) or msg:find('no such file', 1, true) then
            return nil, 'not_found'
        end
        return nil, err
    end
    return obj, ''
end

function Store:put(ns, key, value)
    if not valid_ns(ns) then return false, 'invalid_namespace' end
    if not valid_key(key) then return false, 'invalid_key' end
    if type(value) ~= 'table' then return false, 'invalid_value' end

    local encoded, eerr = cjson.encode(value)
    if not encoded then return false, tostring(eerr or 'encode_failed') end
    if self.max_record_bytes and #encoded > self.max_record_bytes then
        return false, 'record_too_large'
    end

    local ok, err = write_file(record_path(self, ns, key), encoded)
    if not ok then return false, err end

    local keys, kerr = load_index(self, ns)
    if not keys then return false, kerr end
    local found = false
    for _, existing in ipairs(keys) do
        if existing == key then found = true break end
    end
    if not found then
        keys[#keys + 1] = key
        table.sort(keys)
        local iok, ierr = save_index(self, ns, keys)
        if not iok then return false, ierr end
    end

    return true, ''
end

function Store:delete(ns, key)
    if not valid_ns(ns) then return false, 'invalid_namespace' end
    if not valid_key(key) then return false, 'invalid_key' end
    pcall(os.remove, record_path(self, ns, key))
    local keys, err = load_index(self, ns)
    if not keys then return false, err end
    local out = {}
    for _, existing in ipairs(keys) do
        if existing ~= key then out[#out + 1] = existing end
    end
    local ok, ierr = save_index(self, ns, out)
    if not ok then return false, ierr end
    return true, ''
end

function Store:list(ns)
    if not valid_ns(ns) then return nil, 'invalid_namespace' end
    return load_index(self, ns)
end

function Store:status()
    return {
        root = self.root,
        max_record_bytes = self.max_record_bytes,
    }
end

function M.new(opts, logger)
    opts = opts or {}
    local root = opts.root or os.getenv('DEVICECODE_CONTROL_ROOT') or '/data/devicecode/control'
    local max_record_bytes = opts.max_record_bytes or 65536
    local ok, err = ensure_dir(root)
    if not ok then
        dlog(logger, 'error', { what = 'control_store_root_failed', err = tostring(err), root = root })
        return nil, err
    end
    return setmetatable({
        root = root,
        max_record_bytes = max_record_bytes,
        logger = logger,
    }, Store), ''
end

return M
