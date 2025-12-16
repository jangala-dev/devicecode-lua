local fiber = require 'fibers.fiber'
local context = require 'fibers.context'

local harness = {}

-- Default maximum number of cooperative "ticks" to wait
-- before treating a wait as a timeout.
local DEFAULT_MAX_TICKS = 20

-- Environment helpers -------------------------------------------------------

function harness.get_env_variables()
	local bg_ctx = context.background()

	local ctx = context.with_cancel(
		context.with_value(bg_ctx, 'service_name', 'hal')
	)

	local bus = require 'bus'

	-- Force reload to reset state between tests
	package.loaded['services.hal'] = nil
	package.loaded['services.hal.managers.dummy'] = nil
	local hal = require 'services.hal'
	return hal, ctx, bus.new(), bus.new_msg
end

function harness.config_path()
	return { 'config', 'hal' }
end

function harness.new_hal_env()
	local hal, ctx, bus, new_msg = harness.get_env_variables()
	local conn = bus:connect()
	return hal, ctx, bus, conn, new_msg
end

function harness.publish_config(conn, new_msg, payload)
	conn:publish(new_msg(harness.config_path(), payload, { retained = true }))
end

-- Tick-based waiting helpers -----------------------------------------------

-- Internal helper to build an alt function for perform_alt that:
-- - increments a tick counter
-- - yields the current fiber
-- - enforces a max tick budget
-- - bails out if the context is cancelled
local function make_alt_wait(ctx, max_ticks)
	local ticks = 0
	max_ticks = max_ticks or DEFAULT_MAX_TICKS

	return function()
		if ctx and ctx:err() then
			return nil, 'context cancelled'
		end

		ticks = ticks + 1
		if ticks > max_ticks then
			return nil, 'timeout'
		end

		fiber.yield()
		-- Special error sentinel used by wait helpers to
		-- distinguish an alt-path from a real error.
		return nil, '__ALT__'
	end
end

-- Wait for a message on a subscriber using a non-blocking choice.
-- Returns (msg, err). If the alt path exhausts the tick budget,
-- returns (nil, 'timeout'). If the context is cancelled, returns
-- (nil, 'context cancelled').
function harness.wait_for_msg(sub, ctx, max_ticks)
	local alt = make_alt_wait(ctx, max_ticks)
	while true do
		local msg, err = sub:next_msg_op():perform_alt(alt)
		if err ~= '__ALT__' then
			return msg, err
		end
	end
end

-- Wait until a predicate becomes true, yielding cooperatively
-- between checks. Returns true on success, or false, reason on
-- timeout or context cancellation.
function harness.wait_until(ctx, predicate, max_ticks)
	local ticks = 0
	max_ticks = max_ticks or DEFAULT_MAX_TICKS

	while true do
		if predicate() then
			return true
		end

		if ctx and ctx:err() then
			return false, 'context cancelled'
		end

		ticks = ticks + 1
		if ticks > max_ticks then
			return false, 'timeout'
		end

		fiber.yield()
	end
end

return harness

