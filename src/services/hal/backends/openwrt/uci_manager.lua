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

local M = {}
local Manager = {}
Manager.__index = Manager

local Session = {}
Session.__index = Session

local unpack = rawget(table, 'unpack') or _G.unpack

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

local function is_uci_identifier(s)
	return type(s) == 'string' and s ~= '' and s:match('^[A-Za-z0-9_]+$') ~= nil
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
		if not is_uci_identifier(ch.stype or ch.section_type or ch.option) then
			return nil, 'change ' .. i .. ' section type must be a UCI identifier'
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
			if not is_uci_identifier(ch.option) then
				return nil, 'change ' .. i .. ' named section type must be a UCI identifier'
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
		if type(entry) == 'table' and type(entry[1]) == 'string' then
			local ok, verr = validate_argv(entry, 'restart_cmds[' .. i .. ']')
			if ok ~= true then return nil, verr end
			argv = normalise_legacy_argv(array_copy(entry))
		elseif type(entry) == 'table' then
			argv, err = semantic_reload_to_argv(entry)
			if not argv then return nil, err end
		else
			return nil, 'restart_cmds[' .. i .. '] must be an argv or semantic reload table'
		end
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
					entry = { argv = argv, sessions = {} }
					seen[key] = entry
					entries[#entries + 1] = entry
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
	return setmetatable({
		_tx = tx,
		_rx = rx,
		_scope = nil,
		_closed = false,
		_cursor = cursor,
		_cursor_note = cursor_note,
		_fake = cursor == nil,
		_debounce_s = tonumber(opts.debounce_s) or 0.1,
		_run_cmd = opts.run_cmd or default_run_cmd,
	}, Manager)
end

function Manager:start(scope)
	if self._closed then return nil, 'closed' end
	if self._scope then return true, nil end
	scope = scope or fibers.current_scope()
	if not scope then return nil, 'scope required' end
	self._scope = scope
	scope:finally(function (_, status, primary)
		self:terminate(primary or status or 'uci manager closed')
	end)
	local ok, err = scope:spawn(function (worker_scope) self:_run(worker_scope) end)
	if ok ~= true then return nil, err or 'uci manager spawn failed' end
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
		batch[#batch + 1] = item
	end
	return batch
end

function Manager:_apply_batch(batch)
	local results = {}
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
	for _, entry in ipairs(restart_entries) do
		local rok, rerr = self._run_cmd(entry.argv)
		if rok ~= true then
			for _, res in ipairs(entry.sessions) do
				res.ok = false
				res.err = res.err ~= '' and (res.err .. '; ' .. tostring(rerr)) or tostring(rerr)
			end
		end
	end

	for _, res in ipairs(results) do
		if res.item.reply_tx then
			local ok = queue.try_admit_now(res.item.reply_tx, { ok = res.ok, err = res.err })
			if ok ~= true then
				-- The caller has stopped waiting.  This is not a manager failure.
			end
		end
	end
end

function Manager:_run(owner_scope)
	while self._closed ~= true do
		local arms = { item = self._rx:recv_op() }
		if owner_scope and type(owner_scope.close_op) == 'function' then
			arms.closed = owner_scope:close_op()
		end
		local which, item = fibers.perform(fibers.named_choice(arms))
		if which == 'closed' or item == nil then return end
		local batch = self:_collect_batch(item, owner_scope)
		self:_apply_batch(batch)
	end
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
	self._tx:close(reason or 'uci manager terminated')
	self._scope = nil
	return true, nil
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
