-- services/hal/backends/openwrt/uci_manager.lua
-- Scoped UCI commit manager.
--
-- This module is OpenWrt HAL infrastructure.  New strict code should use the
-- Op-returning submit_op/commit_op path.  The compatibility singleton may expose
-- blocking commit() only at the edge while preserving old wifi service callers.
--
-- Ownership contract:
--   * before admission succeeds, the caller still owns staged changes;
--   * after admission succeeds, this manager owns a normalised copy of the
--     commit record;
--   * caller cancellation after admission abandons only that caller's wait, not
--     the already-admitted commit.
--
-- UCI model covered here:
--   * named section creation through set(config, section, stype)
--   * anonymous section creation through add(config, stype), returning a
--     session-local alias which may be used by later staged changes;
--   * scalar and list option set;
--   * add_list / del_list implemented against the manager-owned cursor;
--   * delete option / section;
--   * rename option / section where the libuci-lua binding supports it;
--   * reorder section where the libuci-lua binding supports it;
--   * commit, revert-on-failure and deduplicated reload/restart commands.

local fibers = require 'fibers'
local sleep = require 'fibers.sleep'
local mailbox = require 'fibers.mailbox'
local queue = require 'devicecode.support.queue'
local file = require 'fibers.io.file'

local M = {}
local Manager = {}
Manager.__index = Manager

local ActivationRunner = {}
ActivationRunner.__index = ActivationRunner

local Session = {}
Session.__index = Session

local unpack = rawget(table, 'unpack') or _G.unpack

local function elapsed_ms(t0)
	if not t0 then return nil end
	return math.floor(((fibers.now() - t0) * 1000) + 0.5)
end

local function log_manager(self, level, payload)
	local logger = self and self._logger
	if logger and type(logger[level]) == 'function' then
		payload = payload or {}
		payload.component = payload.component or 'uci_manager'
		logger[level](logger, payload)
	end
end

local function trace_fields(trace)
	local out = {}
	if type(trace) == 'table' then
		for k, v in pairs(trace) do out[k] = v end
	end
	return out
end

local function shallow_copy(t)
	local out = {}
	for k, v in pairs(t or {}) do out[k] = v end
	return out
end

local function deep_copy(v)
	if type(v) ~= 'table' then return v end
	local out = {}
	for k, vv in pairs(v) do out[k] = deep_copy(vv) end
	return out
end

local function copy_changes(changes)
	local out = {}
	for i, ch in ipairs(changes or {}) do
		out[i] = deep_copy(ch)
	end
	return out
end

local function is_array(t)
	if type(t) ~= 'table' then return false end
	local n = 0
	for k in pairs(t) do
		if type(k) ~= 'number' or k < 1 or k % 1 ~= 0 then return false end
		if k > n then n = k end
	end
	return n == #t
end

local function array_copy(t)
	local out = {}
	for i = 1, #(t or {}) do out[i] = t[i] end
	return out
end

local function ensure_pkg_file(confdir, pkg)
	if type(confdir) ~= 'string' or confdir == '' or type(pkg) ~= 'string' or pkg == '' then return true, nil end
	local path = confdir .. '/' .. pkg

	local f = file.open(path, 'r')
	if f then f:close(); return true, nil end

	local err
	f, err = file.open(path, 'w')
	if not f then return nil, tostring(err) end
	local ok, werr = fibers.perform(f:write_op(''))
	local cok, cerr = f:close()
	if ok == false or ok == nil then return nil, tostring(werr or 'failed to create UCI package file ' .. path) end
	if cok == false or cok == nil then return nil, tostring(cerr or 'failed to close UCI package file ' .. path) end
	return true, nil
end

local function is_uci_identifier(s)
	return type(s) == 'string' and s ~= '' and s:match('^[A-Za-z0-9_]+$') ~= nil
end

local function is_uci_section_type(s)
	return type(s) == 'string' and s ~= '' and s:match('^[A-Za-z0-9_-]+$') ~= nil
end

local function validate_pkg(s, label)
	if not is_uci_identifier(s) then
		return nil, label .. ' must be a non-empty UCI identifier'
	end
	return true, nil
end

local function validate_section_ref(s, label)
	if type(s) ~= 'string' or s == '' then
		return nil, label .. ' required'
	end
	return true, nil
end

local function to_uci_value(v)
	local tv = type(v)
	if tv == 'boolean' then return v and '1' or '0' end
	if tv == 'number' or tv == 'string' then return tostring(v) end
	if tv == 'table' then
		if not is_array(v) then return nil, 'UCI table values must be arrays' end
		local out = {}
		for i = 1, #v do
			local cv, err = to_uci_value(v[i])
			if cv == nil then return nil, err end
			out[i] = cv
		end
		return out
	end
	if v == nil then return nil end
	return tostring(v)
end

local function as_list(v)
	if v == nil then return {} end
	if type(v) == 'table' then
		local out = {}
		for i = 1, #v do out[i] = tostring(v[i]) end
		return out
	end
	return { tostring(v) }
end

local function validate_change(record, ch, i)
	if type(ch) ~= 'table' then return nil, 'change ' .. i .. ' must be a table' end
	if ch.config ~= nil and ch.config ~= record.config then
		return nil, 'change ' .. i .. ' config differs from record.config'
	end
	local op = ch.op
	if op ~= 'set' and op ~= 'delete' and op ~= 'add' and op ~= 'add_list'
		and op ~= 'del_list' and op ~= 'rename' and op ~= 'reorder' then
		return nil, 'change ' .. i .. ' has unsupported op'
	end

	if op == 'add' then
		if not is_uci_section_type(ch.stype or ch.section_type or ch.option) then
			return nil, 'change ' .. i .. ' section type must be a valid UCI section type'
		end
		if ch.alias ~= nil and (type(ch.alias) ~= 'string' or ch.alias == '') then
			return nil, 'change ' .. i .. ' alias must be a non-empty string when present'
		end
		return true, nil
	end

	local ok, serr = validate_section_ref(ch.section, 'change ' .. i .. ' section')
	if ok ~= true then return nil, serr end

	if op == 'set' then
		if type(ch.option) ~= 'string' or ch.option == '' then
			return nil, 'change ' .. i .. ' option/section type required'
		end
		if ch.value == nil then
			if not is_uci_section_type(ch.option) then
				return nil, 'change ' .. i .. ' named section type must be a valid UCI section type'
			end
		else
			local _, verr = to_uci_value(ch.value)
			if verr then return nil, 'change ' .. i .. ': ' .. tostring(verr) end
		end
	elseif op == 'delete' then
		if ch.option ~= nil and type(ch.option) ~= 'string' then
			return nil, 'change ' .. i .. ' option must be a string when present'
		end
	elseif op == 'add_list' or op == 'del_list' then
		if type(ch.option) ~= 'string' or ch.option == '' then
			return nil, 'change ' .. i .. ' option required'
		end
		if ch.value == nil then return nil, 'change ' .. i .. ' value required' end
		local _, verr = to_uci_value(ch.value)
		if verr then return nil, 'change ' .. i .. ': ' .. tostring(verr) end
	elseif op == 'rename' then
		if ch.option ~= nil and type(ch.option) ~= 'string' then
			return nil, 'change ' .. i .. ' option must be a string when present'
		end
		if type(ch.name or ch.new_name) ~= 'string' or (ch.name or ch.new_name) == '' then
			return nil, 'change ' .. i .. ' rename target required'
		end
	elseif op == 'reorder' then
		if type(ch.position) ~= 'number' then return nil, 'change ' .. i .. ' position must be a number' end
	end
	return true, nil
