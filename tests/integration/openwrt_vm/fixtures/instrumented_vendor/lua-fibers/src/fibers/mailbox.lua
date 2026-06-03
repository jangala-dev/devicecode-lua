-- fibers/mailbox.lua
--
-- Mailbox: closeable, drainable queue for fibers.
--
-- Conventions
--   * nil payloads are forbidden; nil is reserved for end-of-stream.
--   * rx:recv() returns:
--       - a non-nil message, or
--       - nil when the mailbox is closed and drained.
--     rx:why() yields the close reason (if any).
--   * tx:send(v) returns:
--       - true                if the message was accepted (delivered or enqueued),
--       - false, "full"       if the message was not accepted due to capacity/policy,
--       - nil                 if the mailbox is closed (send rejected).
--     tx:why() yields the close reason (if any).
--   * Multi-producer:
--       - tx:clone() creates a new counted sender handle.
--       - each counted handle should be closed once finished.
--       - mailbox closes-for-send when the last counted handle closes.
--
-- Full policies (when no receiver is waiting and the mailbox is full):
--   * "block"         : sender blocks until space/receiver is available (default)
--   * "reject_newest" : reject the incoming value; send returns false, "full"
--   * "drop_oldest"   : drop the oldest buffered value (if any), enqueue the new one;
--                     send returns true (accepted), and dropped counter increments
--
-- For rendezvous mailboxes (capacity == 0), "drop_oldest" behaves like "reject_newest".

---@module 'fibers.mailbox'

local op      = require 'fibers.op'
local fifo    = require 'fibers.utils.fifo'
local dlist   = require 'fibers.utils.dlist'
local perform = require 'fibers.performer'.perform

local ok_probe, leak_probe = pcall(require, 'devicecode.support.leak_probe')
if not ok_probe then leak_probe = nil end

---@alias MailboxWant nil  -- reserved for future extensions

---@class MailboxState
---@field cap integer
---@field buf any|nil      -- FIFO buffer when cap>0; nil for rendezvous
---@field getq any         -- cancellable wait-list of waiting receivers
---@field putq any         -- cancellable wait-list of waiting senders
---@field taskq any        -- cancellable wait-list of task waiters for recv readiness
---@field closed boolean
---@field reason any|nil
---@field senders integer  -- counted sender handles still open
---@field full '"block"'|'"reject_newest"'|'"drop_oldest"'
---@field dropped integer  -- total number of dropped messages due to full policy

---@class MailboxTx
---@field _st MailboxState
---@field _closed boolean    -- this handle closed (idempotent)
---@field _counted boolean   -- whether this handle contributes to st.senders
local Tx = {}
Tx.__index = Tx

---@class MailboxRx
---@field _st MailboxState
local Rx = {}
Rx.__index = Rx

----------------------------------------------------------------------
-- Internal helpers
----------------------------------------------------------------------

--- Pop the next entry whose suspension is still waiting, if any.
---@param q any
---@return table|nil
local function pop_active(q)
	while not q:empty() do
		local e = q:pop_head()
		local s = e.suspension
		if not s or s:waiting() then
			return e
		end
	end
end

local function cleanup_recv_waiter(entry)
	entry.suspension = nil
	entry.wrap = nil
end

local function cleanup_send_waiter(entry)
	entry.val = nil
	entry.suspension = nil
	entry.wrap = nil
end

local function cleanup_task_waiter(entry)
	entry.task = nil
	entry.waker = nil
end

---@param st MailboxState
local function notify_task_waiters(st)
	local q = st.taskq
	if not q then return end

	while not q:empty() do
		local e = q:pop_head()
		if e and e.task and e.waker then
			local task, waker = e.task, e.waker
			waker:wakeup(task)
			cleanup_task_waiter(e)
		end
	end
end

---@param st MailboxState
---@return boolean
local function recv_may_succeed(st)
	if st.closed then return true end
	if st.buf and st.buf:length() > 0 then return true end
	if st.putq and not st.putq:empty() then return true end
	return false
end

---@param st MailboxState
---@param reason any|nil
local function record_reason(st, reason)
	if st.reason == nil and reason ~= nil then
		st.reason = reason
	end
end

--- Close the mailbox state (idempotent), record reason, and wake blocked parties.
--- Receivers drain buffered values (if any), then receive nil.
--- Waiting senders are rejected (nil).
---@param st MailboxState
---@param reason any|nil
local function close_state(st, reason)
	if st.closed then
		record_reason(st, reason)
		return
	end

	st.closed = true
	record_reason(st, reason)
	if leak_probe then leak_probe.mailbox_closed(st._probe_id, reason) end

	-- Wake receivers: deliver buffered values first, then nil when buffer empty.
	while true do
		local recv = pop_active(st.getq)
		if not recv then break end

		local v
		if st.buf and st.buf:length() > 0 then
			v = st.buf:pop()
		end
		recv.suspension:complete(recv.wrap, v)
		cleanup_recv_waiter(recv)
	end

	-- Reject senders (nil result means "closed").
	while true do
		local snd = pop_active(st.putq)
		if not snd then break end
		snd.suspension:complete(snd.wrap, nil)
		cleanup_send_waiter(snd)
	end

	notify_task_waiters(st)
