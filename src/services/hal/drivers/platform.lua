-- services/hal/drivers/platform.lua
--
-- Platform/host HAL driver.
--
-- Exposes:
--   * platform/1        : identity + basic runtime get()
--   * updater/cm5       : CM5 update prepare/stage/commit/status
--   * control_store/update : durable small-record store on /data
--   * artifact_store/main  : transient/durable artefact store by ref

local fibers  = require 'fibers'
local op      = require 'fibers.op'
local sleep   = require 'fibers.sleep'
local file    = require 'fibers.io.file'
local exec    = require 'fibers.io.exec'
local channel = require 'fibers.channel'

local hal_types      = require 'services.hal.types.core'
local cap_types      = require 'services.hal.types.capabilities'
local cap_args       = require 'services.hal.types.capability_args'
local cache_mod      = require 'shared.cache'
local control_store_mod = require 'services.hal.drivers.control_store'
local artifact_store_mod = require 'services.hal.drivers.artifact_store'

local perform = fibers.perform

local CONTROL_Q_LEN = 8

local function dlog(logger, level, payload)
    if logger and logger[level] then
        logger[level](logger, payload)
    end
end

---@class PlatformDriver
---@field scope Scope
---@field logger Logger?
---@field cap_emit_ch Channel?
---@field initialised boolean
---@field identity table
---@field cache Cache
---@field control_store any
---@field artifact_store any
---@field platform_ch Channel
---@field updater_ch Channel
---@field control_store_ch Channel
---@field artifact_store_ch Channel
local PlatformDriver = {}
PlatformDriver.__index = PlatformDriver

local function read_file(path)
    local f, open_err = file.open(path, 'r')
    if not f then return nil, tostring(open_err) end
    local content, read_err = f:read_all()
    f:close()
    if not content then return nil, tostring(read_err) end
    return content, ''
end

local function trim(s)
    return (s or ''):match('^%s*(.-)%s*$') or ''
end

local function updater_script_path()
    return os.getenv('DEVICECODE_UPDATE_SCRIPT') or '/root/scripts/update.sh'
end

local function read_fw_printenv(varname)
    local cmd = exec.command('fw_printenv', varname)
    local out, _, code = perform(cmd:output_op())
    if code ~= 0 or not out then
        return ''
    end
    return trim(out:match(varname .. '=(.+)$') or '')
end

local function read_identity()
    local function safe_read(path)
        local v, _ = read_file(path)
        return trim(v or '')
    end

    local board_revision = read_fw_printenv('board_revision')

    return {
        hw_revision    = safe_read('/etc/hwrevision'),
        fw_version     = safe_read('/etc/fwversion'),
        serial         = safe_read('/data/serial'),
        board_revision = board_revision,
    }
end

local function default_updater_state()
    return {
        state = 'idle',
        staged = false,
        artifact_ref = nil,
        artifact_meta = nil,
        expected_version = nil,
        last_error = nil,
        updated_at = nil,
    }
end

local function normalized_updater_state(raw_state, identity)
    raw_state = type(raw_state) == 'table' and raw_state or default_updater_state()
    local state = raw_state.state or 'idle'
    local current_version = identity and identity.fw_version or nil
    if state == 'staged' then
        return 'staged'
    end
    if state == 'committing' or state == 'awaiting_reboot' then
        if raw_state.expected_version and current_version == raw_state.expected_version then
            return 'running'
        end
        return 'awaiting_reboot'
    end
    if state == 'failed' or state == 'rollback_detected' then
        return state
    end
    if current_version and current_version ~= '' then
        return 'running'
    end
    return state
end

function PlatformDriver:_read_updater_state()
    local obj, err = self.control_store:get('updater/cm5', 'state')
    if not obj then
        if err == 'not_found' then
            return default_updater_state(), ''
        end
        return default_updater_state(), err
    end
    if type(obj) ~= 'table' then
        return default_updater_state(), 'invalid_state'
    end
    return obj, ''
end

function PlatformDriver:_write_updater_state(state)
    state = state or default_updater_state()
    state.updated_at = state.updated_at or os.time()
    return self.control_store:put('updater/cm5', 'state', state)
