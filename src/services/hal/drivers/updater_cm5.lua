local fibers = require 'fibers'
local op = require 'fibers.op'
local sleep = require 'fibers.sleep'
local file = require 'fibers.io.file'
local exec = require 'fibers.io.exec'
local channel = require 'fibers.channel'

local hal_types = require 'services.hal.types.core'
local cap_types = require 'services.hal.types.capabilities'
local cap_args = require 'services.hal.types.capability_args'
local control_store_mod = require 'services.hal.drivers.control_store'
local artifact_store_mod = require 'services.hal.drivers.artifact_store'

local perform = fibers.perform
local CONTROL_Q_LEN = 8

local Driver = {}
Driver.__index = Driver

local function dlog(logger, level, payload)
    if logger and logger[level] then logger[level](logger, payload) end
end

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

local function updater_script_path(opts)
    return (opts and opts.script) or os.getenv('DEVICECODE_UPDATE_SCRIPT') or '/root/scripts/update.sh'
end

local function read_fw_printenv(varname)
    local cmd = exec.command('fw_printenv', varname)
    local out, _, code = perform(cmd:output_op())
    if code ~= 0 or not out then return '' end
    return trim(out:match(varname .. '=(.+)$') or '')
end

local function read_identity()
    local function safe_read(path)
        local v, _ = read_file(path)
        return trim(v or '')
    end

    return {
        hw_revision    = safe_read('/etc/hwrevision'),
        fw_version     = safe_read('/etc/fwversion'),
        serial         = safe_read('/data/serial'),
        board_revision = read_fw_printenv('board_revision'),
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
    if state == 'staged' then return 'staged' end
    if state == 'committing' or state == 'awaiting_reboot' then
        if raw_state.expected_version and current_version == raw_state.expected_version then return 'running' end
        return 'awaiting_reboot'
    end
    if state == 'failed' or state == 'rollback_detected' then return state end
    if current_version and current_version ~= '' then return 'running' end
    return state
end

local function health_from_status(status)
    status = type(status) == 'table' and status or {}
    local state = tostring(status.state or '')
    if state == 'failed' or state == 'rollback_detected' then
        return { state = 'degraded', reason = tostring(status.last_error or state) }
    end
    if state == 'unavailable' then
        return { state = 'unknown', reason = tostring(status.last_error or state) }
    end
    return { state = 'ok', reason = nil }
end

local function run_control_loop(ch, methods, logger, what)
    fibers.current_scope():finally(function() dlog(logger, 'debug', { what = tostring(what or 'control_loop') .. '_exiting' }) end)
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
            local st, _, r1, r2 = fibers.run_scope(function() return fn(request.opts) end)
            if st ~= 'ok' then ok, value_or_err = false, 'internal error: ' .. tostring(r1) else ok, value_or_err = r1, r2 end
        end
        local reply = hal_types.new.Reply(ok, value_or_err)
        if reply then request.reply_ch:put(reply) end
    end
end

function Driver:_read_updater_state()
    local obj, err = self.control_store:get('updater/cm5', 'state')
    if not obj then
        if err == 'not_found' then return default_updater_state(), '' end
        return default_updater_state(), err
    end
    if type(obj) ~= 'table' then return default_updater_state(), 'invalid_state' end
    return obj, ''
end

function Driver:_write_updater_state(state)
    state = state or default_updater_state()
    state.updated_at = state.updated_at or os.time()
    return self.control_store:put('updater/cm5', 'state', state)
end

function Driver:_emit_updater_facts()
    if not self.cap_emit_ch then return end
    local ok, status = self:status(cap_args.new.UpdaterStatusOpts(false))
    if not ok then return end

    local software_payload, software_err = hal_types.new.Emit('updater', self.id, 'state', 'software', {
        version = status.fw_version,
        build = nil,
        image_id = status.targetfw or status.fw_version,
        boot_id = status.bootedfw,
        bootedfw = status.bootedfw,
        targetfw = status.targetfw,
        upgrade_available = status.upgrade_available,
        hw_revision = status.hw_revision,
        serial = status.serial,
        board_revision = status.board_revision,
    })
    if software_payload then self.cap_emit_ch:put(software_payload) else dlog(self.logger, 'debug', { what = 'updater_software_emit_failed', err = tostring(software_err) }) end

    local updater_payload, updater_err = hal_types.new.Emit('updater', self.id, 'state', 'updater', {
        state = status.state,
        raw_state = status.raw_state,
        staged = status.staged,
        artifact_ref = status.artifact_ref,
        artifact_meta = status.artifact_meta,
        expected_version = status.expected_version,
        last_error = status.last_error,
        updated_at = status.updated_at,
    })
    if updater_payload then self.cap_emit_ch:put(updater_payload) else dlog(self.logger, 'debug', { what = 'updater_fact_emit_failed', err = tostring(updater_err) }) end

    local health_payload, health_err = hal_types.new.Emit('updater', self.id, 'state', 'health', health_from_status(status))
    if health_payload then self.cap_emit_ch:put(health_payload) else dlog(self.logger, 'debug', { what = 'updater_health_emit_failed', err = tostring(health_err) }) end
end

function Driver:init()
    if self.initialised then return 'already initialised' end

    local cs, cerr = control_store_mod.new(self.opts.control_store or {}, self.logger)
    if not cs then return 'control store init failed: ' .. tostring(cerr) end
    self.control_store = cs

    local as, aerr = artifact_store_mod.new(self.opts.artifact_store or {}, self.logger)
    if not as then return 'artifact store init failed: ' .. tostring(aerr) end
    self.artifact_store = as

    self.identity = read_identity()
    self.initialised = true
    return ''
end

function Driver:status(opts)
    if opts ~= nil and getmetatable(opts) ~= cap_args.UpdaterStatusOpts then return false, 'invalid opts' end

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

function Driver:prepare(opts)
    if opts ~= nil and getmetatable(opts) ~= cap_args.UpdaterPrepareOpts then return false, 'invalid opts' end
    local _, status = self:status(cap_args.new.UpdaterStatusOpts(false))
    return true, status
end

function Driver:stage(opts)
    if opts == nil or getmetatable(opts) ~= cap_args.UpdaterStageOpts then return false, 'invalid opts' end

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

    self:_emit_updater_facts()
    return true, {
        staged = true,
        artifact_ref = opts.artifact_ref,
        artifact_meta = artifact,
        expected_version = opts.expected_version,
        artifact_retention = 'keep',
    }
end

function Driver:commit(opts)
    if opts ~= nil and getmetatable(opts) ~= cap_args.UpdaterCommitOpts then return false, 'invalid opts' end

    local state = self:_read_updater_state()
    if state.state ~= 'staged' or type(state.artifact_ref) ~= 'string' or state.artifact_ref == '' then
        return false, 'no_staged_artifact'
    end

    local resolved, rerr = self.artifact_store:resolve_local(state.artifact_ref)
    if not resolved then return false, rerr end

    local script = updater_script_path(self.opts)
    local sf, ferr = file.open(script, 'r')
    if not sf then return false, 'update script unavailable: ' .. tostring(ferr) end
    sf:close()

    state.state = 'awaiting_reboot'
    state.updated_at = os.time()
    local ok, err = self:_write_updater_state(state)
    if not ok then return false, err end
    self:_emit_updater_facts()

    local env = {
        DEVICECODE_STAGED_ARTIFACT = resolved.path,
        DEVICECODE_STAGED_ARTIFACT_REF = state.artifact_ref,
        DEVICECODE_UPDATE_KIND = (opts and opts.mode) or 'cm5',
    }

    local spawn_ok, spawn_err = fibers.spawn(function()
        local cmd = exec.command({ script, env = env, stdout = 'inherit', stderr = 'inherit' })
        perform(cmd:run_op())
    end)
    if not spawn_ok then return false, tostring(spawn_err) end

    return true, { started = true, artifact_ref = state.artifact_ref, artifact_meta = state.artifact_meta }
end

function Driver:capabilities(emit_ch)
    if not self.initialised then return nil, 'cm5 updater provider not initialised' end
    self.cap_emit_ch = emit_ch
    local cap, err = cap_types.new.UpdaterCapability(self.id, self.control_ch)
    if not cap then return nil, err end
    return { cap }, ''
end

function Driver:start()
    if not self.initialised then return false, 'cm5 updater provider not initialised' end
    if self.cap_emit_ch then
        local meta, err = hal_types.new.Emit('updater', self.id, 'meta', 'info', { provider = 'hal.updater_cm5', version = 2 })
        if meta then self.cap_emit_ch:put(meta) else dlog(self.logger, 'debug', { what = 'updater_meta_emit_failed', id = self.id, err = tostring(err) }) end
        self:_emit_updater_facts()
    end
    local methods = {
        prepare = function(opts) return self:prepare(opts) end,
        stage = function(opts) return self:stage(opts) end,
        commit = function(opts) return self:commit(opts) end,
        status = function(opts) return self:status(opts) end,
    }
    local ok, err = self.scope:spawn(function() run_control_loop(self.control_ch, methods, self.logger, 'updater_cm5_control_manager') end)
    if not ok then return false, 'failed to spawn updater_cm5 control manager: ' .. tostring(err) end
    return true, ''
end

function Driver:stop(timeout)
    timeout = timeout or 5
    self.scope:cancel('cm5 updater provider stopped')
    local source = perform(op.named_choice { join = self.scope:join_op(), timeout = sleep.sleep_op(timeout) })
    if source == 'timeout' then return false, 'cm5 updater provider stop timeout' end
    return true, ''
end

local function new(id, opts, logger)
    if type(id) ~= 'string' or id == '' then return nil, 'invalid id' end
    local scope, err = fibers.current_scope():child()
    if not scope then return nil, 'failed to create child scope: ' .. tostring(err) end
    return setmetatable({
        id = id,
        opts = opts or {},
        logger = logger,
        scope = scope,
        control_store = nil,
        artifact_store = nil,
        identity = {},
        initialised = false,
        control_ch = channel.new(CONTROL_Q_LEN),
        cap_emit_ch = nil,
    }, Driver), ''
end

return { new = new, Driver = Driver }
