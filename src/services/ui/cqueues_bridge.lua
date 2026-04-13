-- services/ui/cqueues_bridge.lua
--
-- Bridge cqueues stepping into the current fibers runtime.
--
-- Install once, before starting the lua-http server loop.
--
-- Assumptions:
--   * cqueues.interpose("step", fn) is available
--   * fibers.io.poller exists and P:wait(fd, want, task) returns a WaitToken
--   * runtime.current_fiber() / runtime.yield() are available

local cqueues    = require 'cqueues'
local fibers     = require 'fibers'
local op         = require 'fibers.op'
local sleep      = require 'fibers.sleep'
local wait       = require 'fibers.wait'
local runtime    = require 'fibers.runtime'
local poller_mod = require 'fibers.io.poller'

local unpack = rawget(table, 'unpack') or _G.unpack

local M = {}

local installed = false

---@param fd integer
---@param want '"rd"'|'"wr"'
---@return Op
local function fd_ready_op(fd, want)
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

	local function wrap(ok)
		return ok
	end

	return wait.waitable(register, step, wrap)
end

function M.install()
	if installed then
		return true
	end

	local old_step
	old_step = cqueues.interpose('step', function(self, timeout)
		-- If cqueues is already being stepped inside a fiber-managed path,
		-- let fibers yield before stepping cqueues again.
		if cqueues.running() then
			if runtime.current_fiber and runtime.current_fiber() and runtime.yield then
				runtime.yield()
			end
			return old_step(self, timeout)
		end

		local t = self:timeout() or math.huge
		if timeout ~= nil then
			t = math.min(t, timeout)
		end

		local events = self:events()
		local fd = self:pollfd()

		local choices = {}

		if fd ~= nil and events ~= nil then
			-- cqueues convention:
			--   events == "r" means read only
			--   events == "w" means write only
			-- otherwise treat as both
			if events ~= 'w' then
				choices[#choices + 1] = fd_ready_op(fd, 'rd')
			end
			if events ~= 'r' then
				choices[#choices + 1] = fd_ready_op(fd, 'wr')
			end
		end

		if t ~= math.huge then
			choices[#choices + 1] = sleep.sleep_op(t)
		end

		if #choices == 0 then
			-- Avoid a hard spin if cqueues has neither fd nor timeout ready.
			if runtime.current_fiber and runtime.current_fiber() and runtime.yield then
				runtime.yield()
			end
		elseif #choices == 1 then
			fibers.perform(choices[1])
		else
			fibers.perform(op.choice(unpack(choices)))
		end

		return old_step(self, 0.0)
	end)

	installed = true
	return true
end

return M
