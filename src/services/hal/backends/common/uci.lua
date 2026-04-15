local uci_mod   = require "uci"
local fibers    = require "fibers"
local channel   = require "fibers.channel"
local sleep     = require "fibers.sleep"
local Scope     = require "fibers.scope"
local exec      = require "fibers.io.exec"

---@class UciChange
---@field op 'set'|'add'|'delete'
---@field config string
---@field section? string
---@field stype? string
---@field option? string
---@field value? any

---@class UciCommitRecord
---@field changes UciChange[]
---@field config string
---@field restart_cmds? string[][]   list of argv lists to exec after commit
---@field reply_ch? table            channel to receive {ok, err} when applied

-- Module-level buffered commit queue shared by all sessions
local commit_ch = channel.new(10)

-- Reactor start guard
local started   = false

---Apply a single commit record to an open UCI cursor.
---Errors on any cursor failure so the caller can revert and propagate.
---@param cursor table  uci cursor object
---@param record UciCommitRecord
local function apply_changes(cursor, record)
    for _, change in ipairs(record.changes) do
        if change.op == 'set' then
            local ok = cursor:set(change.config, change.section, change.option, change.value)
            if not ok then
                error(("uci set failed: %s.%s.%s = %s"):format(
                    change.config, change.section or '?',
                    change.option or '?', tostring(change.value)))
            end
        elseif change.op == 'add' then
            local name = cursor:add(change.config, change.stype)
            if not name then
                error(("uci add failed: %s type=%s"):format(
                    change.config, change.stype or '?'))
            end
        elseif change.op == 'delete' then
            local ok
            if change.option then
                ok = cursor:delete(change.config, change.section, change.option)
            else
                ok = cursor:delete(change.config, change.section)
            end
            if not ok then
                error(("uci delete failed: %s.%s%s"):format(
                    change.config, change.section or '?',
                    change.option and ('.' .. change.option) or ''))
            end
        end
    end
    local ok = cursor:commit(record.config)
    if not ok then
        error(("uci commit failed: %s"):format(record.config))
    end
end

---Run a list of restart command specs sequentially using the exec module.
---Each entry is an argv list, e.g. { '/etc/init.d/network', 'restart' }.
---@param cmds string[][]
---@return boolean ok
---@return string  err
local function run_restart_cmds(cmds)
    for _, argv in ipairs(cmds) do
        local cmd = exec.command(argv)
        local status, code = fibers.perform(cmd:run_op())
        if status ~= 'exited' or code ~= 0 then
            return false, table.concat(argv, ' ') .. ' exited with status=' ..
                tostring(status) .. ' code=' .. tostring(code)
        end
    end
    return true, ""
end

---Deduplicate restart commands across a batch of record results.
---Only includes entries from records whose changes applied successfully.
---Returns a list of entries; each entry holds one unique argv and the set of
---per-record result objects that depend on it so errors can be fed back.
---@class RestartEntry
---@field argv string[]
---@field sessions table[]  elements are the result objects {record, ok, err}

