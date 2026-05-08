-- tests/unit/support/test_priority_event.lua

local fibers        = require 'fibers'
local mailbox       = require 'fibers.mailbox'
local op            = require 'fibers.op'
local queue         = require 'services.support.queue'
local priority_event = require 'services.support.priority_event'

local tests = {}

local function fail(msg)
	error(msg or 'assertion failed', 2)
end

local function assert_eq(a, b, msg)
	if a ~= b then
		fail(msg or ('expected ' .. tostring(b) .. ', got ' .. tostring(a)))
	end
end

local function assert_true(v, msg)
	if v ~= true then
		fail(msg or ('expected true, got ' .. tostring(v)))
	end
end

local function assert_nil(v, msg)
	if v ~= nil then
		fail(msg or ('expected nil, got ' .. tostring(v)))
	end
end

local function recv_event(rx, kind)
	return function ()
		local item, err = queue.try_recv_now(rx)
		if item ~= nil then
			return { kind = kind, value = item }
		end
		if err ~= 'not_ready' then
			return { kind = kind .. '_closed' }
		end
		return nil
	end
end

local function recv_op(rx, kind)
	return function ()
		return rx:recv_op():wrap(function (item)
			if item == nil then
				return { kind = kind .. '_closed' }
			end
			return { kind = kind, value = item }
		end)
	end
end

function tests.test_sources_op_selects_ready_sources_by_explicit_order()
	fibers.run(function ()
		local low_tx, low_rx = mailbox.new(4, { full = 'reject_newest' })
		local high_tx, high_rx = mailbox.new(4, { full = 'reject_newest' })
		assert_true(low_tx:send('low-one'))
		assert_true(high_tx:send('high-one'))

		local pending = {}
		local function next_event_op()
			return priority_event.sources_op {
				label = 'test.priority.ready_order',
				pending = pending,
				sources = {
					{ name = 'high', try_now = recv_event(high_rx, 'high'), recv_op = recv_op(high_rx, 'high') },
					{ name = 'low',  try_now = recv_event(low_rx,  'low'),  recv_op = recv_op(low_rx,  'low')  },
				},
			}
		end

		local ev = fibers.perform(next_event_op())
		assert_eq(ev.kind, 'high')
		assert_eq(ev.value, 'high-one')

		ev = fibers.perform(next_event_op())
		assert_eq(ev.kind, 'low')
		assert_eq(ev.value, 'low-one')
	end)
end

function tests.test_next_op_treats_blocking_winner_as_wake_and_rechecks_priority()
	fibers.run(function ()
		local pending = {}
		local high_tx, high_rx = mailbox.new(1, { full = 'reject_newest' })

		local selected = fibers.perform(priority_event.next_op {
			label = 'test.priority.recheck_after_wake',
			select_now = function ()
				local high, err = queue.try_recv_now(high_rx)
				if high ~= nil then
					return { kind = 'high', value = high }
				end
				assert_eq(err, 'not_ready')

				local low = priority_event.take_pending(pending, 'low')
				if low ~= nil then
					return low
				end
				return nil
			end,
			wait_op = function ()
				return op.always('low', { kind = 'low', value = 'blocked-low' })
			end,
			store_wake = function (name, ev)
				pending[name] = ev
				assert_true(high_tx:send('became-ready-high'))
			end,
		})

		assert_eq(selected.kind, 'high')
		assert_eq(selected.value, 'became-ready-high')

		local low = priority_event.take_pending(pending, 'low')
		assert_eq(low.kind, 'low')
		assert_eq(low.value, 'blocked-low')
	end)
end

function tests.test_next_op_allows_no_event_when_explicitly_requested()
	fibers.run(function ()
		local ev = fibers.perform(priority_event.next_op {
			label = 'test.priority.no_event',
			allow_no_event = true,
			select_now = function () return nil end,
			wait_op = function () return op.always('woke') end,
		})

		assert_nil(ev)
	end)
end

return tests
