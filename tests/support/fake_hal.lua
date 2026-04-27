-- tests/support/fake_hal.lua

local fibers = require 'fibers'

local M = {}

local function svc_meta_topic(name)
	return { 'svc', name, 'meta' }
end

local function svc_announce_topic(name)
	return { 'svc', name, 'announce' }
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
	if type(filename) ~= 'string' then return nil end
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
	if type(reply) ~= 'table' then return reply end
	if method == 'read_state' then
		local found = rawget(reply, 'found')
		local data = rawget(reply, 'data')
		local err_text = rawget(reply, 'err')
		if reply.ok == true and found == true then
			return { ok = true, reason = data }
		end
		if reply.ok == true and found == false then
			return { ok = false, reason = err_text or 'not found', code = reply.code }
		end
	end
	local err_text = rawget(reply, 'err')
	if reply.ok ~= nil and reply.reason == nil and err_text ~= nil then
		return { ok = reply.ok, reason = err_text, code = reply.code }
	end
	return reply
end

local function method_offerings(method)
	if method == 'read_state' then return 'fs', 'config', { read = true } end
	if method == 'write_state' then return 'fs', 'state', { write = true } end
	if method == 'verify_ed25519' then return 'signature_verify', 'main', { verify_ed25519 = true } end
	return nil, nil, nil
end

---@class FakeHal
---@field calls table[]
---@field scripted table<string, fun(req:any,request:any):table>|table[]
---@field backend string
---@field caps table
local FakeHal = {}
FakeHal.__index = FakeHal

function FakeHal:new(opts)
	opts = opts or {}
	return setmetatable({
		calls = {},
		scripted = opts.scripted or {},
		backend = opts.backend or 'fakehal',
		caps = opts.caps or {},
	}, FakeHal)
end

function FakeHal:_next_reply(method, req, request)
	local entry = self.scripted[method]
	if type(entry) == 'function' then return entry(req, request) end
	if type(entry) == 'table' and #entry > 0 then
		local v = table.remove(entry, 1)
		if type(v) == 'function' then return v(req, request) end
		return v
	end
	return { ok = false, err = 'no scripted reply for ' .. tostring(method) }
end

function FakeHal:_record_call(method, req, request)
	self.calls[#self.calls + 1] = {
		method = method,
		req = req,
		request = request,
	}
end

function FakeHal:_start_capability_rpc(conn, class, id, offering, legacy_method)
	conn:retain(cap_state_topic(class, id), 'added')
	conn:retain(cap_meta_topic(class, id), { offerings = { [offering] = true } })

	local ep = conn:bind(cap_rpc_topic(class, id, offering), { queue_len = 16 })

	fibers.spawn(function()
		while true do
			local req, err = ep:recv()
			if not req then return end

			local raw_req = req.payload or {}
			local method, mapped_req = map_cap_call(class, id, offering, raw_req)
			method = legacy_method or method

			self:_record_call(method, mapped_req, req)

			local reply = self:_next_reply(method, mapped_req, req)
			reply = map_cap_reply(method, reply)
			if type(reply) ~= 'table' then
				req:fail(reply)
			elseif reply.ok == true then
				req:reply(reply)
			else
				req:reply(reply)
			end
		end
	end)
end

function FakeHal:_start_capabilities(conn)
	local started = {}
	for method, enabled in pairs(self.caps) do
		if enabled then
			local class, id, offerings = method_offerings(method)
			if class and id and offerings then
				local key = class .. '\0' .. tostring(id)
				if not started[key] then started[key] = true end
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

	local payload = {
		role = 'hal',
		backend = self.backend,
		caps = self.caps,
	}

	-- Canonical metadata surface
	conn:retain(svc_meta_topic(name), payload)
	-- Legacy compatibility surface
	conn:retain(svc_announce_topic(name), payload)

	self:_start_capabilities(conn)
end

function M.new(opts)
	return FakeHal:new(opts)
end

return M
