-- services/ui/cqueues_bridge.lua
--
-- Cooperative bridge between cqueues waiting and the fibers runtime.
--
-- Purpose:
--   * let cqueues-driven HTTP/WebSocket internals coexist with fibers
--   * when outside a running cqueues task, wait via fibers on the cqueues
--     pollfd/timeout
--   * when already inside cqueues, just yield cooperatively to fibers first
--
-- This is an adapter boundary. It is expected to be a little ugly.

local cqueues    = require 'cqueues'
local fibers     = require 'fibers'
local sleep      = require 'fibers.sleep'
local wait       = require 'fibers.wait'
local runtime    = require 'fibers.runtime'
local poller_mod = require 'fibers.io.poller'

local unpack = rawget(table, 'unpack') or _G.unpack

local M = {}
local installed = false

local function pollfd_ready_op(fd, want)
	local P = poller_mod.get()
	local armed = false

	local function step()
		if armed then
			armed = false
			return true, true
		end
		return false
	end

	local function register(task)
		armed = true
		return P:wait(fd, want, task)
	end

	return wait.waitable(register, step, function(ok)
		return ok
	end)
end

function M.install()
	if installed then
		return true
	end

	local old_step
	old_step = cqueues.interpose('step', function(self, timeout)
		-- When cqueues is already running one of its own coroutines, keep the
		-- original behaviour but yield to fibers first so the schedulers can
		-- cooperate cleanly.
		if cqueues.running() then
			if runtime.current_fiber and runtime.current_fiber() and runtime.yield then
				runtime.yield()
			end
			return old_step(self, timeout)
		end

		-- Outside a cqueues coroutine, express the cqueues wait as fibers ops:
		--   * fd readability/writability via the fibers poller
		--   * timeout via sleep_op
		local t = self:timeout() or math.huge
		if timeout ~= nil then
			t = math.min(t, timeout)
		end

		local events = self:events()
		local fd = self:pollfd()
		local choices = {}

		if fd ~= nil and events ~= nil then
			if events ~= 'w' then
				choices[#choices + 1] = pollfd_ready_op(fd, 'rd')
			end
			if events ~= 'r' then
				choices[#choices + 1] = pollfd_ready_op(fd, 'wr')
			end
		end

		if t ~= math.huge then
			local deadline = fibers.now() + t
			choices[#choices + 1] = sleep.sleep_until_op(deadline)
		end

		if #choices == 0 then
			if runtime.current_fiber and runtime.current_fiber() and runtime.yield then
				runtime.yield()
			end
		elseif #choices == 1 then
			fibers.perform(choices[1])
		else
			fibers.perform(fibers.choice(unpack(choices)))
		end

		return old_step(self, 0.0)
	end)

	installed = true
	return true
end

return M