end

----------------------------------------------------------------------
-- Construction
----------------------------------------------------------------------

---@param full any
---@return '"block"'|'"reject_newest"'|'"drop_oldest"'
local function norm_full_policy(full, capacity)
	if full == nil then full = 'block' end
	if full ~= 'block' and full ~= 'reject_newest' and full ~= 'drop_oldest' then
		error('mailbox.new: invalid full policy: ' .. tostring(full), 3)
	end
	-- Rendezvous mailboxes have no buffer; drop_oldest collapses to reject_newest.
	if capacity == 0 and full == 'drop_oldest' then
		full = 'reject_newest'
	end
	return full
end

--- Create a mailbox. Returns (tx, rx).
---@param capacity? integer  # 0 or nil -> rendezvous; >0 -> buffered capacity
---@param opts? { full?: '"block"'|'"reject_newest"'|'"drop_oldest"' }
---@return MailboxTx tx, MailboxRx rx
local function new(capacity, opts)
	capacity = capacity or 0
	opts = opts or {}
	local full = norm_full_policy(opts.full, capacity)

	---@type MailboxState
	local probe_id = leak_probe and leak_probe.mailbox_next_id() or nil
	local st = {
		_probe_id = probe_id,
		cap     = capacity,
		buf     = (capacity > 0) and fifo.new() or nil,
		getq    = dlist.new(),
		putq    = dlist.new(),
		taskq   = dlist.new(),
		closed  = false,
		reason  = nil,
		senders = 1,
		full    = full,
		dropped = 0,
	}

	local tx = setmetatable({ _st = st, _closed = false, _counted = true }, Tx)
	local rx = setmetatable({ _st = st }, Rx)
	if leak_probe then leak_probe.mailbox_created(probe_id, capacity, full) end
	return tx, rx
end

----------------------------------------------------------------------
-- Tx (sender)
----------------------------------------------------------------------

--- Return the mailbox close reason (if any).
---@return any|nil
function Tx:why()
	return self._st.reason
end

--- Return total number of dropped messages due to the full policy.
--- For reject_newest: counts incoming messages dropped (and send returns false,"full").
--- For drop_oldest: counts buffered messages evicted to admit new ones.
---@return integer
function Tx:dropped()
	return self._st.dropped or 0
end

--- Clone this sender handle (multi-producer).
--- If the mailbox or this handle is closed, returns an inert, uncounted handle.
---@return MailboxTx
function Tx:clone()
	local st = self._st
	if self._closed or st.closed then
		return setmetatable({ _st = st, _closed = true, _counted = false }, Tx)
	end
	st.senders = st.senders + 1
	if leak_probe then leak_probe.mailbox_sender_cloned(st._probe_id) end
	return setmetatable({ _st = st, _closed = false, _counted = true }, Tx)
end

--- Close this sender handle (idempotent).
--- When the last counted sender closes, the mailbox closes-for-send.
---@param reason any|nil
---@return boolean ok
function Tx:close(reason)
	local st = self._st
	record_reason(st, reason)

	if self._closed then return true end

	self._closed = true

	-- If already uncounted, or mailbox already closed, nothing to do.
	if not self._counted or st.closed then
		self._counted = false
		return true
	end

	self._counted = false
	st.senders = st.senders - 1
	if leak_probe then leak_probe.mailbox_sender_closed(st._probe_id) end
	if st.senders <= 0 then
		st.senders = 0
		close_state(st, reason)
	end

	return true
end