---@param record_results table[]  array of {record=UciCommitRecord, ok=boolean, err=string}
---@return RestartEntry[]
local function trim_restarts(record_results)
    local seen    = {}  -- key → index into entries
    local entries = {}
    for _, res in ipairs(record_results) do
        if res.ok and res.record.restart_cmds then
            for _, argv in ipairs(res.record.restart_cmds) do
                local key = table.concat(argv, '\0')
                if not seen[key] then
                    seen[key]          = #entries + 1
                    entries[#entries + 1] = { argv = argv, sessions = {} }
                end
                local entry = entries[seen[key]]
                -- Deduplicate sessions too (same record can list same cmd twice)
                local already = false
                for _, s in ipairs(entry.sessions) do
                    if s == res then already = true; break end
                end
                if not already then
                    entry.sessions[#entry.sessions + 1] = res
                end
            end
        end
    end
    return entries
end

---Reactor fiber: drains the commit queue and debounces restarts (1s window).
---Each record is applied independently; failures revert that record's staged
---changes and are reported only to its own reply channel.
local function reactor()
    local cursor = uci_mod.cursor()

    while true do
        -- Collect the first record then debounce within a 1s window
        local batch = { commit_ch:get() }

        while true do
            local name, result = fibers.perform(fibers.named_choice({
                more    = commit_ch:get_op(),
                timeout = sleep.sleep_op(1.0),
            }))
            if name == 'timeout' then break end
            batch[#batch + 1] = result
        end

        -- Phase 1: apply each record's changes independently
        local record_results = {}
        for _, r in ipairs(batch) do
            local ok, err = pcall(apply_changes, cursor, r)
            if not ok then
                -- Revert any uncommitted staged changes for this config
                pcall(cursor.revert, cursor, r.config)
                record_results[#record_results + 1] = { record = r, ok = false, err = tostring(err) }
            else
                record_results[#record_results + 1] = { record = r, ok = true, err = "" }
            end
        end

        -- Phase 2: build deduplicated restart list from successful records
        local restart_entries = trim_restarts(record_results)

        -- Phase 3: run each unique restart; propagate failures to dependent sessions
        for _, entry in ipairs(restart_entries) do
            local rok, rerr = run_restart_cmds({ entry.argv })
            if not rok then
                for _, res in ipairs(entry.sessions) do
                    res.ok  = false
                    res.err = res.err ~= "" and (res.err .. "; " .. rerr) or rerr
                end
            end
        end

        -- Phase 4: reply to every session that supplied a reply channel
        for _, res in ipairs(record_results) do
            if res.record.reply_ch then
                res.record.reply_ch:put({ ok = res.ok, err = res.err })
            end
        end
    end
end

---Start the UCI reactor once, attached to the root scope.
---Subsequent calls are no-ops.
---@return nil
local function ensure_started()
    if started then return end
    started = true
    Scope.root():spawn(reactor)
end

---Create a new staged UCI session.
---Changes are queued on commit(); the reactor applies them asynchronously.
---@class UciSession
---@field _changes UciChange[]
local Session = {}
Session.__index = Session

---@return UciSession
local function new_session()
    return setmetatable({ _changes = {} }, Session)
end

---@param config string
---@param section string
---@param option string
---@param value any
function Session:set(config, section, option, value)
    table.insert(self._changes, {
        op = 'set',
        config = config,
        section = section,
        option = option,
        value = value,
    })
end

---@param config string
---@param stype string  UCI section type
function Session:add(config, stype)
    table.insert(self._changes, {
        op = 'add', config = config, stype = stype,
    })
end

---@param config string
---@param section string
---@param option? string  if omitted the whole section is deleted
function Session:delete(config, section, option)
    table.insert(self._changes, {
        op = 'delete', config = config, section = section, option = option,
    })
end

---Queue staged changes to be applied by the reactor.
---Returns a reply channel that will receive {ok=boolean, err=string} once
---the commit (and any restart commands) have completed.
---@param config string        UCI config file name
---@param restart_cmds string[][]|nil  List of argv lists to exec after apply (debounced, 1s)
---@return table reply_ch      channel — receive to wait for completion
function Session:commit(config, restart_cmds)
    local reply_ch = channel.new(1)
    commit_ch:put({
        changes      = self._changes,
        config       = config,
        restart_cmds = restart_cmds,
        reply_ch     = reply_ch,
    })
    self._changes = {}
    return reply_ch
end

---Apply staged changes immediately using a temporary cursor (synchronous).
---Use only during driver initialisation where blocking is acceptable.
---Returns ok (boolean) and err (string).
---@param config string
---@param restart_cmds string[][]|nil  List of argv lists to exec immediately (not debounced)
---@return boolean ok
---@return string  err
function Session:commit_sync(config, restart_cmds)
    local ok, err = pcall(function()
        local c = uci_mod.cursor()
        apply_changes(c, { changes = self._changes, config = config })
        if restart_cmds then
            local rok, rerr = run_restart_cmds(restart_cmds)
            if not rok then error(rerr) end
        end
    end)
    self._changes = {}
    if not ok then
        return false, tostring(err)
    end
    return true, ""
end

---Read a single UCI value without going through the reactor queue.
---Safe for read-only use from any fiber (no staged state involved).
---@param config string
---@param section string
---@param option string
---@return any value   nil if not found
local function get_value(config, section, option)
    local c = uci_mod.cursor()
    return c:get(config, section, option)
end

return {
    ensure_started = ensure_started,
    new_session    = new_session,
    get_value      = get_value,
}