end

function PlatformDriver:_emit_updater_status()
    if not self.cap_emit_ch then return end
    local ok, status = self:updater_status(cap_args.new.UpdaterStatusOpts(false))
    if not ok then return end
    local payload, err = hal_types.new.Emit('updater', 'cm5', 'state', 'status', status)
    if payload then
        self.cap_emit_ch:put(payload)
    else
        dlog(self.logger, 'debug', { what = 'updater_state_emit_failed', err = tostring(err) })
    end
end

-- platform capability -------------------------------------------------------

function PlatformDriver:platform_get(opts)
    if opts == nil or getmetatable(opts) ~= cap_args.PlatformGetOpts then
        return false, 'invalid opts'
    end

    if opts.field ~= 'uptime' then
        return false, 'unsupported field: ' .. tostring(opts.field)
    end

    local cached = self.cache:get('uptime', opts.max_age)
    if cached ~= nil then return true, cached end

    local raw, err = read_file('/proc/uptime')
    if not raw then return false, 'failed to read /proc/uptime: ' .. tostring(err) end
    local uptime_s = tonumber(raw:match('([%d%.]+)'))
    if not uptime_s then return false, 'failed to parse /proc/uptime' end

    self.cache:set('uptime', uptime_s)
    return true, uptime_s
end

-- updater capability --------------------------------------------------------

function PlatformDriver:updater_status(opts)
    if opts ~= nil and getmetatable(opts) ~= cap_args.UpdaterStatusOpts then
        return false, 'invalid opts'
    end

    local raw_state, _ = self:_read_updater_state()
    local artifact_meta = nil
    if type(raw_state.artifact_ref) == 'string' and raw_state.artifact_ref ~= '' then
        artifact_meta = self.artifact_store:describe(raw_state.artifact_ref)
        if type(artifact_meta) ~= 'table' then artifact_meta = nil end
    end

    local bootedfw = read_fw_printenv('bootedfw')
    local targetfw = read_fw_printenv('targetfw')
    local upgrade_available = read_fw_printenv('upgrade_available')
    local state = normalized_updater_state(raw_state, self.identity)

    return true, {
        state = state,
        raw_state = raw_state.state or 'idle',
        staged = raw_state.staged == true,
        artifact_ref = raw_state.artifact_ref,
        artifact_meta = artifact_meta or raw_state.artifact_meta,
        expected_version = raw_state.expected_version,
        last_error = raw_state.last_error,
        updated_at = raw_state.updated_at,
        fw_version = self.identity.fw_version,
        hw_revision = self.identity.hw_revision,
        serial = self.identity.serial,
        board_revision = self.identity.board_revision,
        bootedfw = bootedfw,
        targetfw = targetfw,
        upgrade_available = upgrade_available,
    }
end

function PlatformDriver:updater_prepare(opts)
    if opts ~= nil and getmetatable(opts) ~= cap_args.UpdaterPrepareOpts then
        return false, 'invalid opts'
    end
    local _, status = self:updater_status(cap_args.new.UpdaterStatusOpts(false))
    return true, status
end

function PlatformDriver:updater_stage(opts)
    if opts == nil or getmetatable(opts) ~= cap_args.UpdaterStageOpts then
        return false, 'invalid opts'
    end

    local artifact, err = self.artifact_store:describe(opts.artifact_ref)
    if not artifact then return false, err end
    if artifact.state ~= 'ready' then return false, 'artifact_not_ready' end

    local state = {
        state = 'staged',
        staged = true,
        artifact_ref = opts.artifact_ref,
        artifact_meta = artifact,
        expected_version = opts.expected_version,
        metadata = opts.metadata,
        last_error = nil,
        updated_at = os.time(),
    }
    local ok, werr = self:_write_updater_state(state)
    if not ok then return false, werr end

    self:_emit_updater_status()
    return true, {
        staged = true,
        artifact_ref = opts.artifact_ref,
        artifact_meta = artifact,
        expected_version = opts.expected_version,
        artifact_retention = 'keep',
    }
end

