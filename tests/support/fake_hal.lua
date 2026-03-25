local fibers = require 'fibers'

local M = {}

local function topic(method)
	return { 'rpc', 'hal', method }
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

	local caps = {}
	if type(opts.caps) == 'table' then
		for k, v in pairs(opts.caps) do
			caps[k] = v
		end
	end
	if type(opts.scripted) == 'table' then
		for method in pairs(opts.scripted) do
			if caps[method] == nil then
				caps[method] = true
			end
		end
	end

	return setmetatable({
		calls    = {},
		scripted = opts.scripted or {},
		backend  = opts.backend or 'fakehal',
		caps     = caps,
	}, FakeHal)
end

function FakeHal:calls_for(method)
	local out = {}
	for i = 1, #self.calls do
		local c = self.calls[i]
		if c.method == method then
			out[#out + 1] = c
		end
	end
	return out
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

function FakeHal:start(conn, opts)
	opts = opts or {}
	local name = opts.name or 'hal'

	conn:retain({ 'svc', name, 'announce' }, {
		role     = 'hal',
		rpc_root = { 'rpc', 'hal' },
		backend  = self.backend,
		caps     = self.caps,
	})

	local methods = {}
	for method in pairs(self.scripted) do
		methods[#methods + 1] = method
	end

	for i = 1, #methods do
		local method = methods[i]
		local ep = conn:bind(topic(method), { queue_len = 16 })

		fibers.spawn(function()
			while true do
				local msg, err = ep:recv()
				if not msg then
					return
				end

				local req = msg.payload or {}
				self.calls[#self.calls + 1] = {
					method = method,
					req    = req,
					msg    = msg,
				}

				local reply = self:_next_reply(method, req, msg)
				if msg.reply_to ~= nil then
					conn:publish_one(msg.reply_to, reply, { id = msg.id })
				end
			end
		end)
	end
end

function M.new(opts)
	return FakeHal:new(opts)
end

return M
