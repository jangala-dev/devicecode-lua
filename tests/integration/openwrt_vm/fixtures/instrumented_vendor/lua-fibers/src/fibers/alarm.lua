-- fibers/alarm.lua
--
-- Wall-clock based alarms integrated with the fibers runtime.
--
-- Each alarm is driven by a recurrence function:
--   next_time(last_fired :: epoch|nil, now :: epoch) -> next_epoch|nil
--
-- Semantics:
--   * When next_time returns nil, the alarm becomes exhausted.
--   * When the alarm fires, callers receive:
--       true, alarm, last_fired_epoch, ...
--   * Once the alarm is exhausted, callers receive exactly once:
--       false, "no_more_recurrences", alarm, last_fired_epoch|nil
--     after which further wait_op() calls never fire.
--   * Multiple alarms scheduled for the same wall time will fire
--     in successive synchronisations (via CML choice and per-alarm state).
--
-- Time initialisation:
--   * alarm.new() and alarm:wait_op() are safe before real time is known.
--   * No wait_op() will complete until set_time_source(...) has been called.
--   * A wait_op() started before set_time_source will first wait for time
--     to become ready, then for the next recurrence.
--
-- Clock / civil time changes:
--   * alarm.time_changed() notifies all waiting alarms that the mapping
--     from monotonic time to civil time (UTC/zone) has changed.
--   * A wait_op() that is currently sleeping for the next recurrence
--     will be pre-empted, recompute its next firing time, and sleep again.
--   * This uses best-effort choice semantics: if a timer and a clock
--     change become ready together, either may win the choice.

local op        = require 'fibers.op'
local sleep_mod = require 'fibers.sleep'
local perform   = require 'fibers.performer'.perform
local cond_mod  = require 'fibers.cond'
local time      = require 'fibers.utils.time'

---@class Alarm
---@field _next_time fun(last: number|nil, now: number): number|nil
---@field _policy any
---@field _label string
---@field _last number|nil
---@field _next_wall number|nil
---@field _state "active"|"exhausted_pending"|"exhausted_done"
local Alarm = {}
Alarm.__index = Alarm

----------------------------------------------------------------------
-- Wall-clock source, readiness, and clock-change signalling
----------------------------------------------------------------------

-- Wall-clock "now" function (epoch seconds); replaced once real time is known.
local wall_now   = time.realtime
local time_ready = false

-- One-shot condition for “time is ready”.
local time_ready_cond = cond_mod.new()

-- Multi-shot condition for “clock / civil time has changed”.
-- This is recreated on every change so that each wait sees at most
-- one wake-up per change generation.
local clock_change_cond = cond_mod.new()

--- Install the wall-clock time source.
--- May be called once, when real time is known (RTC, NTP, GNSS, etc.).
---@param now_fn fun(): number
local function set_time_source(now_fn)
	assert(type(now_fn) == 'function', 'set_time_source expects a function')
	assert(not time_ready, 'set_time_source may only be called once')

	wall_now   = now_fn
	time_ready = true

	-- Wake any fibers that were waiting for time to become ready.
	time_ready_cond:signal()

	-- Treat "time became known" as a clock change for any alarms that
	-- might start waiting after this point.
	clock_change_cond:signal()
	clock_change_cond = cond_mod.new()
end

--- Notify alarms that the civil time mapping has changed.
--- Call this when:
---   * the system's wall clock is adjusted (e.g. after NTP sync), or
---   * the time zone used by recurrence functions has changed.
local function time_changed()
	if not time_ready then
		-- Before time_ready, no alarm has gone past the readiness gate,
		-- so there is nothing meaningful to reschedule.
		return
	end

	clock_change_cond:signal()
	clock_change_cond = cond_mod.new()
end

----------------------------------------------------------------------
-- Alarm object API
--
-- Internal state:
--   _state     : "active" | "exhausted_pending" | "exhausted_done"
--   _last      : last fired wall-clock epoch (or nil)
--   _next_wall : next scheduled wall-clock epoch (or nil)
----------------------------------------------------------------------

function Alarm:is_active()
	return self._state == 'active'
end

