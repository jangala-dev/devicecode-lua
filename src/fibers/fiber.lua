-- (c) Snabb project
-- (c) Jangala

-- Use of this source code is governed by the XXXXXXXXX license; see COPYING.

--- Fiber module.
-- Implements a fiber system using Lua's coroutines for cooperative multitasking.
-- @module fibers.fiber

-- Required packages
local sched = require 'fibers.sched'

local current_fiber
local current_scheduler = sched.new()

--- The Fiber class
-- Represents a single fiber, or lightweight thread.
-- @type Fiber
local Fiber = {}
Fiber.__index = Fiber

--- Spawns a new fiber.
-- @function spawn
-- @tparam function fn The function to run in the new fiber.
local function spawn(fn)
    -- Capture the traceback
    local tb = debug.traceback("", 2):match("\n[^\n]*\n(.*)") or ""
    -- If we're inside another fiber, append the traceback to the parent's traceback
    if current_fiber and current_fiber.traceback then
        tb = tb .. "\n" .. current_fiber.traceback
    end

    current_scheduler:schedule(
        setmetatable({
            coroutine = coroutine.create(fn),
            alive = true,
            sockets = {},
            traceback = tb
        }, Fiber))
end

--- Resumes execution of the fiber.
-- If the fiber is already dead, this will throw an error.
-- @tparam vararg ... The arguments to pass to the fiber.
function Fiber:resume(...)
    assert(self.alive, "dead fiber")                     -- checks that the fiber is alive
    local saved_current_fiber = current_fiber            -- shift the old current fiber into a safe place
    current_fiber = self                                 -- we are the new current fiber
    local ok, err = coroutine.resume(self.coroutine, ...) -- rev up our coroutine
    -- current_fiber = saved_current_fiber the KEY bit, we only get here when the coroutine above has yielded,
    -- but we then pop back in the fiber we previously displaced
    current_fiber = saved_current_fiber
    if not ok then
        print('Error while running fiber: ' .. tostring(err))
        print(debug.traceback(self.coroutine))
        print('fibers history:\n' .. self.traceback)
        os.exit(255)
    end
end

Fiber.run = Fiber.resume

--- Suspends execution of the fiber.
-- The fiber will be resumed when the provided blocking function finishes.
-- @tparam function block_fn The function to block on.
-- @tparam vararg ... The arguments to pass to the blocking function.
function Fiber:suspend(block_fn, ...)
    assert(current_fiber == self)
    -- The block_fn should arrange to reschedule the fiber when it
    -- becomes runnable.
    block_fn(current_scheduler, current_fiber, ...)
    return coroutine.yield()
end

--- Returns the socket associated with the provided descriptor.
-- @tparam number sd The socket descriptor.
-- @treturn table The socket.
function Fiber:get_socket(sd)
    return assert(self.sockets[sd])
end

--- Adds a new socket to the fiber.
-- @tparam table sock The socket to add.
-- @treturn number The descriptor of the added socket.
function Fiber:add_socket(sock)
    local sd = #self.sockets
    -- FIXME: add refcount on socket
    self.sockets[sd] = sock
    return sd
end

--- Closes the socket associated with the provided descriptor.
-- @tparam number sd The socket descriptor.
function Fiber:close_socket(sd)
    self:get_socket(sd)
    self.sockets[sd] = nil
    -- FIXME: remove refcount on socket
end

--- Waits until the socket associated with the provided descriptor is readable.
-- @tparam number sd The socket descriptor.
function Fiber:wait_for_readable(sd)
    local s = self:get_socket(sd)
    current_scheduler:resume_when_readable(s, self)
    return coroutine.yield()
end

--- Waits until the socket associated with the provided descriptor is writable.
-- @tparam number sd The socket descriptor.
function Fiber:wait_for_writable(sd)
    local s = self:get_socket(sd)
    current_scheduler:schedule_when_writable(s, self)
    return coroutine.yield()
end

--- Returns the traceback of the fiber.
-- @function get_traceback
function Fiber:get_traceback()
    return self.traceback or "No traceback available"
end

--- Returns the current time according to the current scheduler.
-- @treturn number The current time.
local function now() return current_scheduler:now() end

--- Suspends execution of the current fiber.
-- The fiber will be resumed when the provided blocking function finishes.
-- @function suspend
-- @tparam function block_fn The function to block on.
-- @tparam vararg ... The arguments to pass to the blocking function.
local function suspend(block_fn, ...) return current_fiber:suspend(block_fn, ...) end

local function schedule(scheduler, fiber) scheduler:schedule(fiber) end

--- Suspends execution of the current fiber.
-- The fiber will be resumed when the scheduler is ready to run it again.
-- @function yield
local function yield() return suspend(schedule) end

--- Stops the current scheduler from running more tasks.
-- @function stop
local function stop() current_scheduler:stop() end

--- Runs the main event loop of the current scheduler.
-- The scheduler will continue to run tasks and wait for events until stopped.
-- @function main
local function main() return current_scheduler:main() end

return {
    current_scheduler = current_scheduler,
    spawn = spawn,
    now = now,
    suspend = suspend,
    yield = yield,
    stop = stop,
    main = main
}
