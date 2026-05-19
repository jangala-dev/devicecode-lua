-- services/update/job_store_control_store.lua
--
-- Control-store-backed durable Update job store.
--
-- This is the production adapter for services.update.job_store_cap. It speaks
-- only to the curated HAL control-store capability surface:
--   cap/control-store/<id>/rpc/{get,put,delete,list}
--
-- The store is intentionally flat because the HAL control-store provider
-- accepts flat safe keys. Job ids are encoded into safe key suffixes; the job id
-- inside the JSON payload remains authoritative when loading.

local fibers = require 'fibers'
local op     = require 'fibers.op'
local cjson  = require 'cjson.safe'

local cap_args = require 'services.hal.types.capability_args'
local model    = require 'services.update.model'

local M = {}

local Store = {}
Store.__index = Store

local function copy(v)
	return model.deep_copy(v)
end

local function rpc_topic(id, method)
	return { 'cap', 'control-store', id or 'update', 'rpc', method }
end

local VOID_SUCCESS = {
	put = true,
	delete = true,
}

local function unwrap_reply_for(method)
	return function (reply, err)
		if reply == nil then
			return nil, err
		end
		if type(reply) == 'table' and type(reply.ok) == 'boolean' then
			if reply.ok then
				if reply.reason == nil and VOID_SUCCESS[method] then
					return true, nil
				end
				return reply.reason, nil
			end
			return nil, tostring(reply.reason or err or 'control_store_call_failed')
		end
		if reply == false then
			return nil, err or 'control_store_call_failed'
		end
		return reply, err
	end
end

local function call_op(self, method, payload, opts)
	if type(self._conn) ~= 'table' or type(self._conn.call_op) ~= 'function' then
		return op.always(nil, 'control_store_connection_required')
	end
	return self._conn:call_op(
		rpc_topic(self._id, method),
		payload or {},
		opts or self._call_opts
	):wrap(function (reply, err)
		return unwrap_reply_for(method)(reply, err)
	end)
end

local function safe_key_suffix(id)
	id = tostring(id or '')
	if id == '' then return nil, 'invalid_job_id' end
	return (id:gsub('[^%w%._%-]', function (ch)
		return ('_%02X'):format(ch:byte())
	end)), nil
end

local function key_for(self, job_id)
	local suffix, err = safe_key_suffix(job_id)
	if not suffix then return nil, err end
	return self._prefix .. suffix, nil
end

local function sorted_ids(jobs)
	local ids = {}
	for id in pairs(jobs or {}) do ids[#ids + 1] = id end
	table.sort(ids)
	return ids
end

local function decode_job(key, body)
	if type(body) ~= 'string' then
		return nil, 'control_store_job_body_not_string:' .. tostring(key)
	end
	local job, err = cjson.decode(body)
	if type(job) ~= 'table' then
		return nil, 'control_store_job_json_invalid:' .. tostring(err or key)
	end
	if type(job.job_id) ~= 'string' or job.job_id == '' then
		return nil, 'control_store_job_missing_id:' .. tostring(key)
	end
	return job, nil
end

function Store:load_all_op()
	return fibers.run_scope_op(function ()
		local list_opts, lerr = cap_args.new.ControlStoreListOpts(self._prefix)
		if not list_opts then return nil, lerr or 'invalid_control_store_list_opts' end

		local keys, err = fibers.perform(call_op(self, 'list', list_opts))
		if keys == nil then return nil, err or 'control_store_list_failed' end
		if type(keys) ~= 'table' then return nil, 'control_store_list_returned_non_table' end

		local jobs = {}
		for _, key in ipairs(keys) do
			if type(key) == 'string' and key:sub(1, #self._prefix) == self._prefix then
				local get_opts, gerr = cap_args.new.ControlStoreGetOpts(key)
				if not get_opts then return nil, gerr or 'invalid_control_store_get_opts' end
				local body, berr = fibers.perform(call_op(self, 'get', get_opts))
				if body == nil then return nil, berr or ('control_store_get_failed:' .. key) end
				local job, derr = decode_job(key, body)
				if not job then return nil, derr end
				jobs[job.job_id] = copy(job)
			end
		end

		return { jobs = jobs, order = sorted_ids(jobs) }, nil
	end):wrap(function (st, rep, snapshot, err)
		if st ~= 'ok' then return nil, tostring(err or rep) end
		return snapshot, err
	end)
end

function Store:save_job_op(job)
	return op.guard(function ()
		if type(job) ~= 'table' or type(job.job_id) ~= 'string' or job.job_id == '' then
			return op.always(nil, 'invalid_job')
		end
		local key, kerr = key_for(self, job.job_id)
		if not key then return op.always(nil, kerr or 'invalid_job_id') end

		local body, jerr = cjson.encode(copy(job))
		if type(body) ~= 'string' then
			return op.always(nil, 'control_store_job_json_encode_failed:' .. tostring(jerr))
		end

		local put_opts, perr = cap_args.new.ControlStorePutOpts(key, body)
		if not put_opts then return op.always(nil, perr or 'invalid_control_store_put_opts') end
		return call_op(self, 'put', put_opts):wrap(function (ok, err)
			if ok == nil then return nil, err or 'control_store_put_failed' end
			return true, nil
		end)
	end)
end

function Store:delete_job_op(job_id)
	return op.guard(function ()
		local key, kerr = key_for(self, job_id)
		if not key then return op.always(nil, kerr or 'invalid_job_id') end
		local delete_opts, derr = cap_args.new.ControlStoreDeleteOpts(key)
		if not delete_opts then return op.always(nil, derr or 'invalid_control_store_delete_opts') end
		return call_op(self, 'delete', delete_opts):wrap(function (ok, err)
			if ok == nil and tostring(err) ~= 'not found' then
				return nil, err or 'control_store_delete_failed'
			end
			return true, nil
		end)
	end)
end

function M.new(conn, opts)
	opts = opts or {}
	return setmetatable({
		_conn = conn,
		_id = opts.id or opts.store_id or 'update',
		_prefix = opts.prefix or 'update-job-',
		_call_opts = opts.call_opts,
	}, Store)
end

M.Store = Store
return M
