-- services/hal/drivers/platform.lua
--
-- Platform identity HAL driver.
-- Reads hw_revision, fw_version, serial number and board_revision at
-- driver creation and publishes them as a retained state/identity message.
-- Exposes a 'platform' capability with a 'get' RPC offering.
-- Only the 'uptime' field is readable at runtime (from /proc/uptime).

local fibers  = require "fibers"
local op      = require "fibers.op"
local sleep   = require "fibers.sleep"
local file    = require "fibers.io.file"
local exec    = require "fibers.io.exec"
local channel = require "fibers.channel"

local hal_types = require "services.hal.types.core"
local cap_types      = require "services.hal.types.capabilities"
local cjson          = require "cjson.safe"
local cap_args = require "services.hal.types.capability_args"
local cache_mod      = require "shared.cache"

local perform = fibers.perform

local CONTROL_Q_LEN = 8

local function dlog(logger, level, payload)
    if logger and logger[level] then
        logger[level](logger, payload)
    end
end

---@class PlatformDriver
---@field scope Scope
---@field control_ch Channel
---@field cap_emit_ch Channel?
---@field cache Cache
---@field identity table  hw_revision, fw_version, serial, board_revision
---@field logger Logger?
local PlatformDriver = {}
PlatformDriver.__index = PlatformDriver

---- helpers ----

---@param path string
---@return string? content
---@return string error
local function read_file(path)
    local f, open_err = file.open(path, 'r')
    if not f then
        return nil, tostring(open_err)
    end
    local content, read_err = f:read_all()
    f:close()
    if not content then
        return nil, tostring(read_err)
    end
    return content, ""
end

---@param s string
---@return string
local function trim(s)
    return (s or ""):match("^%s*(.-)%s*$") or ""
end


local function dirname(path)
    local d = tostring(path or ''):match('^(.*)/[^/]+$')
    if d == nil or d == '' then return '.' end
    return d
end

local function ensure_parent_dir(path)
    local dir = dirname(path)
    local cmd = exec.command('mkdir', '-p', dir)
    local st = perform(cmd:run_op())
    if st ~= 'exited' then
        return false, 'mkdir failed'
    end
    return true, ''
end

local function read_json(path)
    local raw, err = read_file(path)
    if not raw then return nil, err end
    local obj, derr = cjson.decode(raw)
    if obj == nil then return nil, tostring(derr or 'decode_failed') end
    return obj, ''
end

local function write_json(path, obj)
    local ok, derr = ensure_parent_dir(path)
    if not ok then return false, derr end
    local encoded, eerr = cjson.encode(obj)
    if not encoded then return false, tostring(eerr or 'encode_failed') end
    local f, ferr = file.open(path, 'w')
    if not f then return false, tostring(ferr) end
    local wn, werr = f:write(encoded)
    f:close()
    if wn == nil then return false, tostring(werr) end
    return true, ''
end

local function updater_state_path()
    return os.getenv('DEVICECODE_UPDATE_STATE_PATH') or '/data/update/cm5-updater.json'
end

local function updater_artifact_root()
    return os.getenv('DEVICECODE_ARTIFACT_DIR') or '/data/artifacts'
end

local function updater_script_path()
    return os.getenv('DEVICECODE_UPDATE_SCRIPT') or '/root/scripts/update.sh'
end

local function read_updater_state()
    local path = updater_state_path()
    local obj, err = read_json(path)
    if not obj then return { state = 'idle', path = path }, err end
    if type(obj) ~= 'table' then return { state = 'idle', path = path }, 'invalid_state' end
    obj.path = path
    return obj, ''
end

--- Run fw_printenv and extract a named variable.
---@param varname string
---@return string value
local function read_fw_printenv(varname)
    local cmd = exec.command('fw_printenv', varname)
    local out, _, code = perform(cmd:output_op())
    if code ~= 0 or not out then
        return ""
    end
    -- Output format: "varname=value\n"
    return trim(out:match(varname .. "=(.+)$") or "")
end

--- Read all identity fields once at driver creation.
---@return table identity
local function read_identity()
    local function safe_read(path)
        local v, _ = read_file(path)
        return trim(v or "")
    end

    local board_revision = read_fw_printenv('board_revision')

    return {
        hw_revision    = safe_read('/etc/hwrevision'),
        fw_version     = safe_read('/etc/fwversion'),
        serial         = safe_read('/data/serial'),
        board_revision = board_revision,
    }
end

---- capability verbs ----