function PlatformDriver:updater_commit(opts)
    if opts ~= nil and getmetatable(opts) ~= cap_args.UpdaterCommitOpts then
        return false, 'invalid opts'
    end

    local state = self:_read_updater_state()
    if state.state ~= 'staged' or type(state.artifact_ref) ~= 'string' or state.artifact_ref == '' then
        return false, 'no_staged_artifact'
    end

    local resolved, rerr = self.artifact_store:resolve_local(state.artifact_ref)
    if not resolved then return false, rerr end

    local script = updater_script_path()
    local sf, ferr = file.open(script, 'r')
    if not sf then return false, 'update script unavailable: ' .. tostring(ferr) end
    sf:close()

    state.state = 'awaiting_reboot'
    state.updated_at = os.time()
    local ok, err = self:_write_updater_state(state)
    if not ok then return false, err end
    self:_emit_updater_status()

    local env = {
        DEVICECODE_STAGED_ARTIFACT = resolved.path,
        DEVICECODE_STAGED_ARTIFACT_REF = state.artifact_ref,
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
    if not spawn_ok then return false, tostring(spawn_err) end

    return true, {
        started = true,
        artifact_ref = state.artifact_ref,
        artifact_meta = state.artifact_meta,
    }
end

-- control_store capability --------------------------------------------------

function PlatformDriver:control_store_get(opts)
    if opts == nil or getmetatable(opts) ~= cap_args.ControlStoreGetOpts then
        return false, 'invalid opts'
    end
    local value, err = self.control_store:get(opts.ns, opts.key)
    if value == nil then return false, err end
    return true, value
end

function PlatformDriver:control_store_put(opts)
    if opts == nil or getmetatable(opts) ~= cap_args.ControlStorePutOpts then
        return false, 'invalid opts'
    end
    local ok, err = self.control_store:put(opts.ns, opts.key, opts.value)
    if not ok then return false, err end
    return true, { ok = true }
end

function PlatformDriver:control_store_delete(opts)
    if opts == nil or getmetatable(opts) ~= cap_args.ControlStoreDeleteOpts then
        return false, 'invalid opts'
    end
    local ok, err = self.control_store:delete(opts.ns, opts.key)
    if not ok then return false, err end
    return true, { ok = true }
end

function PlatformDriver:control_store_list(opts)
    if opts == nil or getmetatable(opts) ~= cap_args.ControlStoreListOpts then
        return false, 'invalid opts'
    end
    local keys, err = self.control_store:list(opts.ns)
    if not keys then return false, err end
    return true, { ns = opts.ns, keys = keys }
end

function PlatformDriver:control_store_status(opts)
    if opts ~= nil and getmetatable(opts) ~= cap_args.ControlStoreStatusOpts then
        return false, 'invalid opts'
    end
    return true, self.control_store:status()
end

-- artifact_store capability -------------------------------------------------

function PlatformDriver:artifact_store_create_sink(opts)
    if opts == nil or getmetatable(opts) ~= cap_args.ArtifactStoreCreateSinkOpts then
        return false, 'invalid opts'
    end
    local sink, err = self.artifact_store:create_sink(opts.meta, { policy = opts.policy })
    if not sink then return false, err end
    return true, sink
end

function PlatformDriver:artifact_store_import_path(opts)
    if opts == nil or getmetatable(opts) ~= cap_args.ArtifactStoreImportPathOpts then
        return false, 'invalid opts'
    end
    local art, err = self.artifact_store:import_path(opts.path, opts.meta, { policy = opts.policy })
    if not art then return false, err end
    return true, art
end

function PlatformDriver:artifact_store_import_source(opts)
    if opts == nil or getmetatable(opts) ~= cap_args.ArtifactStoreImportSourceOpts then
        return false, 'invalid opts'
    end
    local art, err = self.artifact_store:import_source(opts.source, opts.meta, { policy = opts.policy })
    if not art then return false, err end
    return true, art
end

function PlatformDriver:artifact_store_open(opts)
    if opts == nil or getmetatable(opts) ~= cap_args.ArtifactStoreOpenOpts then
        return false, 'invalid opts'
    end
    local art, err = self.artifact_store:open(opts.artifact_ref)
    if not art then return false, err end
    return true, art
end

function PlatformDriver:artifact_store_delete(opts)
    if opts == nil or getmetatable(opts) ~= cap_args.ArtifactStoreDeleteOpts then
        return false, 'invalid opts'
    end
    local ok, err = self.artifact_store:delete(opts.artifact_ref)
    if not ok then return false, err end
    return true, { ok = true }
end

function PlatformDriver:artifact_store_status(opts)
    if opts ~= nil and getmetatable(opts) ~= cap_args.ArtifactStoreStatusOpts then
        return false, 'invalid opts'
    end
    return true, self.artifact_store:status()
end

-- control managers ----------------------------------------------------------

local function run_control_loop(ch, methods, logger, what)
    fibers.current_scope():finally(function()
        dlog(logger, 'debug', { what = tostring(what or 'control_loop') .. '_exiting' })
    end)

    while true do
        local request, req_err = ch:get()
        if not request then
            dlog(logger, 'debug', { what = tostring(what or 'control_loop') .. '_closed', err = tostring(req_err) })
            break
        end

        local fn = methods[request.verb]
        local ok, value_or_err
        if type(fn) ~= 'function' then
            ok, value_or_err = false, 'unsupported verb: ' .. tostring(request.verb)
        else
            local st, _, r1, r2 = fibers.run_scope(function()
                return fn(request.opts)
            end)
            if st ~= 'ok' then
                ok, value_or_err = false, 'internal error: ' .. tostring(r1)
            else
                ok, value_or_err = r1, r2
            end
        end

        local reply = hal_types.new.Reply(ok, value_or_err)
        if reply then request.reply_ch:put(reply) end
    end
end

-- public interface ----------------------------------------------------------

function PlatformDriver:init()
    if self.initialised then return 'already initialised' end

    local cs, cerr = control_store_mod.new({}, self.logger)
    if not cs then return 'control store init failed: ' .. tostring(cerr) end
    self.control_store = cs

    local as, aerr = artifact_store_mod.new({}, self.logger)
    if not as then return 'artifact store init failed: ' .. tostring(aerr) end
    self.artifact_store = as

    self.initialised = true
    return ''
end

function PlatformDriver:capabilities(emit_ch)
    if not self.initialised then return nil, 'platform driver not initialised' end
    self.cap_emit_ch = emit_ch

    local caps = {}
    local cap, err = cap_types.new.PlatformCapability('1', self.platform_ch)
    if not cap then return nil, err end
    caps[#caps + 1] = cap

    local updater_cap, uerr = cap_types.new.UpdaterCapability('cm5', self.updater_ch)
    if not updater_cap then return nil, uerr end
    caps[#caps + 1] = updater_cap

    local control_cap, cerr = cap_types.new.ControlStoreCapability('update', self.control_store_ch)
    if not control_cap then return nil, cerr end
    caps[#caps + 1] = control_cap

    local artifact_cap, aerr = cap_types.new.ArtifactStoreCapability('main', self.artifact_store_ch)
    if not artifact_cap then return nil, aerr end
    caps[#caps + 1] = artifact_cap

    return caps, ''
end

function PlatformDriver:start()
    if not self.initialised then return false, 'platform driver not initialised' end

    if self.cap_emit_ch then
        local state_payload, state_err = hal_types.new.Emit('platform', '1', 'state', 'identity', self.identity)
        if state_payload then self.cap_emit_ch:put(state_payload) else dlog(self.logger, 'debug', { what = 'state_identity_emit_failed', err = tostring(state_err) }) end

        local meta_payload, meta_err = hal_types.new.Emit('platform', '1', 'meta', 'info', { provider = 'hal', version = 2 })
        if meta_payload then self.cap_emit_ch:put(meta_payload) else dlog(self.logger, 'debug', { what = 'meta_emit_failed', err = tostring(meta_err) }) end

        local updater_meta, updater_meta_err = hal_types.new.Emit('updater', 'cm5', 'meta', 'info', { provider = 'hal', version = 2 })
        if updater_meta then self.cap_emit_ch:put(updater_meta) else dlog(self.logger, 'debug', { what = 'updater_meta_emit_failed', err = tostring(updater_meta_err) }) end

        local control_meta, control_meta_err = hal_types.new.Emit('control_store', 'update', 'meta', 'info', { provider = 'hal', version = 1 })
        if control_meta then self.cap_emit_ch:put(control_meta) else dlog(self.logger, 'debug', { what = 'control_store_meta_emit_failed', err = tostring(control_meta_err) }) end

        local artifact_meta, artifact_meta_err = hal_types.new.Emit('artifact_store', 'main', 'meta', 'info', { provider = 'hal', version = 1 })
        if artifact_meta then self.cap_emit_ch:put(artifact_meta) else dlog(self.logger, 'debug', { what = 'artifact_store_meta_emit_failed', err = tostring(artifact_meta_err) }) end

        self:_emit_updater_status()
    end

    local platform_methods = {
        get = function(opts) return self:platform_get(opts) end,
    }
    local updater_methods = {
        prepare = function(opts) return self:updater_prepare(opts) end,
        stage = function(opts) return self:updater_stage(opts) end,
        commit = function(opts) return self:updater_commit(opts) end,
        status = function(opts) return self:updater_status(opts) end,
    }
    local control_methods = {
        get = function(opts) return self:control_store_get(opts) end,
        put = function(opts) return self:control_store_put(opts) end,
        delete = function(opts) return self:control_store_delete(opts) end,
        list = function(opts) return self:control_store_list(opts) end,
        status = function(opts) return self:control_store_status(opts) end,
    }
    local artifact_methods = {
        create_sink = function(opts) return self:artifact_store_create_sink(opts) end,
        import_path = function(opts) return self:artifact_store_import_path(opts) end,
        import_source = function(opts) return self:artifact_store_import_source(opts) end,
        open = function(opts) return self:artifact_store_open(opts) end,
        delete = function(opts) return self:artifact_store_delete(opts) end,
        status = function(opts) return self:artifact_store_status(opts) end,
    }

    local ok, err = self.scope:spawn(function() run_control_loop(self.platform_ch, platform_methods, self.logger, 'platform_control_manager') end)
    if not ok then return false, 'failed to spawn platform manager: ' .. tostring(err) end
    ok, err = self.scope:spawn(function() run_control_loop(self.updater_ch, updater_methods, self.logger, 'updater_control_manager') end)
    if not ok then return false, 'failed to spawn updater manager: ' .. tostring(err) end
    ok, err = self.scope:spawn(function() run_control_loop(self.control_store_ch, control_methods, self.logger, 'control_store_manager') end)
    if not ok then return false, 'failed to spawn control_store manager: ' .. tostring(err) end
    ok, err = self.scope:spawn(function() run_control_loop(self.artifact_store_ch, artifact_methods, self.logger, 'artifact_store_manager') end)
    if not ok then return false, 'failed to spawn artifact_store manager: ' .. tostring(err) end

    return true, ''
end

function PlatformDriver:stop(timeout)
    timeout = timeout or 5
    self.scope:cancel('platform driver stopped')
    local source = perform(op.named_choice {
        join = self.scope:join_op(),
        timeout = sleep.sleep_op(timeout),
    })
    if source == 'timeout' then return false, 'platform driver stop timeout' end
    return true, ''
end

local function new(logger)
    local scope, err = fibers.current_scope():child()
    if not scope then return nil, 'failed to create child scope: ' .. tostring(err) end

    scope:finally(function()
        local st, primary = scope:status()
        if st == 'failed' then
            dlog(logger, 'error', { what = 'scope_failed', err = tostring(primary), status = st })
        end
        dlog(logger, 'debug', { what = 'stopped' })
    end)

    return setmetatable({
        scope = scope,
        logger = logger,
        cap_emit_ch = nil,
        initialised = false,
        identity = read_identity(),
        cache = cache_mod.new(),
        control_store = nil,
        artifact_store = nil,
        platform_ch = channel.new(CONTROL_Q_LEN),
        updater_ch = channel.new(CONTROL_Q_LEN),
        control_store_ch = channel.new(CONTROL_Q_LEN),
        artifact_store_ch = channel.new(CONTROL_Q_LEN),
    }, PlatformDriver), ''
end

return { new = new }
