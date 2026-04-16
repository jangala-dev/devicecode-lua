-- tests/support/fake_hal.lua

local fibers = require 'fibers'

local M = {}

local function topic(method)
	return { 'rpc', 'hal', method }
end

local function cap_state_topic(class, id)
	return { 'cap', class, id, 'state' }
end

local function cap_meta_topic(class, id)
	return { 'cap', class, id, 'meta' }
end

local function cap_rpc_topic(class, id, method)
	return { 'cap', class, id, 'rpc', method }
end

local function strip_json_suffix(filename)
	if type(filename) ~= 'string' then
		return nil
	end
	return (filename:gsub('%.json$', ''))
end

local function legacy_state_req_from_filename(filename, data)
	return {
		ns = 'config',
		key = strip_json_suffix(filename),
		data = data,
	}
end

local function map_cap_call(class, id, method, req)
	if class == 'fs' and id == 'config' and method == 'read' then
		return 'read_state', legacy_state_req_from_filename(req and req.filename)
	end

	if class == 'fs' and id == 'state' and method == 'write' then
		return 'write_state', legacy_state_req_from_filename(req and req.filename, req and req.data)
	end

	return method, req
end

local function map_cap_reply(method, reply)
	if type(reply) ~= 'table' then
		return reply
	end

	if method == 'read_state' then
		local found = rawget(reply, 'found')
		local data = rawget(reply, 'data')
		local err_text = rawget(reply, 'err')
		if reply.ok == true and found == true then
			return {
				ok = true,
				reason = data,
			}
		end

		if reply.ok == true and found == false then
			return {
				ok = false,
				reason = err_text or 'not found',
				code = reply.code,
			}
		end
	end

	local err_text = rawget(reply, 'err')
	if reply.ok ~= nil and reply.reason == nil and err_text ~= nil then
		return {
			ok = reply.ok,
			reason = err_text,
			code = reply.code,
		}
	end

	return reply
end

local function method_offerings(method)
	if method == 'read_state' then
		return 'fs', 'config', { read = true }
	end

	if method == 'write_state' then
		return 'fs', 'state', { write = true }
	end

	return nil, nil, nil
end

---@class FakeHal
---@field calls table[]
---@field scripted table<string, fun(req:any,msg:any):table>|table[]
---@field backend string
---@field caps table
local FakeHal = {}
FakeHal.__index = FakeHal

function FakeHal:new(opts)
	opts = opts or {}
	return setmetatable({
		calls    = {},
		scripted = opts.scripted or {},
		backend  = opts.backend or 'fakehal',
		caps     = opts.caps or {},
	}, FakeHal)
end

function FakeHal:_next_reply(method, req, msg)
	local entry = self.scripted[method]
	if type(entry) == 'function' then
		return entry(req, msg)
	end
	if type(entry) == 'table' and #entry > 0 then
		local v = table.remove(entry, 1)
		if type(v) == 'function' then
			return v(req, msg)
		end
		return v
	end
	return { ok = false, err = 'no scripted reply for ' .. tostring(method) }
end

function FakeHal:_record_call(method, req, msg)
	self.calls[#self.calls + 1] = {
		method = method,
		req    = req,
		msg    = msg,
	}
end

function FakeHal:_start_legacy_rpc(conn)
	local methods = {}
	for method in pairs(self.scripted) do
		methods[#methods + 1] = method
	end

	for i = 1, #methods do
		local method = methods[i]
		local ep = conn:bind(topic(method), { queue_len = 16 })

		fibers.spawn(function()
			while true do
				local req, err = ep:recv()
				if not req then
					return
				end

				local payload = req.payload or {}
				self:_record_call(method, payload, req)

				local reply = self:_next_reply(method, payload, req)
				req:reply(reply)
			end
		end)
	end
end

function FakeHal:_start_capability_rpc(conn, class, id, offering, legacy_method)
	conn:retain(cap_state_topic(class, id), 'added')
	conn:retain(cap_meta_topic(class, id), { offerings = { [offering] = true } })

	local ep = conn:bind(cap_rpc_topic(class, id, offering), { queue_len = 16 })

	fibers.spawn(function()
		while true do
			local msg, err = ep:recv()
			if not msg then
				return
			end

			local raw_req = msg.payload or {}
			local method, req = map_cap_call(class, id, offering, raw_req)
			method = legacy_method or method

			self:_record_call(method, req, msg)

			local reply = self:_next_reply(method, req, msg)
			reply = map_cap_reply(method, reply)

			msg:reply(reply)
		end
	end)
end

function FakeHal:_start_capabilities(conn)
	local started = {}

	for method, enabled in pairs(self.caps) do
		if enabled then
			local class, id, offerings = method_offerings(method)
			if class ~= nil and id ~= nil and offerings ~= nil then
				local key = class .. '\0' .. tostring(id)
				if not started[key] then
					started[key] = true
				end

				for offering in pairs(offerings) do
					self:_start_capability_rpc(conn, class, id, offering, method)
				end
			end
		end
	end
end

function FakeHal:start(conn, opts)
	opts = opts or {}
	local name = opts.name or 'hal'

	conn:retain({ 'svc', name, 'announce' }, {
		role     = 'hal',
		rpc_root = { 'rpc', 'hal' },
		backend  = self.backend,
		caps     = self.caps,
	})

	self:_start_legacy_rpc(conn)
	self:_start_capabilities(conn)
end

function M.new(opts)
	return FakeHal:new(opts)
end

return M