---@param opts PlatformGetOpts
---@return boolean ok
---@return any value_or_err
function PlatformDriver:get(opts)
    if opts == nil or getmetatable(opts) ~= cap_args.PlatformGetOpts then
        return false, "invalid opts"
    end
    local field   = opts.field
    local max_age = opts.max_age

    if field ~= 'uptime' then
        return false, "unsupported field: " .. tostring(field)
    end

    local cached = self.cache:get('uptime', max_age)
    if cached ~= nil then
        return true, cached
    end

    local raw, err = read_file('/proc/uptime')
    if not raw then
        return false, "failed to read /proc/uptime: " .. err
    end

    local uptime_s = tonumber(raw:match("([%d%.]+)"))
    if not uptime_s then
        return false, "failed to parse /proc/uptime"
    end

    self.cache:set('uptime', uptime_s)
    return true, uptime_s
end



---@param opts UpdaterStatusOpts?
---@return boolean ok
---@return any value_or_err
function PlatformDriver:status(opts)
    if opts ~= nil and getmetatable(opts) ~= cap_args.UpdaterStatusOpts then
        return false, "invalid opts"
    end
    local raw_state = read_updater_state()
    return true, {
        state = raw_state.state or 'idle',
        staged = raw_state.staged == true,
        artifact = raw_state.artifact,
        expected_version = raw_state.expected_version,
        last_error = raw_state.last_error,
        updated_at = raw_state.updated_at,
        fw_version = self.identity.fw_version,
        hw_revision = self.identity.hw_revision,
        serial = self.identity.serial,
        board_revision = self.identity.board_revision,
        bootedfw = read_fw_printenv('bootedfw'),
        targetfw = read_fw_printenv('targetfw'),
        upgrade_available = read_fw_printenv('upgrade_available'),
        artifact_root = updater_artifact_root(),
        state_path = updater_state_path(),
    }
end

function PlatformDriver:emit_updater_status()
    if not self.cap_emit_ch then return end
    local ok, status = self:status(cap_args.new.UpdaterStatusOpts(false))
    if not ok then return end
    local state_payload, state_err = hal_types.new.Emit('updater', 'cm5', 'state', 'status', status)
    if state_payload then
        self.cap_emit_ch:put(state_payload)
    else
        dlog(self.logger, 'debug', { what = 'updater_state_emit_failed', err = tostring(state_err) })
    end
end

---@param opts UpdaterPrepareOpts?
---@return boolean ok
---@return any value_or_err
function PlatformDriver:prepare(opts)
    if opts ~= nil and getmetatable(opts) ~= cap_args.UpdaterPrepareOpts then
        return false, "invalid opts"
    end
    local _, status = self:status(cap_args.new.UpdaterStatusOpts(false))
    return true, status
end

---@param opts UpdaterStageOpts?
---@return boolean ok
---@return any value_or_err
function PlatformDriver:stage(opts)
    if opts == nil or getmetatable(opts) ~= cap_args.UpdaterStageOpts then
        return false, "invalid opts"
    end
    local artifact = opts.artifact
    local path = artifact
    if not artifact:match('^/') then
        if artifact:find('..', 1, true) or artifact:find('/', 1, true) or artifact:find('\\', 1, true) then
            return false, "invalid artifact path"
        end
        path = updater_artifact_root() .. '/' .. artifact
    end
    local f, ferr = file.open(path, 'r')
    if not f then
        return false, 'artifact not found: ' .. tostring(ferr)
    end
    local content, rerr = f:read_all()
    f:close()
    if content == nil then
        return false, 'artifact unreadable: ' .. tostring(rerr)
    end
    local state = {
        state = 'staged',
        staged = true,
        artifact = path,
        artifact_size = #content,
        expected_version = opts.expected_version,
        metadata = opts.metadata,
        last_error = nil,
        updated_at = os.time(),
    }
    local ok, err = write_json(updater_state_path(), state)
    if not ok then
        return false, err
    end
    self:emit_updater_status()
    return true, {
        staged = true,
        artifact = path,
        artifact_size = #content,
        expected_version = opts.expected_version,
    }
end

---@param opts UpdaterCommitOpts?
---@return boolean ok
---@return any value_or_err
function PlatformDriver:commit(opts)
    if opts ~= nil and getmetatable(opts) ~= cap_args.UpdaterCommitOpts then
        return false, "invalid opts"
    end
    local state = read_updater_state()
    if state.state ~= 'staged' or type(state.artifact) ~= 'string' or state.artifact == '' then
        return false, 'no_staged_artifact'
    end
    local script = updater_script_path()
    local sf, ferr = file.open(script, 'r')
    if not sf then
        return false, 'update script unavailable: ' .. tostring(ferr)
    end
    sf:close()

    state.state = 'committing'
    state.updated_at = os.time()
    local ok, err = write_json(updater_state_path(), state)
    if not ok then
        return false, err
    end
    self:emit_updater_status()

    local env = {
        DEVICECODE_STAGED_ARTIFACT = state.artifact,
        DEVICECODE_UPDATE_KIND = (opts and opts.mode) or 'cm5',
    }

    local spawn_ok, spawn_err = fibers.spawn(function()
        local cmd = exec.command({
            script,
            env = env,
            stdout = 'inherit',
            stderr = 'inherit',
        })
        perform(cmd:run_op())
    end)
    if not spawn_ok then
        return false, tostring(spawn_err)
    end
    return true, { started = true, artifact = state.artifact }