--- Cancel the alarm permanently.
--- No further firings or exhaustion notification will be delivered.
function Alarm:cancel()
	self._state     = 'exhausted_done'
	self._next_wall = nil
end

-- Internal: ensure _next_wall is populated or update state on exhaustion.
---@param now number
---@return number|nil
function Alarm:_ensure_next(now)
	if self._next_wall or self._state ~= 'active' then
		return self._next_wall
	end

	local t = self._next_time(self._last, now)
	if not t then
		-- No further recurrences: schedule exhaustion notification.
		self._state = 'exhausted_pending'
		return nil
	end

	self._next_wall = t
	return t
end

--- Main CML-style operation: wait for the alarm to fire once.
--
-- Returns an Op which, when performed, yields either:
--
--   * On successful firing:
--       true, alarm, last_fired_epoch, ...
--
--   * Once, when the recurrence sequence is exhausted:
--       false, "no_more_recurrences", alarm, last_fired_epoch|nil
--
-- After the exhaustion notification has been delivered, further
-- wait_op() calls return an Op that never fires.
--
-- Before set_time_source is called, a wait_op() will first block
-- until time becomes ready, and then behave exactly as if wait_op()
-- had been called afterwards.
--
-- If alarm.time_changed() is called while this wait_op() is sleeping
-- for its next firing time, the sleep will be pre-empted and the
-- next firing time will be recomputed from the updated civil time.
function Alarm:wait_op()
	return op.guard(function ()
		-- Fully inert: no more results of any kind.
		if self._state == 'exhausted_done' then
			return op.never()
		end

		-- Time not yet initialised: wait once for readiness, then recurse.
		if not time_ready then
			local ev = time_ready_cond:wait_op()
			return ev:wrap(function ()
				-- At this point, time_ready is true; perform a fresh wait.
				return perform(self:wait_op())
			end)
		end

		-- Normal path: real time is available.
		local now = wall_now()
		self:_ensure_next(now)

		-- If the recurrence has just been exhausted, deliver the
		-- one-off exhaustion notification and then become inert.
		if self._state == 'exhausted_pending' then
			self._state = 'exhausted_done'
			return op.always(false, 'no_more_recurrences', self, self._last)
		end

		-- We have a valid next_wall at this point.
		local next_wall = assert(self._next_wall, 'alarm internal error: missing next_wall')
		local dt        = next_wall - now
		if dt < 0 then dt = 0 end

		-- Build a race between:
		--   * sleeping until the scheduled time; and
		--   * a clock/civil-time change.
		--
		-- sleep_op(dt) yields no user-level values on success.
		local sleep_ev  = sleep_mod.sleep_op(dt)
		local change_ev = clock_change_cond:wait_op()

		local choice_ev = op.boolean_choice(sleep_ev, change_ev)

		return choice_ev:wrap(function (is_sleep)
			if is_sleep then
				-- Timer completed: commit this firing.
				self._last      = next_wall
				self._next_wall = nil
				return true, self, self._last
			else
				-- Clock or time zone changed before the timer fired:
				-- clear the stale schedule and recompute under new civil time.
				self._next_wall = nil
				return perform(self:wait_op())
			end
		end)
	end)
end

-- Convenience alias: treat the alarm itself as an Event factory.
Alarm.event = Alarm.wait_op

----------------------------------------------------------------------
-- Constructors
----------------------------------------------------------------------

---@class AlarmNewParams
---@field next_time fun(last: number|nil, now: number): number|nil
---@field policy any?
---@field label string?

--- Create a new alarm.
---
---@param params AlarmNewParams
---@return Alarm
local function new(params)
	assert(type(params) == 'table', 'alarm.new expects a parameter table')
	local next_time = params.next_time
	assert(type(next_time) == 'function', 'alarm.new: next_time function required')

	local self = setmetatable({
		_next_time = next_time,
		_policy    = params.policy,
		_label     = params.label or '',

		_last      = nil, -- last fired wall-clock epoch
		_next_wall = nil, -- next scheduled wall-clock epoch
		_state     = 'active', -- lifecycle state
	}, Alarm)

	return self
end

return {
	Alarm           = Alarm,
	new             = new,
	set_time_source = set_time_source,
	time_changed    = time_changed,
}
