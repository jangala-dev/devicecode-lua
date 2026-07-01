-- services/gsm/apn_store_control_store.lua
--
-- Control-store-backed custom APN storage. GSM owns this adapter; UI routes call
-- GSM capabilities and never address the HAL control-store directly.

local fibers = require 'fibers'
local op     = require 'fibers.op'
local cjson  = require 'cjson.safe'

local cap_args = require 'services.hal.types.capability_args'
local apn_model = require 'services.gsm.apn_model'

local M = {}

local Store = {}
Store.__index = Store

local DEFAULT_ID = 'gsm'
local DEFAULT_KEY = 'custom-apns-v1'

local function rpc_topic(id, method)
	return { 'cap', 'control-store', id or DEFAULT_ID, 'rpc', method }
end

local function unwrap(method)
	return function(reply, err)
		if reply == nil then return nil, err end
		if type(reply) ~= 'table' or type(reply.ok) ~= 'boolean' then return nil, 'invalid_control_store_reply' end
		if reply.ok then return reply.reason, nil end
		return nil, tostring(reply.reason or err or ('control_store_' .. method .. '_failed'))
	end
end

local function call_op(self, method, payload)
	if type(self._conn) ~= 'table' or type(self._conn.call_op) ~= 'function' then
		return op.always(nil, 'control_store_connection_required')
	end
	return self._conn:call_op(rpc_topic(self._id, method), payload or {}, self._call_opts)
		:wrap(unwrap(method))
end

local function decode_records(body)
	if body == nil then return {}, nil end
	if type(body) ~= 'string' then return nil, 'custom_apns_body_not_string' end
	local payload, derr = cjson.decode(body)
	if type(payload) ~= 'table' then return nil, 'custom_apns_json_invalid:' .. tostring(derr) end
	local records = payload.records or payload.apns or payload
	return apn_model.normalise_list(records)
end

function Store:load_op()
	return fibers.run_scope_op(function ()
		local opts, oerr = cap_args.new.ControlStoreGetOpts(self._key)
		if not opts then return nil, oerr or 'invalid_control_store_get_opts' end
		local body, err = fibers.perform(call_op(self, 'get', opts))
		if body == nil then
			if tostring(err or '') == 'not found' then return {}, nil end
			return nil, err or 'control_store_get_failed'
		end
		return decode_records(body)
	end):wrap(function(st, rep, records, err)
		if st ~= 'ok' then return nil, tostring(records or err or rep) end
		return records, err
	end)
end

function Store:save_op(records)
	return fibers.run_scope_op(function ()
		local list, lerr = apn_model.normalise_list(records)
		if not list then return nil, lerr end
		local body, berr = cjson.encode({
			schema = 'devicecode.gsm.custom-apns/1',
			records = list,
		})
		if type(body) ~= 'string' then return nil, 'custom_apns_json_encode_failed:' .. tostring(berr) end
		local opts, oerr = cap_args.new.ControlStorePutOpts(self._key, body)
		if not opts then return nil, oerr or 'invalid_control_store_put_opts' end
		local ok, err = fibers.perform(call_op(self, 'put', opts))
		if ok == nil then return nil, err or 'control_store_put_failed' end
		return list, nil
	end):wrap(function(st, rep, records, err)
		if st ~= 'ok' then return nil, tostring(records or err or rep) end
		return records, err
	end)
end

function Store:describe()
	return {
		kind = 'control-store',
		id = self._id,
		key = self._key,
	}
end

function M.new(conn, opts)
	opts = opts or {}
	return setmetatable({
		_conn = conn,
		_id = opts.id or opts.store_id or DEFAULT_ID,
		_key = opts.key or DEFAULT_KEY,
		_call_opts = opts.call_opts,
	}, Store)
end

M.DEFAULT_ID = DEFAULT_ID
M.DEFAULT_KEY = DEFAULT_KEY
M.Store = Store
return M