--- Op that sends a message.
--- When performed:
---   * true             : accepted (delivered or enqueued)
---   * false, "full"    : not accepted due to capacity/policy (reject_newest)
---   * nil              : mailbox closed (send rejected)
---@param v any  # MUST NOT be nil
---@return Op
function Tx:send_op(v)
	assert(v ~= nil, 'mailbox.send: nil payload is not permitted')

	local st = self._st
	local getq, putq, buf, cap = st.getq, st.putq, st.buf, st.cap
	local full = st.full

	-- Full-policy handler returns:
	--   ready:boolean_for_op, result1, result2
	-- where ready==true means the op is ready and result* are returned to the caller.
	local function handle_full()
		if full == 'block' then
			-- Not ready; must block.
			return false
		end

		-- Some message is being discarded due to boundedness.
		st.dropped = st.dropped + 1
		if leak_probe then leak_probe.mailbox_dropped(st._probe_id, full) end

		if full == 'drop_oldest' and buf then
			-- Evict one buffered value to admit the new one.
			-- (For cap==0, drop_oldest is normalised away to reject_newest.)
			buf:pop()
			buf:push(v)
			notify_task_waiters(st)
			return true, true
		end

		-- reject_newest: do not admit v.
		return true, false, 'full'
	end

	local function try()
		if st.closed or self._closed then
			-- Ready: closed is signalled to caller by nil result.
			return true, nil
		end

		-- Rendezvous with a waiting receiver.
		local recv = pop_active(getq)
		if recv then
			recv.suspension:complete(recv.wrap, v)
			cleanup_recv_waiter(recv)
			notify_task_waiters(st)
			return true, true
		end

		-- Buffered enqueue when there is space.
		if buf and buf:length() < cap then
			buf:push(v)
			notify_task_waiters(st)
			return true, true
		end

		-- Full (buffered) or no receiver (rendezvous): apply full policy.
		return handle_full()
	end

	local function block(suspension, wrap_fn)
		if st.closed or self._closed then
			-- Resume sender with nil (closed).
			return suspension:complete(wrap_fn, nil)
		end
		-- Only used for "block" policy.
		local entry = { val = v, suspension = suspension, wrap = wrap_fn }
		local node = putq:push_tail(entry)
		suspension:add_cleanup(function ()
			if node:remove() then
				cleanup_send_waiter(entry)
			end
		end)
	end

	return op.new_primitive(nil, try, block)
end

--- Register a task to be woken when recv may succeed (message arrives or close).
--- This does not expose the scheduler; callers provide a waker capability.
---@param task Task
---@param waker table
---@return WaitToken
function Rx:on_message(task, waker)
	local st = self._st
	assert(task and type(task) == 'table' and type(task.run) == 'function',
		'on_message: task must have :run()')
	assert(waker and type(waker.wakeup) == 'function',
		'on_message: waker must support :wakeup(task)')

	if recv_may_succeed(st) then
		waker:wakeup(task)
		return { unlink = function () return false end }
	end

	local entry = { task = task, waker = waker }
	local node = st.taskq:push_tail(entry)

	return {
		unlink = function ()
			if node:remove() then
				cleanup_task_waiter(entry)
				return true
			end
			return false
		end,
	}
end

--- Synchronously send a message.
---@param v any
---@return boolean|nil ok
---@return string|nil reason  -- "full" when ok==false
function Tx:send(v)
	return perform(self:send_op(v))
end

----------------------------------------------------------------------
-- Rx (receiver)
----------------------------------------------------------------------

--- Return the mailbox close reason (if any).
---@return any|nil
function Rx:why()
	return self._st.reason
end

--- Return total number of dropped messages due to the full policy.
---@return integer
function Rx:dropped()
	return self._st.dropped or 0
end

--- Op that receives the next message.
--- When performed: a non-nil value, or nil when closed and drained.
---@return Op
function Rx:recv_op()
	local st = self._st
	local getq, putq, buf = st.getq, st.putq, st.buf

	local function try()
		-- Prefer unblocking a waiting sender (if present); we may still return
		-- a buffered value first.
		local snd = pop_active(putq)
		if snd then
			-- Sender was accepted (delivered or enqueued-by-refill below).
			snd.suspension:complete(snd.wrap, true)
		end

		if buf and buf:length() > 0 then
			local v = buf:pop()
			-- If there was a sender waiting, refill the buffer with its value.
			if snd then
				buf:push(snd.val)
				cleanup_send_waiter(snd)
			end
			return true, v
		end

		if snd then
			local v = snd.val
			cleanup_send_waiter(snd)
			return true, v
		end

		if st.closed then
			return true, nil
		end

		return false
	end

	---@param suspension Suspension
	---@param wrap_fn WrapFn
	local function block(suspension, wrap_fn)
		if st.closed then
			return suspension:complete(wrap_fn, nil)
		end
		local entry = { suspension = suspension, wrap = wrap_fn }
		local node = getq:push_tail(entry)
		suspension:add_cleanup(function ()
			if node:remove() then
				cleanup_recv_waiter(entry)
			end
		end)
	end

	return op.new_primitive(nil, try, block)
end

--- Synchronously receive the next message.
---@return any|nil v
function Rx:recv()
	return perform(self:recv_op())
end

--- Iterator over received messages, ending at nil (closed and drained).
---@return fun(): any|nil
function Rx:iter()
	return function ()
		return self:recv()
	end
end

----------------------------------------------------------------------
-- Public API
----------------------------------------------------------------------

return {
	new = new,

	Tx = Tx,
	Rx = Rx,
}
