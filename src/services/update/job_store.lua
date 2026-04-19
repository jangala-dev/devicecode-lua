
local cjson   = require 'cjson.safe'
local cap_sdk = require 'services.hal.sdk.cap'

local M = {}

local function read_file(fs_cap, filename)
    local opts = assert(cap_sdk.args.new.FilesystemReadOpts(filename))
    local reply, err = fs_cap:call_control('read', opts)
    if not reply then return nil, err end
    if reply.ok ~= true then return nil, reply.reason end
    return reply.reason or '', nil
end

local function write_file(fs_cap, filename, data)
    local opts = assert(cap_sdk.args.new.FilesystemWriteOpts(filename, data))
    local reply, err = fs_cap:call_control('write', opts)
    if not reply then return nil, err end
    if reply.ok ~= true then return nil, reply.reason end
    return true, nil
end

function M.load(fs_cap, filename)
    local raw, err = read_file(fs_cap, filename)
    if raw == nil then
        local msg = tostring(err or '')
        if msg:find('No such file', 1, true) or msg:find('ENOENT', 1, true) then
            return { jobs = {}, order = {} }, nil
        end
        return nil, err
    end
    if raw == '' then
        return { jobs = {}, order = {} }, nil
    end
    local obj, derr = cjson.decode(raw)
    if type(obj) ~= 'table' then
        return nil, derr or 'decode_failed'
    end
    obj.jobs = type(obj.jobs) == 'table' and obj.jobs or {}
    obj.order = type(obj.order) == 'table' and obj.order or {}
    return obj, nil
end

function M.save(fs_cap, filename, store)
    local encoded, err = cjson.encode(store)
    if not encoded then return nil, err end
    return write_file(fs_cap, filename, encoded)
end

return M
