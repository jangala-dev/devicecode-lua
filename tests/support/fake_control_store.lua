-- tests/support/fake_control_store.lua
--
-- Tiny in-memory stand-in for HAL's curated control-store capability.  It binds
-- cap/control-store/<id>/rpc/{get,put,delete,list} on the bus and records calls
-- so devhost tests can prove UI -> GSM -> control-store paths are used without
-- requiring a real HAL backend or filesystem.

local fibers = require 'fibers'

local M = {}
local Store = {}
Store.__index = Store

local METHODS = { 'get', 'put', 'delete', 'list' }

local function t(...) return { ... } end

local function cap_status_topic(id)
	return t('cap', 'control-store', id, 'status')
end

local function cap_meta_topic(id)
	return t('cap', 'control-store', id, 'meta')
end

local function cap_state_topic(id)
	return t('cap', 'control-store', id, 'state')
end

local function cap_rpc_topic(id, method)
	return t('cap', 'control-store', id, 'rpc', method)
end

local function copy(v)
	if type(v) ~= 'table' then return v end
	local out = {}
	for k, sv in pairs(v) do out[k] = copy(sv) end
	return out
end

local function sorted_keys(values, prefix)
	local out = {}
	prefix = prefix or ''
	for key in pairs(values or {}) do
		if prefix == '' or tostring(key):sub(1, #prefix) == prefix then
			out[#out + 1] = key
		end
	end
	table.sort(out)
	return out
end

function Store:new(opts)
	opts = opts or {}
	return setmetatable({
		id = opts.id or 'gsm',
		values = copy(opts.values or {}),
		calls = {},
		endpoints = {},
	}, Store)
end

function Store:_reply(method, payload)
	payload = payload or {}
	local key = payload.key
	self.calls[#self.calls + 1] = { method = method, payload = copy(payload) }

	if method == 'get' then
		if type(key) ~= 'string' or key == '' then return { ok = false, reason = 'invalid key' } end
		local body = self.values[key]
		if body == nil then return { ok = false, reason = 'not found' } end
		return { ok = true, reason = body }
	elseif method == 'put' then
		if type(key) ~= 'string' or key == '' then return { ok = false, reason = 'invalid key' } end
		if type(payload.data) ~= 'string' then return { ok = false, reason = 'data must be a string' } end
		self.values[key] = payload.data
		return { ok = true, reason = true }
	elseif method == 'delete' then
		if type(key) ~= 'string' or key == '' then return { ok = false, reason = 'invalid key' } end
		self.values[key] = nil
		return { ok = true, reason = true }
	elseif method == 'list' then
		return { ok = true, reason = sorted_keys(self.values, payload.prefix) }
	end
	return { ok = false, reason = 'unsupported method: ' .. tostring(method) }
end

function Store:start(conn, opts)
	opts = opts or {}
	local id = opts.id or self.id or 'gsm'
	local scope = opts.scope
	self.id = id

	conn:retain(cap_state_topic(id), 'added')
	conn:retain(cap_status_topic(id), {
		schema = 'devicecode.cap.status/1',
		state = 'available',
		available = true,
		methods = METHODS,
	})
	conn:retain(cap_meta_topic(id), {
		schema = 'devicecode.cap.meta/1',
		class = 'control-store',
		id = id,
		offerings = { get = true, put = true, delete = true, list = true },
		methods = METHODS,
		fake = true,
	})

	for _, method in ipairs(METHODS) do
		local method_name = method
		local ep = assert(conn:bind(cap_rpc_topic(id, method_name), { queue_len = 32 }))
		self.endpoints[method_name] = ep

		local function serve()
			while true do
				local req = fibers.perform(ep:recv_op())
				if req == nil then return end
				req:reply(self:_reply(method_name, req.payload or {}))
			end
		end

		if scope and type(scope.spawn) == 'function' then
			local ok, err = scope:spawn(serve)
			if ok ~= true then error(err or 'fake control-store spawn failed', 0) end
		else
			fibers.spawn(serve)
		end
	end
	return true
end

function Store:get(key)
	return self.values[key]
end

function Store:put(key, value)
	self.values[key] = value
	return true
end

function M.new(opts)
	return Store:new(opts)
end

M.Store = Store
return M
