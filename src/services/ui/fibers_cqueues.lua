package.path="./?.lua;/usr/share/lua/?.lua;/usr/share/lua/?/init.lua;/usr/lib/lua/?.lua;/usr/lib/lua/?/init.lua"
	.. package.path
package.path = "../../?.lua;../?.lua;" .. package.path

local fiber = require "fibers.fiber"
local op = require "fibers.op"
local pollio = require "fibers.pollio"
local sleep = require "fibers.sleep"
local cqueues = require "cqueues"

local old_step; old_step = cqueues.interpose("step", function(self, timeout)
	if cqueues.running() then
		fiber.yield()
		return old_step(self, timeout)
	else
		local t = self:timeout() or math.huge
		if timeout then
			t = math.min(t, timeout)
		end

		local events = self:events()
		local fd = self:pollfd()

		local choices = {}

		if events ~= "w" then table.insert(choices, pollio.fd_readable_op(fd)) end
		if events ~= "r" then table.insert(choices, pollio.fd_writable_op(fd)) end
		if t ~= math.huge then table.insert(choices, sleep.sleep_op(t)) end

		op.choice(unpack(choices)):perform()
		return old_step(self, 0.0)
	end
end)
