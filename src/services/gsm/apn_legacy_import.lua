-- services/gsm/apn_legacy_import.lua
--
-- One-time import of custom APNs saved by the v0.9 local UI. v0.9 keeps them under
-- default.apns in /data/configs/user.cfg, which survives the update to later firmware
-- but which nothing else reads. The file is never changed, so going back to v0.9 still
-- finds it.
--
-- The store's key decides whether the import has happened: once it exists, whether from
-- this import or from a save in the current UI, the import never writes again. The caller
-- runs this before it serves APN requests, so nothing else writes the key meanwhile.
--
-- APN records can hold passwords, so nothing here returns or logs file contents in an
-- error.

local fibers = require 'fibers'
local cjson = require 'cjson.safe'
local apn_model = require 'services.gsm.apn_model'

local perform = fibers.perform

local M = {}

M.FILENAME = 'user.cfg'

-- v0.9 connected a custom APN using only its apn, user, password and authtype, and its
-- UI took free text everywhere else. MVNO fields had no effect there, so they mustn't
-- cost a working record its place or change how it ranks now.
local IGNORED_BY_V09 = { mvno_type = true, mvno_match_data = true }

local function normalise_v09_record(rec)
	if type(rec) ~= 'table' then return nil end
	local out = {}
	for k, v in pairs(rec) do
		local t = type(v)
		if not IGNORED_BY_V09[k] and (t == 'string' or t == 'number' or t == 'boolean') then
			out[k] = v
		end
	end
	return apn_model.normalise_record(out)
end

---@param body any
---@return table? records
---@return integer|string skipped_or_err count of records dropped, or 'malformed'
function M.parse(body)
	if type(body) ~= 'string' then return nil, 'malformed' end
	local doc = cjson.decode(body)
	if type(doc) ~= 'table' then return nil, 'malformed' end
	local section = doc.default
	if section == nil then return {}, 0 end
	if type(section) ~= 'table' then return nil, 'malformed' end
	local list = section.apns
	if list == nil then return {}, 0 end
	if type(list) ~= 'table' then return nil, 'malformed' end

	-- normalise_list rejects a whole list for one bad record, so go one at a time.
	local records, seen, skipped = {}, {}, 0
	for _, rec in ipairs(list) do
		local item = normalise_v09_record(rec)
		local key = item and table.concat({ item.carrier, item.mcc, item.mnc, item.apn }, '\0')
		if item and not seen[key] then
			seen[key] = true
			records[#records + 1] = item
		else
			skipped = skipped + 1
		end
	end
	return records, skipped
end

local function is_missing_file(reason)
	return tostring(reason or ''):find('No such file', 1, true) ~= nil
end

-- Resolves to a result whose status is final for this boot, or to nil and an error that
-- is worth retrying:
--   exists      the store already has the key
--   imported    records were saved; imported and skipped hold the counts
--   no_source   no file, or no usable records in it; nothing written
--   malformed   the file can't be parsed; nothing written
---@param store table
---@param read_op fun(): Op resolves to a filesystem reply and an error
---@return Op
function M.run_op(store, read_op)
	return fibers.run_scope_op(function()
		local exists, xerr = perform(store:exists_op())
		if exists == nil then return nil, xerr or 'control_store_get_failed' end
		if exists then return { status = 'exists' }, nil end

		local reply, rerr = perform(read_op())
		if reply == nil then return nil, tostring(rerr or 'user_cfg_read_failed') end
		if reply.ok ~= true then
			if is_missing_file(reply.reason) then return { status = 'no_source', skipped = 0 }, nil end
			return nil, tostring(reply.reason or 'user_cfg_read_failed')
		end

		local records, skipped = M.parse(reply.reason)
		if not records then return { status = 'malformed' }, nil end
		if #records == 0 then return { status = 'no_source', skipped = skipped }, nil end

		local saved, serr = perform(store:save_op(records))
		if not saved then return nil, serr or 'control_store_put_failed' end
		return { status = 'imported', records = saved, imported = #saved, skipped = skipped }, nil
	end):wrap(function(st, rep, result, err)
		if st ~= 'ok' then return nil, tostring(result or err or rep) end
		return result, err
	end)
end

return M