end

---- control manager ----

function PlatformDriver:control_manager()
    fibers.current_scope():finally(function()
        dlog(self.logger, 'debug', { what = 'control_manager_exiting' })
    end)

    while true do
        local request, req_err = self.control_ch:get()
        if not request then
            dlog(self.logger, 'debug', { what = 'control_ch_closed', err = tostring(req_err) })
            break
        end

        local fn = self[request.verb]
        local ok, value_or_err
        if type(fn) ~= 'function' then
            ok, value_or_err = false, "unsupported verb: " .. tostring(request.verb)
        else
            local st, _, r1, r2 = fibers.run_scope(function()
                return fn(self, request.opts)
            end)
            if st ~= 'ok' then
                ok, value_or_err = false, "internal error: " .. tostring(r1)
            else
                ok, value_or_err = r1, r2
            end
        end

        local reply = hal_types.new.Reply(ok, value_or_err)
        if reply then
            request.reply_ch:put(reply)
        end
    end
end

---- public interface ----

---@return string error
function PlatformDriver:init()
    if self.initialised then
        return "already initialised"
    end
    self.initialised = true
    return ""
end

---@param emit_ch Channel
---@return Capability[]?
---@return string error
function PlatformDriver:capabilities(emit_ch)
    if not self.initialised then
        return nil, "platform driver not initialised"
    end
    self.cap_emit_ch = emit_ch
    local cap, err = cap_types.new.PlatformCapability('1', self.control_ch)
    if not cap then
        return {}, err
    end
    local updater_cap, uerr = cap_types.new.UpdaterCapability('cm5', self.control_ch)
    if not updater_cap then
        return {}, uerr
    end
    return { cap, updater_cap }, ""
end

---@return boolean ok
---@return string error
function PlatformDriver:start()
    if not self.initialised then
        return false, "platform driver not initialised"
    end
    if self.cap_emit_ch then
        -- Publish identity as a retained state sub-topic (consistent with modem state/card).
        local state_payload, state_err = hal_types.new.Emit(
            'platform', '1', 'state', 'identity', self.identity)
        if state_payload then
            self.cap_emit_ch:put(state_payload)
        else
            dlog(self.logger, 'debug', { what = 'state_identity_emit_failed', err = tostring(state_err) })
        end

        -- Publish meta.
        local meta_payload, meta_err = hal_types.new.Emit('platform', '1', 'meta', 'info', { provider = 'hal', version = 1 })
        if meta_payload then
            self.cap_emit_ch:put(meta_payload)
        else
            dlog(self.logger, 'debug', { what = 'meta_emit_failed', err = tostring(meta_err) })
        end

        local updater_meta, updater_meta_err = hal_types.new.Emit('updater', 'cm5', 'meta', 'info', { provider = 'hal', version = 1 })
        if updater_meta then
            self.cap_emit_ch:put(updater_meta)
        else
            dlog(self.logger, 'debug', { what = 'updater_meta_emit_failed', err = tostring(updater_meta_err) })
        end

        self:emit_updater_status()
    end

    local ok, spawn_err = self.scope:spawn(function()
        self:control_manager()
    end)
    if not ok then
        return false, "failed to spawn control_manager: " .. tostring(spawn_err)
    end
    return true, ""
end

---@param timeout number?
---@return boolean ok
---@return string error
function PlatformDriver:stop(timeout)
    timeout = timeout or 5
    self.scope:cancel('platform driver stopped')
    local source = perform(op.named_choice {
        join    = self.scope:join_op(),
        timeout = sleep.sleep_op(timeout),
    })
    if source == 'timeout' then
        return false, "platform driver stop timeout"
    end
    return true, ""
end

---@param logger Logger?
---@return PlatformDriver?
---@return string error
local function new(logger)
    local scope, err = fibers.current_scope():child()
    if not scope then
        return nil, "failed to create child scope: " .. tostring(err)
    end

    scope:finally(function()
        local st, primary = scope:status()
        if st == 'failed' then
            dlog(logger, 'error', { what = 'scope_failed', err = tostring(primary), status = st })
        end
        dlog(logger, 'debug', { what = 'stopped' })
    end)

    local identity = read_identity()

    return setmetatable({
        scope       = scope,
        control_ch  = channel.new(CONTROL_Q_LEN),
        cap_emit_ch = nil,
        cache       = cache_mod.new(),
        identity    = identity,
        logger      = logger,
        initialised = false,
    }, PlatformDriver), ""
end

return { new = new }
