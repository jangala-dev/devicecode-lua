-- tests/devicecode/support/test_queue.lua

local fibers   = require 'fibers'
local sleep    = require 'fibers.sleep'
local channel  = require 'fibers.channel'
local scope    = require 'fibers.scope'
local mailbox  = require 'fibers.mailbox'
local queue    = require 'devicecode.support.queue'

local tests = {}

local function fail(msg)
	error(msg or 'assertion failed', 2)
end

local function assert_true(v, msg)
	if v ~= true then
		fail(msg or ('expected true, got ' .. tostring(v)))
	end
end

local function assert_false(v, msg)
	if v ~= false then
		fail(msg or ('expected false, got ' .. tostring(v)))
	end
end

local function assert_nil(v, msg)
	if v ~= nil then
		fail(msg or ('expected nil, got ' .. tostring(v)))
	end
end

local function assert_not_nil(v, msg)
	if v == nil then
		fail(msg or 'expected non-nil value')
	end
end

local function assert_eq(a, b, msg)
	if a ~= b then
		fail(msg or ('expected ' .. tostring(b) .. ', got ' .. tostring(a)))
	end
end

local function assert_match(s, pat, msg)
	if type(s) ~= 'string' or not s:match(pat) then
		fail(msg or ('expected "' .. tostring(s) .. '" to match ' .. tostring(pat)))
	end
end

-------------------------------------------------------------------------------
-- try_send_now accepts immediate buffered admission
-------------------------------------------------------------------------------

function tests.test_try_send_now_accepts_buffered_admission()
	fibers.run(function ()
		local tx, rx = mailbox.new(1, { full = 'reject_newest' })

		local ok, err = queue.try_send_now(tx, 'hello')

		assert_true(ok)
		assert_nil(err)

		local item = fibers.perform(rx:recv_op())
		assert_eq(item, 'hello')
	end)
end

-------------------------------------------------------------------------------
-- try_send_now does not wait when rendezvous send would block
-------------------------------------------------------------------------------

function tests.test_try_send_now_returns_would_block_for_rendezvous_without_receiver()
	fibers.run(function ()
		local tx = mailbox.new(0, { full = 'block' })

		local ok, err = queue.try_send_now(tx, 'hello')

		assert_nil(ok)
		assert_eq(err, 'would_block')
	end)
end

-------------------------------------------------------------------------------
-- try_send_now preserves bounded rejection semantics
-------------------------------------------------------------------------------

function tests.test_try_send_now_preserves_reject_newest_full_result()
	fibers.run(function ()
		local tx = mailbox.new(1, { full = 'reject_newest' })

		local ok, err = queue.try_send_now(tx, 'one')
		assert_true(ok)
		assert_nil(err)

		ok, err = queue.try_send_now(tx, 'two')
		assert_false(ok)
		assert_eq(err, 'full')
	end)
end

-------------------------------------------------------------------------------
-- try_send_now reports closed send side
-------------------------------------------------------------------------------

function tests.test_try_send_now_reports_closed_mailbox()
	fibers.run(function ()
		local tx = mailbox.new(1, { full = 'reject_newest' })

		tx:close('closed_for_test')

		local ok, err = queue.try_send_now(tx, 'hello')

		assert_nil(ok)
		assert_eq(err, 'closed')
	end)
end

-------------------------------------------------------------------------------
-- try_recv_now receives immediately available values
-------------------------------------------------------------------------------

function tests.test_try_recv_now_receives_available_value()
	fibers.run(function ()
		local tx, rx = mailbox.new(1, { full = 'reject_newest' })

		local ok, err = queue.try_send_now(tx, 'hello')
		assert_true(ok)
		assert_nil(err)

		local item, rerr = queue.try_recv_now(rx)

		assert_eq(item, 'hello')
		assert_nil(rerr)
	end)
end

-------------------------------------------------------------------------------
-- try_recv_now does not wait when no value is available
-------------------------------------------------------------------------------

function tests.test_try_recv_now_returns_not_ready_when_empty_and_open()
	fibers.run(function ()
		local _, rx = mailbox.new(1, { full = 'reject_newest' })

		local item, err = queue.try_recv_now(rx)

		assert_nil(item)
		assert_eq(err, 'not_ready')
	end)
end


-------------------------------------------------------------------------------
-- try_recv_now reports closed receive side distinctly from not-ready
-------------------------------------------------------------------------------

function tests.test_try_recv_now_reports_closed_mailbox()
	fibers.run(function ()
		local tx, rx = mailbox.new(1, { full = 'reject_newest' })
		tx:close('closed_for_test')
		local expected = tostring(rx:why() or 'closed')

		local item, err = queue.try_recv_now(rx)

		assert_nil(item)
		assert_eq(err, expected)
		if err == 'not_ready' then fail('closed mailbox reported not_ready') end
	end)