end

local function validate_argv(argv, label)
	if type(argv) ~= 'table' or #argv == 0 then return nil, label .. ' must be a non-empty argv array' end
	for i = 1, #argv do
		if type(argv[i]) ~= 'string' or argv[i] == '' then
			return nil, label .. '[' .. i .. '] must be a non-empty string'
		end
	end
	return true, nil
end

local function semantic_reload_to_argv(entry)
	local kind = entry.kind or entry.action
	local target = entry.target or entry.service
	if kind ~= 'reload' and kind ~= 'restart' then
		return nil, 'unsupported reload action: ' .. tostring(kind)
	end
	if type(target) ~= 'string' or target == '' then
		return nil, 'reload target required'
	end
	if target == 'wifi' or target == 'wireless' then
		return { '/sbin/wifi', kind }, nil
	end
	return { '/etc/init.d/' .. target, kind }, nil
end

local function normalise_legacy_argv(argv)
	-- Existing radio/band providers pass legacy command shorthands such as
	-- { 'wifi', 'reload' } and { 'service', 'dawn', 'restart' }.  Preserve this
	-- compatibility at the HAL edge while encouraging new code to use semantic
	-- reload tables.
	if argv[1] == 'wifi' then
		local out = { '/sbin/wifi' }
		for i = 2, #argv do out[#out + 1] = argv[i] end
		return out
	end
	if argv[1] == 'service' and type(argv[2]) == 'string' and type(argv[3]) == 'string' then
		local out = { '/etc/init.d/' .. argv[2], argv[3] }
		for i = 4, #argv do out[#out + 1] = argv[i] end
		return out
	end
	return argv
end

