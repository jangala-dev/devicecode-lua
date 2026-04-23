local uci_mod   = require "uci"
local fibers    = require "fibers"
local channel   = require "fibers.channel"
local sleep     = require "fibers.sleep"
local Scope     = require "fibers.scope"
local exec      = require "fibers.io.exec"

---@class UciChange
---@field op 'set'|'delete'
---@field config string
---@field section? string
---@field option? string   section type when value is nil (named-section creation)
---@field value? any       absent/nil means create a named section of type `option`

---@class UciCommitRecord
---@field changes UciChange[]
---@field config string
---@field restart_cmds? string[][]   list of argv lists to exec after commit
---@field reply_ch? table            channel to receive {ok, err} when applied

-- Module-level buffered commit queue shared by all sessions
local commit_ch = channel.new(10)

-- Reactor start guard
local started   = false

---Convert a value to a UCI-safe string.
---Booleans become "1"/"0"; everything else uses tostring().
---@param v any
---@return string
local function to_uci_string(v)
    if type(v) == 'boolean' then return v and '1' or '0' end
    return tostring(v)
end

---Apply a single commit record to an open UCI cursor.
---Errors on any cursor failure so the caller can revert and propagate.
---@param cursor table  uci cursor object
---@param record UciCommitRecord
local function apply_changes(cursor, record)
    for _, change in ipairs(record.changes) do
        if change.op == 'set' then
            local ok, err
            if change.value == nil then
                -- 3-arg form: create a named section of type change.option
                ok, err = cursor:set(change.config, change.section, change.option)
                if not ok then
                    error(("uci set (named section) failed: %s.%s type=%s: %s"):format(
                        change.config, change.section or '?', change.option or '?', tostring(err)))
                end
            else
                ok, err = cursor:set(change.config, change.section, change.option, to_uci_string(change.value))
                if not ok then
                    error(("uci set failed: %s.%s.%s = %s: %s"):format(
                        change.config, change.section or '?',
                        change.option or '?', tostring(change.value), tostring(err)))
                end
            end
        elseif change.op == 'delete' then
            local ok, err
            if change.option then
                ok, err = cursor:delete(change.config, change.section, change.option)
            else
                ok, err = cursor:delete(change.config, change.section)
            end
            if not ok then
                error(("uci delete failed: %s.%s%s: %s"):format(
                    change.config, change.section or '?',
                    change.option and ('.' .. change.option) or '', tostring(err)))
            end
        end
    end
    local ok, err = cursor:commit(record.config)
    if not ok then
        error(("uci commit failed: %s: %s"):format(record.config, tostring(err)))
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
                timeout = sleep.sleep_op(0.1),
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

---Set an option value, or create a named section when called with 3 arguments.
---3-arg form: `set(config, section, stype)` creates a named section of the given type.
---4-arg form: `set(config, section, option, value)` sets an option value.
---@param config string
---@param section string
---@param option string  option name, or section type when value is absent
---@param value? any
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
---@param section string
---@param option? string  if omitted the whole section is deleted
function Session:delete(config, section, option)
    table.insert(self._changes, {
        op = 'delete', config = config, section = section, option = option,
    })
end

---Queue staged changes to be applied by the reactor and wait for the result.
---Blocks until the commit (and any restart commands) have completed.
---@param config string        UCI config file name
---@param restart_cmds string[][]|nil  List of argv lists to exec after apply (debounced, 1s)
---@return boolean ok
---@return string? err
function Session:commit(config, restart_cmds)
    local reply_ch = channel.new(1)
    commit_ch:put({
        changes      = self._changes,
        config       = config,
        restart_cmds = restart_cmds,
        reply_ch     = reply_ch,
    })
    self._changes = {}
    local result = reply_ch:get()
    return result.ok, result.err
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

---Return true if a UCI section exists in the given config file.
---@param config string
---@param section string
---@return boolean
local function section_exists(config, section)
    local c = uci_mod.cursor()
    return c:get(config, section) ~= nil
end

---Return all section names in a config file matching an optional type filter.
---Calls cursor:foreach which iterates committed+staged values.
---@param config string
---@param stype? string  UCI section type to filter by (e.g. 'wifi-iface'); nil = all sections
---@return string[]  section names
local function get_sections(config, stype)
    local c = uci_mod.cursor()
    local names = {}
    c:foreach(config, stype, function(s)
        if s['.name'] then
            names[#names + 1] = s['.name']
        end
    end)
    return names
end

return {
    ensure_started  = ensure_started,
    new_session     = new_session,
    get_value       = get_value,
    section_exists  = section_exists,
    get_sections    = get_sections,
}