end

-------------------------------------------------------------------------------
-- assert_admit_required raises on non-immediate admission failure
-------------------------------------------------------------------------------

function tests.test_assert_admit_required_raises_on_would_block()
	fibers.run(function ()
		local tx = mailbox.new(0, { full = 'block' })

		local ok, err = pcall(function ()
			queue.assert_admit_required(tx, 'hello', 'completion_report')
		end)

		assert_false(ok)
		assert_match(err, 'completion_report')
		assert_match(err, 'would_block')
	end)
end

-------------------------------------------------------------------------------
-- helpers still use scope-aware perform
-------------------------------------------------------------------------------

function tests.test_try_send_now_still_observes_scope_cancellation()
	fibers.run(function (root_scope)
		local child = assert(root_scope:child())

		local ok_spawn, spawn_err = child:spawn(function (s)
			s:cancel('cancelled_for_test')

			local ok, err = pcall(function ()
				local tx = mailbox.new(1, { full = 'reject_newest' })
				return queue.try_send_now(tx, 'hello')
			end)

			assert_false(ok)
			assert_true(scope.is_cancelled(err), 'expected scope cancellation sentinel')
			assert_eq(scope.cancel_reason(err), 'cancelled_for_test')
		end)

		assert_true(ok_spawn, spawn_err)

		local st, rep, primary = fibers.perform(child:join_op())

		assert_eq(st, 'cancelled')
		assert_eq(primary, 'cancelled_for_test')
		assert_eq(#rep.extra_errors, 0)
	end)
end

-------------------------------------------------------------------------------
-- losing choice arms unlink blocked mailbox waiters
-------------------------------------------------------------------------------

function tests.test_mailbox_choice_unlinks_losing_recv_waiter()
	fibers.run(function ()
		local hot_tx, hot_rx = mailbox.new(0, { full = 'block' })
		local _, quiet_rx = mailbox.new(0, { full = 'block' })

		for i = 1, 25 do
			fibers.spawn(function ()
				sleep.sleep(0.001)
				hot_tx:send('tick-' .. tostring(i))
			end)

			local which, item = fibers.perform(fibers.named_choice {
				hot = hot_rx:recv_op(),
				quiet = quiet_rx:recv_op(),
			})

			assert_eq(which, 'hot')
			assert_eq(item, 'tick-' .. tostring(i))
			assert_eq(quiet_rx._st.getq:length(), 0, 'quiet recv waiter leaked')
		end
	end)
end

function tests.test_mailbox_choice_unlinks_losing_send_waiter()
	fibers.run(function ()
		local hot_tx, hot_rx = mailbox.new(0, { full = 'block' })
		local quiet_tx = mailbox.new(0, { full = 'block' })

		for i = 1, 25 do
			fibers.spawn(function ()
				sleep.sleep(0.001)
				hot_tx:send('tick-' .. tostring(i))
			end)

			local which, item = fibers.perform(fibers.named_choice {
				hot = hot_rx:recv_op(),
				quiet = quiet_tx:send_op({ i = i }),
			})

			assert_eq(which, 'hot')
			assert_eq(item, 'tick-' .. tostring(i))
			assert_eq(quiet_tx._st.putq:length(), 0, 'quiet send waiter leaked')
		end
	end)
end

-------------------------------------------------------------------------------
-- losing choice arms unlink blocked channel waiters
-------------------------------------------------------------------------------

function tests.test_channel_choice_unlinks_losing_get_waiter()
	fibers.run(function ()
		local hot = channel.new()
		local quiet = channel.new()

		for i = 1, 25 do
			fibers.spawn(function ()
				sleep.sleep(0.001)
				hot:put('tick-' .. tostring(i))
			end)

			local which, item = fibers.perform(fibers.named_choice {
				hot = hot:get_op(),
				quiet = quiet:get_op(),
			})

			assert_eq(which, 'hot')
			assert_eq(item, 'tick-' .. tostring(i))
			assert_eq(quiet.getq:length(), 0, 'quiet get waiter leaked')
		end
	end)
end

function tests.test_channel_choice_unlinks_losing_put_waiter()
	fibers.run(function ()
		local hot = channel.new()
		local quiet = channel.new()

		for i = 1, 25 do
			fibers.spawn(function ()
				sleep.sleep(0.001)
				hot:put('tick-' .. tostring(i))
			end)

			local which, item = fibers.perform(fibers.named_choice {
				hot = hot:get_op(),
				quiet = quiet:put_op({ i = i }),
			})

			assert_eq(which, 'hot')
			assert_eq(item, 'tick-' .. tostring(i))
			assert_eq(quiet.putq:length(), 0, 'quiet put waiter leaked')
		end
	end)
end

return tests