local function normalise_restart_cmds(cmds)
	if cmds == nil then return {}, nil end
	if type(cmds) ~= 'table' then return nil, 'restart_cmds must be a table' end
	local out = {}
	for i = 1, #cmds do
		local entry = cmds[i]
		local argv, err
		local wait = true
		if type(entry) == 'table' and type(entry[1]) == 'string' then
			local ok, verr = validate_argv(entry, 'restart_cmds[' .. i .. ']')
			if ok ~= true then return nil, verr end
			wait = entry.wait ~= false and entry.async ~= true
			argv = normalise_legacy_argv(array_copy(entry))
		elseif type(entry) == 'table' then
			wait = entry.wait ~= false and entry.async ~= true
			argv, err = semantic_reload_to_argv(entry)
			if not argv then return nil, err end
		else
			return nil, 'restart_cmds[' .. i .. '] must be an argv or semantic reload table'
		end
		argv.wait = wait
		out[#out + 1] = argv
	end
	return out, nil
end

local function normalise_record(record)
	if type(record) ~= 'table' then return nil, 'record must be a table' end
	if type(record.config) ~= 'string' or record.config == '' then return nil, 'record.config required' end
	local ok_pkg, pkg_err = validate_pkg(record.config, 'record.config')
	if ok_pkg ~= true then return nil, pkg_err end
	if type(record.changes) ~= 'table' then return nil, 'record.changes must be a table' end

	local out = {
		config = record.config,
		changes = copy_changes(record.changes),
		reply_tx = record.reply_tx,
		replace_package = record.replace_package == true,
	}
	for i, ch in ipairs(out.changes) do
		local ok, err = validate_change(out, ch, i)
		if ok ~= true then return nil, err end
		ch.config = out.config
	end
	local restarts, rerr = normalise_restart_cmds(record.restart_cmds)
	if not restarts then return nil, rerr end
	out.restart_cmds = restarts
	return out, nil
end

local function resolve_section(record, aliases, section)
	if aliases and aliases[section] then return aliases[section] end
	return section
end

local function revert_record(cursor, record)
	if cursor and type(cursor.revert) == 'function' then
		pcall(function () cursor:revert(record.config) end)
	end
end

local function record_packages(records)
	local seen, out = {}, {}
	for _, record in ipairs(records or {}) do
		if record and record.config and not seen[record.config] then
			seen[record.config] = true
			out[#out + 1] = record.config
		end
	end
	table.sort(out)
	return out
end

local function copy_package_table(pkg)
	local out = {}
	for k, v in pairs(pkg or {}) do
		if type(k) == 'string' and k:sub(1, 1) ~= '.' then
			out[k] = deep_copy(v)
		end
	end
	return out
end

local function snapshot_packages(cursor, packages)
	local out = {}
	if not cursor then return out, nil end
	if type(cursor.get_all) ~= 'function' then return nil, 'uci get_all unavailable; cannot snapshot for rollback' end
	for _, pkg in ipairs(packages or {}) do
		if type(cursor.load) == 'function' then pcall(function () cursor:load(pkg) end) end
		out[pkg] = copy_package_table(cursor:get_all(pkg) or {})
	end
	return out, nil
end

local function delete_all_sections(cursor, pkg)
	if not cursor then return true, nil end
	if type(cursor.get_all) ~= 'function' then return nil, 'uci get_all unavailable; cannot clear package for rollback' end
	local cur = cursor:get_all(pkg) or {}
	for secname, rec in pairs(cur) do
		if type(secname) == 'string' and secname:sub(1, 1) ~= '.' and type(rec) == 'table' then
			local ok, err = cursor:delete(pkg, secname)
			if ok ~= true then return nil, tostring(err or ('delete failed for ' .. pkg .. '.' .. secname)) end
		end
	end
	return true, nil
end

local function restore_package(cursor, pkg, snapshot)
	if not cursor then return true, nil end
	if type(cursor.revert) == 'function' then pcall(function () cursor:revert(pkg) end) end
	local ok, err = delete_all_sections(cursor, pkg)
	if ok ~= true then return nil, err end
	for secname, rec in pairs(snapshot or {}) do
		if type(secname) == 'string' and secname:sub(1, 1) ~= '.' and type(rec) == 'table' then
			local stype = rec['.type']
			if type(stype) ~= 'string' or stype == '' then
				return nil, 'rollback snapshot missing section type for ' .. pkg .. '.' .. secname
			end
			ok, err = cursor:set(pkg, secname, stype)
			if ok ~= true then return nil, tostring(err or ('restore create failed for ' .. pkg .. '.' .. secname)) end
			for opt, value in pairs(rec) do
				if type(opt) == 'string' and opt:sub(1, 1) ~= '.' then
					local uval, verr = to_uci_value(value)
					if verr then return nil, verr end
					ok, err = cursor:set(pkg, secname, opt, uval)
					if ok ~= true then return nil, tostring(err or ('restore set failed for ' .. pkg .. '.' .. secname .. '.' .. opt)) end
				end
			end
		end
	end
	ok, err = cursor:commit(pkg)
	if ok ~= true then return nil, tostring(err or ('rollback commit failed for ' .. pkg)) end
	return true, nil
end

local function restore_packages(cursor, snapshots, packages)
	local restored, errors = {}, {}
	for _, pkg in ipairs(packages or {}) do
		local ok, err = restore_package(cursor, pkg, snapshots and snapshots[pkg] or {})
		if ok == true then
			restored[#restored + 1] = pkg
		else
			errors[#errors + 1] = tostring(pkg) .. ': ' .. tostring(err)
		end
	end
	if #errors > 0 then return nil, table.concat(errors, '; '), restored end
	return true, nil, restored
end

local function cursor_add_list(cursor, config, section, option, value)
	if type(cursor.add_list) == 'function' then
		local ok, err = cursor:add_list(config, section, option, value)
		if ok then return true, nil end
		-- Some Lua bindings do not expose add_list; if present but rejected, report it.
		return nil, tostring(err or 'uci add_list failed')
	end
	local cur = as_list(cursor:get(config, section, option))
	cur[#cur + 1] = value
	local ok, err = cursor:set(config, section, option, cur)
	if not ok then return nil, tostring(err or 'uci add_list(set) failed') end
	return true, nil
end

local function cursor_del_list(cursor, config, section, option, value)
	if type(cursor.del_list) == 'function' then
		local ok, err = cursor:del_list(config, section, option, value)
		if ok then return true, nil end
		return nil, tostring(err or 'uci del_list failed')
	end
	local cur = as_list(cursor:get(config, section, option))
	local out = {}
	local removed = false
	for i = 1, #cur do
		if tostring(cur[i]) == tostring(value) then
			removed = true
		else
			out[#out + 1] = cur[i]
		end
	end
	if not removed then return true, nil end
	if #out == 0 then
		local ok, err = cursor:delete(config, section, option)
		if not ok then return nil, tostring(err or 'uci del_list(delete) failed') end
		return true, nil
	end
	local ok, err = cursor:set(config, section, option, out)
	if not ok then return nil, tostring(err or 'uci del_list(set) failed') end
	return true, nil
end

local function cursor_rename_option_fallback(cursor, config, section, option, new_name)
	local value = cursor:get(config, section, option)
	if value == nil then return nil, 'uci rename option failed: option not found' end
	local ok, err = cursor:set(config, section, new_name, value)
	if not ok then return nil, tostring(err or 'uci rename option(set) failed') end
	ok, err = cursor:delete(config, section, option)
	if not ok then return nil, tostring(err or 'uci rename option(delete) failed') end
	return true, nil
end

local function cursor_rename_section_fallback(cursor, config, section, new_name)
	if not is_uci_identifier(new_name) then
		return nil, 'uci rename section target must be a UCI identifier'
	end
	if type(cursor.get_all) ~= 'function' then
		return nil, 'uci rename unavailable in Lua binding and get_all fallback unavailable'
	end
	local all = cursor:get_all(config, section)
	if type(all) ~= 'table' then return nil, 'uci rename section failed: section not found' end
	local stype = all['.type']
	if type(stype) ~= 'string' or stype == '' then
		return nil, 'uci rename section failed: section type missing'
	end
	local ok, err = cursor:set(config, new_name, stype)
	if not ok then return nil, tostring(err or 'uci rename section(create) failed') end
	for k, v in pairs(all) do
		if type(k) == 'string' and k:sub(1, 1) ~= '.' then
			ok, err = cursor:set(config, new_name, k, v)
			if not ok then return nil, tostring(err or ('uci rename section(set ' .. tostring(k) .. ') failed')) end
		end
	end
	ok, err = cursor:delete(config, section)
	if not ok then return nil, tostring(err or 'uci rename section(delete old) failed') end
	return true, nil
end

local function cursor_rename(cursor, config, section, option, new_name)
	if type(cursor.rename) == 'function' then
		local ok, err
		if option ~= nil then
			ok, err = cursor:rename(config, section, option, new_name)
		else
			ok, err = cursor:rename(config, section, new_name)
		end
		if ok then return true, nil end
		return nil, tostring(err or 'uci rename failed')
	end
	if option ~= nil then
		return cursor_rename_option_fallback(cursor, config, section, option, new_name)
	end
	return cursor_rename_section_fallback(cursor, config, section, new_name)
end

local function apply_with_cursor(cursor, record)
	if not cursor then
		return true, nil -- explicit fake/no-uci mode for tests and non-OpenWrt hosts.
	end
	if type(cursor.load) == 'function' then pcall(function () cursor:load(record.config) end) end
	if record.replace_package == true then
		local ok, err = delete_all_sections(cursor, record.config)
		if ok ~= true then return nil, err end
	end
	local aliases = {}
	for _, change in ipairs(record.changes) do
		local op = change.op
		local section = resolve_section(record, aliases, change.section)
		if op == 'add' then
			if type(cursor.add) ~= 'function' then return nil, 'uci add unavailable in Lua binding' end
			local stype = change.stype or change.section_type or change.option
			local name, err = cursor:add(record.config, stype)
			if not name then return nil, tostring(err or 'uci add failed') end
			if change.alias then aliases[change.alias] = name end
		elseif op == 'set' then
			if change.value == nil then
				local ok, err = cursor:set(record.config, section, change.option)
				if not ok then return nil, tostring(err or 'uci set section failed') end
			else
				local value, verr = to_uci_value(change.value)
				if verr then return nil, verr end
				local ok, err = cursor:set(record.config, section, change.option, value)
				if not ok then return nil, tostring(err or 'uci set failed') end
			end
		elseif op == 'delete' then
			local ok, err
			if change.option ~= nil then
				ok, err = cursor:delete(record.config, section, change.option)
			else
				ok, err = cursor:delete(record.config, section)
			end
			if not ok then return nil, tostring(err or 'uci delete failed') end
		elseif op == 'add_list' then
			local values = type(change.value) == 'table' and change.value or { change.value }
			for i = 1, #values do
				local value, verr = to_uci_value(values[i])
				if verr then return nil, verr end
				local ok, err = cursor_add_list(cursor, record.config, section, change.option, value)
				if not ok then return nil, err end
			end
		elseif op == 'del_list' then
			local values = type(change.value) == 'table' and change.value or { change.value }
			for i = 1, #values do
				local value, verr = to_uci_value(values[i])
				if verr then return nil, verr end
				local ok, err = cursor_del_list(cursor, record.config, section, change.option, value)
				if not ok then return nil, err end
			end
		elseif op == 'rename' then
			local new_name = change.name or change.new_name
			local ok, err = cursor_rename(cursor, record.config, section, change.option, new_name)
			if ok and change.option == nil and aliases[change.section] then aliases[change.section] = new_name end
			if not ok then return nil, tostring(err or 'uci rename failed') end
		elseif op == 'reorder' then
			if type(cursor.reorder) ~= 'function' then return nil, 'uci reorder unavailable in Lua binding' end
			local ok, err = cursor:reorder(record.config, section, math.floor(change.position))
			if not ok then return nil, tostring(err or 'uci reorder failed') end
		end
	end
	local ok, err = cursor:commit(record.config)
	if not ok then return nil, tostring(err or 'uci commit failed') end
	return true, nil
end

local function default_run_cmd(argv)
	local exec = require 'fibers.io.exec'
	local cmd = exec.command(unpack(argv))
	local status, code = fibers.perform(cmd:run_op())
	if status ~= 'exited' or code ~= 0 then
		return false, table.concat(argv, ' ') .. ' exited with status=' .. tostring(status) .. ' code=' .. tostring(code)
	end
	return true, nil
end

local NO_ACTIVATION = {}

local function restart_key(argv)
	return table.concat(argv, '\0')
end

local function trim_restarts(record_results)
	local seen = {}
	local entries = {}
	for _, res in ipairs(record_results) do
		if res.ok and res.record and res.record.restart_cmds then
			for _, argv in ipairs(res.record.restart_cmds) do
				local key = restart_key(argv)
				local entry = seen[key]
				if not entry then
					entry = { argv = argv, wait = argv.wait ~= false, sessions = {} }
					seen[key] = entry
					entries[#entries + 1] = entry
				elseif argv.wait ~= false then
					-- If any caller requires a synchronous restart, keep the shared
					-- deduplicated command synchronous for all sessions that depend on it.
					entry.wait = true
				end
				local duplicate = false
				for _, s in ipairs(entry.sessions) do
					if s == res then duplicate = true; break end
				end
				if not duplicate then entry.sessions[#entry.sessions + 1] = res end
			end
		end
	end
	return entries
end

local function split_activation_entries(entries)
	local sync, async = {}, {}
	for _, entry in ipairs(entries or {}) do
		if entry.wait ~= false then sync[#sync + 1] = entry else async[#async + 1] = entry end
	end
	return sync, async
end

local function activation_entry_count(entries)
	return #(entries or {})
end

local function activation_argvs(entries)
	local out = {}
	for i, entry in ipairs(entries or {}) do out[i] = array_copy(entry.argv or {}) end
	return out
end

local function new_activation_runner(manager)
	local tx, rx = mailbox.new(8, { full = 'drop_oldest' })
	return setmetatable({
		_manager = manager,
		_tx = tx,
		_rx = rx,
		_closed = false,
		_next_id = 0,
		_latest_id = 0,
		_running_id = nil,
		_status = { state = 'idle' },
	}, ActivationRunner)
end

function ActivationRunner:submit(entries, trace)
	if self._closed then return nil, 'activation runner closed' end
	if activation_entry_count(entries) == 0 then
		return { state = 'none', commands = 0 }, nil
	end
	self._next_id = (self._next_id or 0) + 1
	local item = {
		id = self._next_id,
		entries = entries,
		trace = trace_fields(trace),
		submitted_at = fibers.now(),
	}
	self._latest_id = item.id
	local ok, err = queue.try_admit_now(self._tx, item)
	if ok ~= true then return nil, err or 'activation runner busy' end
	self._status = {
		state = self._running_id and 'queued' or 'scheduled',
		generation = item.id,
		commands = activation_entry_count(entries),
		submitted_at = item.submitted_at,
	}
	log_manager(self._manager, 'info', (function ()
		local p = trace_fields(trace)
		p.what = 'uci_activation_scheduled'
		p.activation_id = item.id
		p.commands = activation_entry_count(entries)
		p.argvs = activation_argvs(entries)
		return p
	end)())
	return {
		state = 'scheduled',
		generation = item.id,
		commands = activation_entry_count(entries),
	}, nil
end

function ActivationRunner:status()
	return deep_copy(self._status or { state = 'idle' })
end

function ActivationRunner:_next_item(owner_scope)
	local arms = { item = self._rx:recv_op() }
	if owner_scope and type(owner_scope.close_op) == 'function' then arms.closed = owner_scope:close_op() end
	local which, item = fibers.perform(fibers.named_choice(arms))
	if which == 'closed' or item == nil then return nil end

	local drained = 0
	while true do
		local newer = queue.try_now(self._rx:recv_op(), NO_ACTIVATION)
		if newer == NO_ACTIVATION or newer == nil then break end
		item = newer
		drained = drained + 1
	end
	if drained > 0 then
		log_manager(self._manager, 'info', (function ()
			local p = trace_fields(item.trace)
			p.what = 'uci_activation_coalesced'
			p.activation_id = item.id
			p.dropped = drained
			return p
		end)())
	end
	return item
end

function ActivationRunner:_run_entry(entry, trace, activation_id)
	local argv = entry.argv or {}
	local t0 = fibers.now()
	log_manager(self._manager, 'info', (function ()
		local p = trace_fields(trace)
		p.what = 'uci_activation_command_begin'
		p.activation_id = activation_id
		p.argv = array_copy(argv)
		return p
	end)())
	local ok, err = self._manager._run_cmd(argv)
	log_manager(self._manager, ok == true and 'info' or 'warn', (function ()
		local p = trace_fields(trace)
		p.what = 'uci_activation_command_done'
		p.activation_id = activation_id
		p.argv = array_copy(argv)
		p.ok = ok == true
		p.err = err
		p.elapsed_ms = elapsed_ms(t0)
		return p
	end)())
	return ok == true, err
end

function ActivationRunner:_run(owner_scope)
	while self._closed ~= true do
		local item = self:_next_item(owner_scope)
		if item == nil then return end
		self._running_id = item.id
		local t0 = fibers.now()
		self._status = {
			state = 'running',
			generation = item.id,
			commands = activation_entry_count(item.entries),
			started_at = t0,
		}
		log_manager(self._manager, 'info', (function ()
			local p = trace_fields(item.trace)
			p.what = 'uci_activation_runner_begin'
			p.activation_id = item.id
			p.commands = activation_entry_count(item.entries)
			p.argvs = activation_argvs(item.entries)
			return p
		end)())

		local ok, err = true, nil
		for _, entry in ipairs(item.entries or {}) do
			local rok, rerr = self:_run_entry(entry, item.trace, item.id)
			if rok ~= true then ok, err = false, rerr; break end
		end

		local stale = item.id < (self._latest_id or item.id)
		self._status = {
			state = ok and 'done' or 'failed',
			generation = item.id,
			commands = activation_entry_count(item.entries),
			ok = ok == true,
			err = err,
			stale = stale,
			elapsed_ms = elapsed_ms(t0),
		}
		if ok ~= true then
			self._manager._last_activation_error = {
				activation_id = item.id,
				err = tostring(err or 'activation failed'),
			}
		end
		log_manager(self._manager, ok == true and 'info' or 'warn', (function ()
			local p = trace_fields(item.trace)
			p.what = 'uci_activation_runner_done'
			p.activation_id = item.id
			p.ok = ok == true
			p.err = err
			p.stale = stale
			p.elapsed_ms = elapsed_ms(t0)
			return p
		end)())
		self._running_id = nil
	end
end

function ActivationRunner:start(scope)
	if self._closed then return nil, 'activation runner closed' end
	if self._scope then return true, nil end
	scope = scope or fibers.current_scope()
	if not scope then return nil, 'scope required' end
	self._scope = scope
	local ok, err = scope:spawn(function (worker_scope) self:_run(worker_scope) end)
	if ok ~= true then return nil, err or 'activation runner spawn failed' end
	return true, nil
end

function ActivationRunner:terminate(reason)
	if self._closed then return true, nil end
	self._closed = true
	self._tx:close(reason or 'activation runner terminated')
	self._scope = nil
	return true, nil
end

local function make_cursor(opts)
	if opts and opts.cursor ~= nil then return opts.cursor, nil end
	local ok, uci_or_err = pcall(require, 'uci')
	if not ok or not uci_or_err or type(uci_or_err.cursor) ~= 'function' then
		if opts and opts.allow_fake == false then
			return nil, 'uci module unavailable'
		end
		return nil, 'uci module unavailable; manager running in fake mode'
	end
	return uci_or_err.cursor(opts and opts.confdir, opts and opts.savedir), nil
end

function M.new(opts)
	opts = opts or {}
	local tx, rx = mailbox.new(opts.queue_len or 16, { full = opts.full or 'reject_newest' })
	local cursor, cursor_note = make_cursor(opts)
	if cursor == nil and opts.allow_fake == false then
		return nil, cursor_note or 'uci unavailable'
	end
	local confdir = opts.confdir
	if confdir == nil and opts.cursor == nil and cursor ~= nil then confdir = '/etc/config' end
	local mgr = setmetatable({
		_tx = tx,
		_rx = rx,
		_scope = nil,
		_closed = false,
		_cursor = cursor,
		_cursor_note = cursor_note,
		_fake = cursor == nil,
		_confdir = confdir,
		_savedir = opts.savedir,
		_debounce_s = tonumber(opts.debounce_s) or 0.1,
		_run_cmd = opts.run_cmd or default_run_cmd,
		_run_cmd_explicit = type(opts.run_cmd) == 'function',
		_logger = opts.logger,
		_pending = {},
	}, Manager)
	mgr._activation = new_activation_runner(mgr)
	return mgr
end

function Manager:start(owner_scope)
	if self._closed then return nil, 'closed' end
	if self._scope then return true, nil end
	owner_scope = owner_scope or fibers.current_scope()
	if not owner_scope then return nil, 'owner scope required' end

	-- The UCI manager is long-lived owned work under the supplied lifetime
	-- scope.  Do not install finalisers on owner_scope here: lua-fibers only
	-- permits scope:finally on an already-started scope from inside that same
	-- scope.  Provider apply calls may start the manager from a request fibre,
	-- so create a private child scope and install its finaliser before it starts.
	local child, cerr = owner_scope:child()
	if not child then return nil, cerr or 'uci manager scope create failed' end

	self._scope = child
	child:finally(function (_, status, primary)
		self:terminate(primary or status or 'uci manager closed')
	end)

	local aok, aerr = self._activation:start(child)
	if aok ~= true then
		self._scope = nil
		child:cancel(aerr or 'activation runner start failed')
		return nil, aerr or 'activation runner start failed'
	end

	local ok, err = child:spawn(function (worker_scope) self:_run(worker_scope) end)
	if ok ~= true then
		self._activation:terminate(err or 'uci manager spawn failed')
		self._scope = nil
		child:cancel(err or 'uci manager spawn failed')
		return nil, err or 'uci manager spawn failed'
	end

	return true, nil
end

function Manager:_collect_batch(first_item, owner_scope)
	local batch = { first_item }
	while self._closed ~= true do
		local arms = {
			more = self._rx:recv_op(),
			timeout = sleep.sleep_op(self._debounce_s):wrap(function () return true end),
		}
		if owner_scope and type(owner_scope.close_op) == 'function' then
			arms.closed = owner_scope:close_op()
		end
		local which, item = fibers.perform(fibers.named_choice(arms))
		if which == 'timeout' or which == 'closed' then break end
		if item == nil then break end
		if item.transaction then
			self._pending[#self._pending + 1] = item
			break
		end
		batch[#batch + 1] = item
	end
	return batch
end

function Manager:_ensure_packages(packages, trace)
	local t0 = fibers.now()
	log_manager(self, 'debug', (function ()
		local p = trace_fields(trace)
		p.what = 'uci_ensure_packages_begin'
		p.packages = packages or {}
		return p
	end)())
	if self._fake == true then
		log_manager(self, 'debug', (function ()
			local p = trace_fields(trace)
			p.what = 'uci_ensure_packages_done'
			p.fake = true
			p.elapsed_ms = elapsed_ms(t0)
			return p
		end)())
		return true, nil
	end
	if type(self._confdir) == 'string' and self._confdir ~= '' then
		local ok, err = file.mkdir_p(self._confdir)
		if ok ~= true then
			log_manager(self, 'warn', (function ()
				local p = trace_fields(trace)
				p.what = 'uci_ensure_packages_done'
				p.ok = false
				p.err = 'failed to create UCI confdir ' .. self._confdir .. ': ' .. tostring(err)
				p.elapsed_ms = elapsed_ms(t0)
				return p
			end)())
			return nil, 'failed to create UCI confdir ' .. self._confdir .. ': ' .. tostring(err)
		end
	end
	for _, pkg in ipairs(packages or {}) do
		local pkg_t0 = fibers.now()
		local ok, err = ensure_pkg_file(self._confdir, pkg)
		log_manager(self, ok == true and 'debug' or 'warn', (function ()
			local p = trace_fields(trace)
			p.what = 'uci_ensure_package_file'
			p.package = pkg
			p.ok = ok == true
			p.err = err
			p.elapsed_ms = elapsed_ms(pkg_t0)
			return p
		end)())
		if ok ~= true then return nil, err end
		if self._cursor and type(self._cursor.load) == 'function' then pcall(function () self._cursor:load(pkg) end) end
	end
	log_manager(self, 'debug', (function ()
		local p = trace_fields(trace)
		p.what = 'uci_ensure_packages_done'
		p.ok = true
		p.elapsed_ms = elapsed_ms(t0)
		return p
	end)())
	return true, nil
end

function Manager:_run_restart_entry(entry, trace)
	local wait = entry.wait ~= false
	log_manager(self, 'info', (function ()
		local p = trace_fields(trace)
		p.what = wait and 'uci_activation_begin' or 'uci_activation_schedule_begin'
		p.argv = array_copy(entry.argv or {})
		p.wait = wait
		return p
	end)())
	if wait then
		local t0 = fibers.now()
		local ok, err = self._run_cmd(entry.argv)
		log_manager(self, ok == true and 'info' or 'warn', (function ()
			local p = trace_fields(trace)
			p.what = 'uci_activation_done'
			p.argv = array_copy(entry.argv or {})
			p.ok = ok == true
			p.err = err
			p.elapsed_ms = elapsed_ms(t0)
			return p
		end)())
		return ok, err
	end
	local activation, err = self:_schedule_activation({ entry }, trace)
	return activation ~= nil, err
end

function Manager:_schedule_activation(entries, trace)
	if not entries or #entries == 0 then return { state = 'none', commands = 0 }, nil end
	if not self._activation then return nil, 'activation runner unavailable' end
	return self._activation:submit(entries, trace)
end

function Manager:_apply_batch(batch)
	local results = {}
	local pkgs = record_packages((function () local rs = {}; for _, item in ipairs(batch or {}) do rs[#rs + 1] = item.record end; return rs end)())
	local eok, eerr = self:_ensure_packages(pkgs)
	if eok ~= true then
		for _, item in ipairs(batch or {}) do
			if item.reply_tx then queue.try_admit_now(item.reply_tx, { ok = false, err = tostring(eerr) }) end
		end
		return
	end
	for _, item in ipairs(batch) do
		local record = item.record
		local ok, err
		if self._closed then
			ok, err = nil, 'uci manager closed'
		else
			ok, err = apply_with_cursor(self._cursor, record)
			if ok ~= true then revert_record(self._cursor, record) end
		end
		results[#results + 1] = { item = item, record = record, ok = ok == true, err = err or '' }
	end

	local restart_entries = trim_restarts(results)
	local sync_entries, async_entries = split_activation_entries(restart_entries)
	for _, entry in ipairs(sync_entries) do
		local rok, rerr = self:_run_restart_entry(entry)
		if rok ~= true then
			for _, res in ipairs(entry.sessions) do
				res.ok = false
				res.err = res.err ~= '' and (res.err .. '; ' .. tostring(rerr)) or tostring(rerr)
			end
		end
	end
	local activation, aerr = nil, nil
	if #async_entries > 0 then
		activation, aerr = self:_schedule_activation(async_entries)
		if activation == nil then
			for _, entry in ipairs(async_entries) do
				for _, res in ipairs(entry.sessions) do
					res.ok = false
					res.err = res.err ~= '' and (res.err .. '; ' .. tostring(aerr)) or tostring(aerr)
				end
			end
		end
	end

	for _, res in ipairs(results) do
		if res.item.reply_tx then
			local ok = queue.try_admit_now(res.item.reply_tx, { ok = res.ok, err = res.err, activation = activation })
			if ok ~= true then
				-- The caller has stopped waiting.  This is not a manager failure.
			end
		end
	end
end


function Manager:_apply_transaction(item)
	local t0 = fibers.now()
	local tx = item.transaction or {}
	local records = tx.records or {}
	local packages = tx.packages or record_packages(records)
	local trace = tx.trace or {}
	log_manager(self, 'info', (function ()
		local p = trace_fields(trace)
		p.what = 'uci_transaction_begin'
		p.packages = packages
		p.records = #records
		return p
	end)())
	local eok, eerr = self:_ensure_packages(packages, trace)
	if eok ~= true then
		log_manager(self, 'warn', (function ()
			local p = trace_fields(trace)
			p.what = 'uci_transaction_done'
			p.ok = false
			p.status = 'failed_no_change'
			p.err = tostring(eerr)
			p.elapsed_ms = elapsed_ms(t0)
			return p
		end)())
		if item.reply_tx then queue.try_admit_now(item.reply_tx, { ok = false, status = 'failed_no_change', err = tostring(eerr), packages = packages }) end
		return
	end

	local result = {
		ok = true,
		status = 'ok',
		packages = packages,
		rollback = { attempted = false, ok = nil, packages = {} },
		timings = {},
	}

	local phase = fibers.now()
	log_manager(self, 'debug', (function ()
		local p = trace_fields(trace)
		p.what = 'uci_snapshot_begin'
		p.packages = packages
		return p
	end)())
	local snapshots, snap_err = snapshot_packages(self._cursor, packages)
	result.timings.snapshot_ms = elapsed_ms(phase)
	log_manager(self, snapshots and 'debug' or 'warn', (function ()
		local p = trace_fields(trace)
		p.what = 'uci_snapshot_done'
		p.ok = snapshots ~= nil
		p.err = snap_err
		p.elapsed_ms = elapsed_ms(phase)
		return p
	end)())
	if snapshots == nil then
		result.ok = false
		result.status = 'failed_no_change'
		result.err = snap_err
		result.timings.total_ms = elapsed_ms(t0)
		log_manager(self, 'warn', (function ()
			local p = trace_fields(trace)
			p.what = 'uci_transaction_done'
			p.ok = false
			p.status = result.status
			p.err = result.err
			p.elapsed_ms = result.timings.total_ms
			return p
		end)())
		if item.reply_tx then queue.try_admit_now(item.reply_tx, result) end
		return
	end

	local record_results = {}
	local failed = nil
	for _, record in ipairs(records) do
		local rt0 = fibers.now()
		log_manager(self, 'debug', (function ()
			local p = trace_fields(trace)
			p.what = 'uci_record_apply_begin'
			p.config = record.config
			p.changes = #(record.changes or {})
			p.replace_package = record.replace_package == true
			return p
		end)())
		local ok, err
		if self._closed then
			ok, err = nil, 'uci manager closed'
		else
			ok, err = apply_with_cursor(self._cursor, record)
		end
		local record_ms = elapsed_ms(rt0)
		log_manager(self, ok == true and 'debug' or 'warn', (function ()
			local p = trace_fields(trace)
			p.what = 'uci_record_apply_done'
			p.config = record.config
			p.ok = ok == true
			p.err = err
			p.elapsed_ms = record_ms
			return p
		end)())
		local res = { record = record, ok = ok == true, err = err or '', elapsed_ms = record_ms }
		record_results[#record_results + 1] = res
		result.timings['commit_' .. tostring(record.config) .. '_ms'] = record_ms
		if ok ~= true then
			failed = { step = 'uci_commit', config = record.config, err = err }
			break
		end
	end

	if not failed then
		phase = fibers.now()
		local restart_entries = trim_restarts(record_results)
		log_manager(self, 'info', (function ()
			local p = trace_fields(trace)
			p.what = 'uci_activation_phase_begin'
			p.entries = #restart_entries
			p.fake = self._fake == true
			return p
		end)())
		if self._fake == true and self._run_cmd_explicit ~= true then
			-- In fake-UCI mode there is no OpenWrt system to reload.  Unit tests and
			-- non-OpenWrt hosts should still exercise validation, reconciliation and
			-- transaction/rollback semantics without attempting /etc/init.d commands.
		else
			local sync_entries, async_entries = split_activation_entries(restart_entries)
			for _, entry in ipairs(sync_entries) do
				local rok, rerr = self:_run_restart_entry(entry, trace)
				if rok ~= true then
					failed = { step = 'restart', argv = entry.argv, err = rerr }
					break
				end
			end
			if not failed and #async_entries > 0 then
				local activation, aerr = self:_schedule_activation(async_entries, trace)
				if activation then
					result.activation = activation
				else
					failed = { step = 'activation_schedule', err = aerr }
				end
			end
		end
		result.timings.activation_ms = elapsed_ms(phase)
		log_manager(self, failed and 'warn' or 'info', (function ()
			local p = trace_fields(trace)
			p.what = 'uci_activation_phase_done'
			p.ok = failed == nil
			p.err = failed and failed.err or nil
			p.activation = result.activation
			p.elapsed_ms = result.timings.activation_ms
			return p
		end)())
	end

	if failed then
		result.ok = false
		result.failed_step = failed.step
		result.failed_config = failed.config
		result.err = tostring(failed.err or failed.step or 'uci transaction failed')
		if tx.rollback ~= false then
			result.rollback.attempted = true
			phase = fibers.now()
			log_manager(self, 'warn', (function ()
				local p = trace_fields(trace)
				p.what = 'uci_rollback_begin'
				p.failed_step = failed.step
				p.failed_config = failed.config
				return p
			end)())
			local rok, rerr, restored = restore_packages(self._cursor, snapshots, packages)
			result.timings.rollback_ms = elapsed_ms(phase)
			result.rollback.ok = rok == true
			result.rollback.packages = restored or {}
			log_manager(self, rok == true and 'info' or 'warn', (function ()
				local p = trace_fields(trace)
				p.what = 'uci_rollback_done'
				p.ok = rok == true
				p.err = rerr
				p.elapsed_ms = result.timings.rollback_ms
				return p
			end)())
			if rok == true then
				result.status = 'failed_rolled_back'
			else
				result.status = 'failed_rollback_failed'
				result.rollback.err = tostring(rerr)
			end
		else
			result.status = 'failed_partial'
		end
	end

	result.timings.total_ms = elapsed_ms(t0)
	log_manager(self, result.ok == true and 'info' or 'warn', (function ()
		local p = trace_fields(trace)
		p.what = 'uci_transaction_done'
		p.ok = result.ok == true
		p.status = result.status
		p.err = result.err
		p.failed_step = result.failed_step
		p.failed_config = result.failed_config
		p.activation = result.activation
		p.elapsed_ms = result.timings.total_ms
		return p
	end)())

	if item.reply_tx then
		local sent = queue.try_admit_now(item.reply_tx, result)
		log_manager(self, sent == true and 'debug' or 'warn', (function ()
			local p = trace_fields(trace)
			p.what = 'uci_transaction_reply'
			p.sent = sent == true
			p.elapsed_ms = elapsed_ms(t0)
			return p
		end)())
	end
end

function Manager:_run(owner_scope)
	while self._closed ~= true do
		local item = table.remove(self._pending, 1)
		if item == nil then
			local arms = { item = self._rx:recv_op() }
			if owner_scope and type(owner_scope.close_op) == 'function' then
				arms.closed = owner_scope:close_op()
			end
			local which, got = fibers.perform(fibers.named_choice(arms))
			if which == 'closed' or got == nil then return end
			item = got
		end
		if item.transaction then
			self:_apply_transaction(item)
		else
			local batch = self:_collect_batch(item, owner_scope)
			self:_apply_batch(batch)
		end
	end
end


function Manager:transaction_op(spec, opts)
	spec = spec or {}
	opts = opts or {}
	local admitted_flag = false
	return fibers.run_scope_op(function ()
		if self._closed then return { ok = false, status = 'closed', err = 'closed' }, false end
		local records = {}
		for i, record in ipairs(spec.records or {}) do
			local normalised, err = normalise_record(record)
			if not normalised then
				return { ok = false, status = 'invalid', err = 'record ' .. tostring(i) .. ': ' .. tostring(err) }, false
			end
			records[#records + 1] = normalised
		end
		if #records == 0 then return { ok = true, status = 'ok', packages = {}, rollback = { attempted = false } }, false end
		local reply_tx, reply_rx = mailbox.new(1, { full = 'reject_newest' })
		local admitted, aerr = queue.try_admit_now(self._tx, {
			transaction = {
				records = records,
				packages = spec.packages or record_packages(records),
				rollback = spec.rollback ~= false,
				trace = opts.trace,
			},
			reply_tx = reply_tx,
		})
		if admitted ~= true then
			return { ok = false, status = 'busy', err = 'uci_manager_busy: ' .. tostring(aerr or 'not_admitted') }, false
		end
		admitted_flag = true
		if type(opts.on_admitted) == 'function' then opts.on_admitted() end
		local result = fibers.perform(reply_rx:recv_op())
		if result == nil then return { ok = false, status = 'closed', err = 'uci manager closed' }, true end
		return result, true
	end):wrap(function (status, _report, result, admitted)
		if status ~= 'ok' then return { ok = false, status = 'failed', err = tostring(result or status) }, admitted_flag end
		return result, (admitted == true) or admitted_flag
	end)
end

function Manager:submit_op(record, opts)
	opts = opts or {}
	local admitted_flag = false
	return fibers.run_scope_op(function ()
		if self._closed then return false, 'closed', false end
		local normalised, err = normalise_record(record)
		if not normalised then return false, err, false end
		local reply_tx, reply_rx = mailbox.new(1, { full = 'reject_newest' })
		local admitted, aerr = queue.try_admit_now(self._tx, {
			record = normalised,
			reply_tx = reply_tx,
		})
		if admitted ~= true then
			return false, 'uci_manager_busy: ' .. tostring(aerr or 'not_admitted'), false
		end
		admitted_flag = true
		if type(opts.on_admitted) == 'function' then
			local ok_admit, admit_err = pcall(opts.on_admitted)
			if ok_admit ~= true then return false, tostring(admit_err or 'on_admitted failed'), true end
		end
		local result = fibers.perform(reply_rx:recv_op())
		if result == nil then return false, 'uci manager closed', true end
		return result.ok == true, result.err, true
	end):wrap(function (status, _report, ok, err, admitted)
		if status ~= 'ok' then return false, tostring(ok or status), admitted_flag end
		return ok == true, err, (admitted == true) or admitted_flag
	end)
end

function Manager:new_session()
	return setmetatable({ _manager = self, _changes = {}, _alias_n = 0 }, Session)
end

function Manager:terminate(reason)
	if self._closed then return true, nil end
	self._closed = true
	local why = reason or 'uci manager terminated'
	if self._activation then self._activation:terminate(why) end
	self._tx:close(why)
	local scope = self._scope
	self._scope = nil
	if scope then scope:cancel(why) end
	return true, nil
end

function Manager:activation_status()
	if not self._activation then return { state = 'unavailable' } end
	return self._activation:status()
end

function Manager:fake_mode()
	return self._fake, self._cursor_note
end

function Session:set(config, section, option, value)
	self._changes[#self._changes + 1] = {
		op = 'set',
		config = config,
		section = section,
		option = option,
		value = value,
	}
	return true
end

function Session:add(config, stype, alias)
	self._alias_n = (self._alias_n or 0) + 1
	alias = alias or ('__dc_uci_pending_' .. tostring(self._alias_n))
	self._changes[#self._changes + 1] = {
		op = 'add',
		config = config,
		stype = stype,
		alias = alias,
	}
	return alias
end

function Session:add_list(config, section, option, value)
	self._changes[#self._changes + 1] = {
		op = 'add_list',
		config = config,
		section = section,
		option = option,
		value = value,
	}
	return true
end

function Session:del_list(config, section, option, value)
	self._changes[#self._changes + 1] = {
		op = 'del_list',
		config = config,
		section = section,
		option = option,
		value = value,
	}
	return true
end

function Session:delete(config, section, option)
	self._changes[#self._changes + 1] = {
		op = 'delete',
		config = config,
		section = section,
		option = option,
	}
	return true
end

function Session:rename(config, section, option_or_name, maybe_name)
	local option, name
	if maybe_name == nil then
		name = option_or_name
	else
		option = option_or_name
		name = maybe_name
	end
	self._changes[#self._changes + 1] = {
		op = 'rename',
		config = config,
		section = section,
		option = option,
		name = name,
	}
	return true
end

function Session:reorder(config, section, position)
	self._changes[#self._changes + 1] = {
		op = 'reorder',
		config = config,
		section = section,
		position = position,
	}
	return true
end

function Session:commit_op(config, restart_cmds)
	return fibers.run_scope_op(function ()
		local changes = copy_changes(self._changes)
		local ok, err = fibers.perform(self._manager:submit_op({
			config = config,
			changes = changes,
			restart_cmds = restart_cmds,
		}, {
			on_admitted = function () self._changes = {} end,
		}))
		return ok == true, err
	end):wrap(function (status, _report, ok, err)
		if status ~= 'ok' then return false, tostring(ok or status) end
		return ok == true, err
	end)
end

function Session:commit(config, restart_cmds)
	return fibers.perform(self:commit_op(config, restart_cmds))
end

M._normalise_record_for_test = normalise_record

return M
