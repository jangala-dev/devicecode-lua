local op = require "fibers.op"
local pollio = require "fibers.pollio"
local cqueues = require "cqueues"
local fiber = require 'fibers.fiber'
print("installing poll handler")
pollio.install_poll_io_handler()

print("installing stream based IO library")
require 'fibers.stream.compat'.install()

print("overriding cqueues step")
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
        -- messy
        if events == 'r' then
            pollio.fd_readable_op(self:pollfd()):perform()
        elseif events == 'w' then
            pollio.fd_writable_op(self:pollfd()):perform()
        elseif events == 'rw' then
            op.choice(
                pollio.fd_readable_op(self:pollfd()),
                pollio.fd_writable_op(self:pollfd())
            ):perform()
        end
		return old_step(self, 0.0)
	end
end)
