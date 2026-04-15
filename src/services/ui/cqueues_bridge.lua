-- services/ui/cqueues_bridge.lua
--
-- Bridge cqueues stepping into the current fibers runtime.
--
-- Install once, before starting the lua-http server loop.
--
-- This version is adapted to the current fibers API:
--   * fibers.perform(...)
--   * runtime.current_fiber()
--   * runtime.yield()
--   * poller-based fd readiness ops
--
-- Assumptions:
--   * fibers.io.poller exists and P:wait(fd, want, task) returns a WaitToken
--   * cqueues.interpose("step", fn) behaves as in older examples

local cqueues = require 'cqueues'
local fibers  = require 'fibers'
local op      = require 'fibers.op'
local sleep   = require 'fibers.sleep'
local runtime = require 'fibers.runtime'
local poller_mod = require 'fibers.io.poller'

local unpack = rawget(table, 'unpack') or _G.unpack

local M = {}

local installed = false

---@param fd integer
---@param want '"rd"'|'"wr"'
---@return Op
local function fd_ready_op(fd, want)
	local P = poller_mod.get()

	return op.new_primitive(
		nil,
		function()
			-- Pure polling is delegated to the poller task wakeup path.
			-- This op is never immediately ready.
			return false
		end,
		function(suspension, wrap_fn)
			local task = {
				run = function()
					if suspension:waiting() then
						suspension:complete(wrap_fn)
					end
				end,
			}

			local tok = P:wait(fd, want, task)
			if tok and tok.unlink then
				suspension:add_cleanup(function()
					tok:unlink()
				end)
			end
		end
	)
end

function M.install()
	if installed then
		return true
	end

	local old_step
	old_step = cqueues.interpose('step', function(self, timeout)
		-- If cqueues is already running inside a fiber-managed call chain,
		-- give fibers a chance to run other work before stepping cqueues again.
		if cqueues.running() then
			if runtime.current_fiber() then
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
			--   events == "r" means it only wants read readiness
			--   events == "w" means it only wants write readiness
			-- otherwise it may want both
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
			-- No fd and no timeout: avoid a hard spin.
			if runtime.current_fiber() then
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
