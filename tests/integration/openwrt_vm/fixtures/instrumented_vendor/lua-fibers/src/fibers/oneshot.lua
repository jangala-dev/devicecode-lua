-- fibers/oneshot.lua

--- One-shot notification primitive.
---@module 'fibers.oneshot'

---@alias OneshotWaiter fun()

---@class Oneshot
---@field triggered boolean
---@field waiters table[]            # list of { fn = OneshotWaiter|nil }
---@field on_after_signal fun()|nil
local Oneshot = {}
Oneshot.__index = Oneshot

local function noop() end
--- Create a new one-shot.
---@param on_after_signal? fun() # optional callback run after signalling all waiters
---@return Oneshot
local function new(on_after_signal)
	return setmetatable({
		triggered       = false,
		waiters         = {},
		on_after_signal = on_after_signal,
	}, Oneshot)
end

--- Register a waiter.
--- If already triggered, the thunk is run immediately.
---@param thunk OneshotWaiter
---@return fun() cancel  # idempotent deregistration thunk
function Oneshot:add_waiter(thunk)
	if self.triggered then
		thunk()
		return noop
	end

	local ws = self.waiters
	local rec = { fn = thunk }
	ws[#ws + 1] = rec

	return function ()
		-- idempotent; clearing fn drops the closure reference
		rec.fn = nil
	end
end

--- Trigger the one-shot.
--- All waiters are run once; the optional callback runs afterwards.
--- Idempotent: subsequent calls after the first have no effect.
function Oneshot:signal()
	if self.triggered then return end
	self.triggered = true

	local ws = self.waiters
	for i = 1, #ws do
		local rec = ws[i]
		ws[i] = nil
		if rec then
			local f = rec.fn
			rec.fn = nil
			if f then f() end
		end
	end

	local cb = self.on_after_signal
	if cb then
		cb()
	end
end

--- Check whether the one-shot has fired.
---@return boolean
function Oneshot:is_triggered()
	return self.triggered
end

return {
	new = new,
}
