-- fibers/io/stream.lua

local wait    = require 'fibers.wait'
local bytes   = require 'fibers.utils.bytes'
local op      = require 'fibers.op'
local perform = require 'fibers.performer'.perform
local runtime = require 'fibers.runtime'

local RingBuf   = bytes.RingBuf
local LinearBuf = bytes.LinearBuf

---@class StreamBackend
---@field read_string  fun(self: StreamBackend, max: integer): string|nil, any|nil, any|nil
---@field write_string fun(self: StreamBackend, data: string): integer|nil, any|nil, any|nil
---@field on_readable  fun(self: StreamBackend, task: Task): WaitToken
---@field on_writable  fun(self: StreamBackend, task: Task): WaitToken
---@field close        fun(self: StreamBackend): boolean, any|nil
---@field seek         fun(self: StreamBackend, whence: string, offset: integer): integer|nil, any|nil
---@field nonblock     fun(self: StreamBackend)|nil
---@field block        fun(self: StreamBackend)|nil
---@field filename     string|nil
---@field fileno       fun(self: StreamBackend): integer|nil

---@class Stream
---@field io StreamBackend|nil
---@field rx any|nil
---@field tx any|nil
---@field line_buffering boolean
---@field _bufmode '"no"'|'"line"'|'"full"'|nil
---@field _bufsize integer|nil
---@field _ws Waitset
---@field _closed boolean
---@field _closing boolean
---@field _sticky_rerr any|nil
---@field _sticky_werr any|nil
---@field _big string|nil
---@field _big_off integer
---@field _pump_task Task
---@field _pump_token WaitToken|nil
---@field _pump_scheduled boolean
---@field _close_done boolean
---@field _close_ok boolean|nil
---@field _close_err any|nil
---@field _rd_owner any|nil
---@field _wr_owner any|nil
local Stream = {}
Stream.__index = Stream

local DEFAULT_BUFFER_SIZE = 2 ^ 12
local BIG_WRITE_CHUNK     = 64 * 1024

-- Single internal wait key. Everything that could unblock someone notifies K_STATE.
local K_STATE    = 'state'
local WANT_STATE = K_STATE

----------------------------------------------------------------------
-- Small helpers
----------------------------------------------------------------------

local function sched() return runtime.current_scheduler end

-- Lifecycle predicates.
function Stream:_has_backend() return self.io ~= nil end

-- No backend, or already fully terminated.
function Stream:_is_dead() return self._closed or (self.io == nil) end

-- In the close handshake, but not yet torn down.
function Stream:_is_closing() return self._closing and not self._closed end

function Stream:_is_readable() return self.rx ~= nil end

function Stream:_is_writable() return self.tx ~= nil end

local function token2(t1, t2)
	return {
		unlink = function ()
			if t1 and t1.unlink then t1:unlink() end
			if t2 and t2.unlink then t2:unlink() end
			return false
		end,
	}
end

local NO_TOKEN = { unlink = function () return false end }

function Stream:_signal_state()
	self._ws:notify_all(K_STATE, sched())
end

local function drained_tx(self)
	return (not self._big) and self.tx and (self.tx:read_avail() == 0)
end

----------------------------------------------------------------------
-- Lane serialisation (read/write)
----------------------------------------------------------------------

local function new_lane(stream, field)
	local owner = {}

	local function acquire()
		local cur = stream[field]
		if cur == nil or cur == owner then
			stream[field] = owner
			return true
		end
		return false
	end

	local function release()
		if stream[field] == owner then
			stream[field] = nil
			stream:_signal_state()
			if stream._closing and not stream._close_done then
				stream:_finish_close_if_ready()
			end
		end
	end

	-- Common wrapper; probe releases on would-block, run holds the lane.
	local function wrap(step, release_on_fail)
		return function ()
			if not acquire() then return false, WANT_STATE end

			local ok, v = step()
			if ok then return true, v end

			if release_on_fail then release() end

			return false, v or WANT_STATE
		end
	end

	local function wrap_probe(step) return wrap(step, true) end

	local function wrap_run(step) return wrap(step, false) end

	return { release = release, wrap_probe = wrap_probe, wrap_run = wrap_run }
end

----------------------------------------------------------------------
-- Backend wait registration
----------------------------------------------------------------------

local function make_register(self, opts)
	opts = opts or {}
	local primed = false

	return function (task, waker, want)
		-- Always register internal state, so close/pump changes wake everyone.
		local t_state = self._ws:add(K_STATE, task)

		if opts.prime_once and not primed then
			primed = true
			waker:wakeup(task)
		end

		-- Internal waits (or unspecified wants) just wait on state changes.
		if want == K_STATE or want == nil or not (want == 'rd' or want == 'wr') then
			return token2(t_state, NO_TOKEN)
		end

		local io = self.io
		if not io then
			-- Ensure the task runs again and the step observes closure.
			waker:wakeup(task)
			return token2(t_state, NO_TOKEN)
		end

		local tok
		if want == 'wr' and io.on_writable then
			tok = io:on_writable(task)
		else
			tok = io:on_readable(task)
		end

		return token2(t_state, tok)
	end
end

----------------------------------------------------------------------
-- Construction
----------------------------------------------------------------------

---@param io_backend StreamBackend
---@param readable? boolean
---@param writable? boolean
---@param bufsize? integer
---@return Stream
local function open(io_backend, readable, writable, bufsize)
	bufsize = bufsize or DEFAULT_BUFFER_SIZE

	local s = setmetatable({
		io             = io_backend,
		line_buffering = false,
		_ws            = wait.new_waitset(),
		_big_off       = 0,
	}, Stream)

	if readable ~= false then s.rx = RingBuf.new(bufsize) end
	if writable ~= false then s.tx = RingBuf.new(bufsize) end

	s._pump_task = { run = function () s:_pump() end }
	return s
end

---@param x any
---@return boolean
local function is_stream(x)
	return type(x) == 'table' and getmetatable(x) == Stream
end

function Stream:nonblock()
	if self.io and self.io.nonblock then self.io:nonblock() end
end

function Stream:block()
	if self.io and self.io.block then self.io:block() end
end

----------------------------------------------------------------------
-- Close / terminate
----------------------------------------------------------------------

function Stream:_latch_close(ok, err)
	if self._close_done then return end
	self._close_done = true
	self._close_ok   = ok
	self._close_err  = err
	self:_signal_state()
end

function Stream:_unlink_pump_wait()
	local pt = self._pump_token
	self._pump_token = nil
	if pt and pt.unlink then pt:unlink() end
end

function Stream:terminate(_)
	-- Idempotent.
	if self._closed then
		if not self._close_done then
			if self._sticky_werr ~= nil then
				self:_latch_close(nil, self._sticky_werr)
			else
				self:_latch_close(true, nil)
			end
		end
		self:_signal_state()
		return
	end

	self._closed   = true
	self._closing  = true
	self._rd_owner = nil
	self._wr_owner = nil

	self:_unlink_pump_wait()

	local io = self.io
	self.io = nil

	self.rx, self.tx = nil, nil
	self._big, self._big_off = nil, 0

	if io and io.close then
		pcall(function () io:close() end)
	end

	if not self._close_done then
		if self._sticky_werr ~= nil then
			self:_latch_close(nil, self._sticky_werr)
		else
			self:_latch_close(true, nil)
		end
	end

	self:_signal_state()
end

function Stream:_finish_close_if_ready()
	if self._close_done or self._closed then return end
	if not self._closing then return end

	-- If writable, wait for drain or sticky write error.
	if self.tx then
		if self._sticky_werr ~= nil then
			self:_latch_close(nil, self._sticky_werr)
			self:terminate('closed')
			return
		end
		if not drained_tx(self) then
			return
		end
	end

	-- Do not tear down while a lane is owned.
	if self._rd_owner ~= nil or self._wr_owner ~= nil then
		return
	end

	self:_latch_close(true, nil)
	self:terminate('closed')
end

function Stream:_begin_close(_)
	if self._closed then
		self:_signal_state()
		self:_finish_close_if_ready()
		return
	end
	self._closing = true
	self:_signal_state()
	self:_finish_close_if_ready()
end

---@return Op
function Stream:close_op()
	local register = make_register(self, { prime_once = true })

	local function probe_step()
		if self._close_done then
			return true, function () return self._close_ok, self._close_err end
		end
		return false, WANT_STATE
	end

	local function run_step()
		if not self._closing and not self._closed then
			self:_begin_close('closing')
		end

		-- Ensure pending output makes progress if any.
		if self.tx then self:_kick_pump() end

		self:_finish_close_if_ready()

		if self._close_done then
			return true, function () return self._close_ok, self._close_err end
		end
		return false, WANT_STATE
	end

	return wait.waitable2(register, probe_step, run_step)
		:wrap(function (th)
			local ok, err = th()
			if ok then return true, nil end
			return nil, err
		end)
end

----------------------------------------------------------------------
-- Read path (choice-safe; ALWAYS returns thunks on ready)
----------------------------------------------------------------------

---@param stream Stream
---@param buf any
---@param min integer
---@param max integer
---@param terminator string|nil
---@return fun(): boolean, any
---@return fun(): boolean, any
local function make_read_steps(stream, buf, min, max, terminator)
	local tally = 0
	local term_target = nil
	local want_hint = WANT_STATE

	local function term_enabled()
		return terminator ~= nil and terminator ~= ''
	end

	local function maybe_clamp()
		if term_target or not term_enabled() or not stream.rx then return end
		local loc = stream.rx:find(terminator)
		if not loc then return end
		local final = tally + loc + #terminator
		if final <= max then
			term_target = final
			min, max = final, final
		end
	end

	local function drain_once()
		if not stream.rx then return end
		local avail = stream.rx:read_avail()
		if avail <= 0 or tally >= max then return end
		local need = math.min(avail, max - tally)
		if need <= 0 then return end
		local chunk = stream.rx:take(need)
		if chunk and #chunk > 0 then
			buf:append(chunk)
			tally = tally + #chunk
		end
	end

	local function drain_all()
		if not stream.rx then return end
		while tally < max do
			local before = tally
			drain_once()
			if tally == before then break end
		end
	end

	-- Terminal check used for both probe and run; does not perform backend I/O.
	-- Always returns either nil (not terminal) or a thunk.
	local function terminal_thunk()
		if stream._sticky_rerr ~= nil then
			maybe_clamp()
			return function ()
				drain_all()
				return buf, tally, stream._sticky_rerr
			end
		end
		if stream:_is_dead() or stream:_is_closing() then
			return function () return buf, tally, 'closed' end
		end
		return nil
	end

	local function probe_step()
		local th = terminal_thunk()
		if th then return true, th end

		maybe_clamp()
		if tally >= min then
			return true, function () return buf, tally, nil end
		end

		-- Choice-safe: if rx has enough to satisfy min, return a drain thunk.
		local rx = stream.rx
		if rx and tally < max then
			local avail = rx:read_avail()
			if avail > 0 then
				local possible = tally + math.min(avail, max - tally)
				if possible >= min then
					return true, function ()
						drain_once()
						return buf, tally, nil
					end
				end
			end
		end

		return false, want_hint
	end

	local function run_step()
		while true do
			local th = terminal_thunk()
			if th then return true, th end

			maybe_clamp()
			drain_once()
			if tally >= min then
				return true, function () return buf, tally, nil end
			end

			local io = stream.io
			if not (io and io.read_string) then
				return true, function () return buf, tally, 'backend does not support read_string' end
			end

			local room = stream.rx:write_avail()
			if room <= 0 then
				return true, function () return buf, tally, 'buffer capacity exhausted' end
			end

			local data, err, want = io:read_string(room)
			if err ~= nil then
				stream._sticky_rerr = err
				stream:_signal_state()
				return true, function () return buf, tally, err end
			end

			if data == nil then
				want_hint = want or 'rd'
				return false, want_hint
			end

			if data == '' then
				-- EOF
				return true, function () return buf, tally, nil end
			end

			stream.rx:put(data)
		end
	end

	return probe_step, run_step
end

---@param buf any
---@param opts? { min?: integer, max?: integer, terminator?: string, eof_ok?: boolean }
---@return Op
function Stream:read_into_op(buf, opts)
	assert(self.rx, 'stream is not readable')

	opts             = opts or {}
	local min        = opts.min or 1
	local max        = opts.max or min
	local terminator = opts.terminator
	local eof_ok     = not not opts.eof_ok

	local lane = new_lane(self, '_rd_owner')
	local probe_step, run_step = make_read_steps(self, buf, min, max, terminator)

	probe_step = lane.wrap_probe(probe_step)
	run_step   = lane.wrap_run(run_step)

	local register = make_register(self, { prime_once = true })

	local function wrap(th)
		local ret_buf, cnt, err = th()
		lane.release()

		if cnt == 0 and not eof_ok then
			return nil, 0, err
		end
		return ret_buf, cnt, err
	end

	local ev = wait.waitable2(register, probe_step, run_step, wrap)
	return ev:on_abort(function () lane.release() end)
end

function Stream:core_read_op(opts)
	local buf = LinearBuf.new()
	local ev  = self:read_into_op(buf, opts)

	return ev:wrap(function (ret_buf, cnt, err)
		if not ret_buf then return nil, 0, err end
		local s = ret_buf:tostring()
		if cnt == 0 and s == '' then
			return nil, 0, err
		end
		return s, cnt, err
	end)
end

function Stream:read_some_op(max)
	assert(type(max) == 'number' and max >= 0, 'read_some_op: max must be non-negative')
	if max == 0 then return op.always('', nil) end

	return self:core_read_op { min = 1, max = max, eof_ok = true }
		:wrap(function (s, cnt, err)
			if err ~= nil then return nil, err end
			if not s or cnt == 0 then return nil, nil end
			return s, nil
		end)
end

function Stream:read_exactly_op(n)
	assert(type(n) == 'number' and n >= 0, 'read_exactly_op: n must be non-negative')
	if n == 0 then return op.always('', nil) end

	return self:core_read_op { min = n, max = n, eof_ok = false }
		:wrap(function (s, cnt, err)
			if err ~= nil then return nil, err end
			if not s or cnt ~= n then return nil, 'short read' end
			return s, nil
		end)
end

function Stream:read_line_op(opts)
	assert(self.rx, 'stream is not readable')

	opts            = opts or {}
	local term      = opts.terminator or '\n'
	local keep_term = not not opts.keep_terminator

	local ev = self:core_read_op {
		min        = math.huge,
		max        = math.huge,
		terminator = term,
		eof_ok     = true,
	}

	return ev:wrap(function (s, cnt, err)
		if err ~= nil then return nil, err end
		if not s or cnt == 0 then return nil, nil end

		if not keep_term and #term > 0 and s:sub(- #term) == term then
			s = s:sub(1, - #term - 1)
		end

		return s, nil
	end)
end

function Stream:read_all_op()
	assert(self.rx, 'stream is not readable')

	return self:core_read_op { min = math.huge, max = math.huge, eof_ok = true }
		:wrap(function (s, _, err)
			if not s then return '', err end
			return s, err
		end)
end

----------------------------------------------------------------------
-- Buffered write pump
----------------------------------------------------------------------

function Stream:_kick_pump()
	if self._pump_scheduled then return end
	if self:_is_dead() then return end
	self._pump_scheduled = true
	sched():schedule(self._pump_task)
end

local function next_write_chunk(self)
	if self._big then
		if self._big_off >= #self._big then
			self._big = nil
			self._big_off = 0
			self:_signal_state()
			return nil
		end
		local remaining = #self._big - self._big_off
		local take = remaining
		if take > BIG_WRITE_CHUNK then take = BIG_WRITE_CHUNK end
		return self._big:sub(self._big_off + 1, self._big_off + take), 'big'
	end

	if self.tx and self.tx:read_avail() > 0 then
		local avail = self.tx:read_avail()
		if avail > BIG_WRITE_CHUNK then avail = BIG_WRITE_CHUNK end
		return self.tx:peek(avail), 'ring'
	end

	return nil
end

local function advance_after_write(self, mode, n)
	if mode == 'big' then
		self._big_off = self._big_off + n
		if self._big_off >= #self._big then
			self._big = nil
			self._big_off = 0
		end
		self:_signal_state()
		return
	end

	self.tx:advance_read(n)
	self:_signal_state()
end

function Stream:_pump()
	self._pump_scheduled = false

	local io = self.io
	if self:_is_dead() or not io then return false end
	if self._sticky_werr then return false end
	if not (self.tx or self._big) then return false end

	self:_unlink_pump_wait()

	local progressed = false

	while true do
		if self._sticky_werr or self:_is_dead() then break end

		local chunk, mode = next_write_chunk(self)
		if not chunk or #chunk == 0 then break end

		local n, err, want = io:write_string(chunk)
		if err then
			self._sticky_werr = err
			self:_signal_state()
			break
		end

		if n == nil or n == 0 then
			-- Would block: arm readiness (poller is responsible for any EPERM cases).
			local w = (want == 'rd') and 'rd' or 'wr'
			if w == 'rd' and io.on_readable then
				self._pump_token = io:on_readable(self._pump_task)
			else
				self._pump_token = io:on_writable(self._pump_task)
			end
			break
		end

		progressed = true
		advance_after_write(self, mode, n)
	end

	if drained_tx(self) then self:_signal_state() end

	self:_finish_close_if_ready()
	return progressed
end

----------------------------------------------------------------------
-- Buffered write ops
----------------------------------------------------------------------

-- Shared output-lane op builder.
-- kind:
--   * 'write' : publish bytes (buffer/big) and return (n|nil, err|nil)
--   * 'flush' : wait until outbound is drained and return (true|nil, err|nil)
local function output_lane_op(self, kind, str)
	assert(kind == 'write' or kind == 'flush', 'output_lane_op: bad kind')

	local lane     = new_lane(self, '_wr_owner')
	local register = make_register(self)

	local function pending()
		return (self._big ~= nil) or (self.tx and self.tx:read_avail() > 0)
	end

	local function drained() return not pending() end

	-- Decide whether we can accept `str` into the outbound queue.
	-- Terminal/error cases are checked by step() before calling this.
	local function can_accept(len)
		local mode = self._bufmode or 'full'

		if mode == 'no' then
			-- Do not allow queuing; require fully drained output.
			if pending() then return false end
			return true, 'big'
		end

		-- Existing buffered behaviour.
		if self._big then return false end

		local cap = self.tx:capacity()
		if len <= self.tx:write_avail() then return true, 'ring' end
		if self.tx:read_avail() == 0 and len > cap then return true, 'big' end

		return false
	end

	local function publish(mode, s)
		if mode == 'ring' then
			self.tx:put(s)
		else
			self._big = s
			self._big_off = 0
		end
	end

	local function rollback_published(mode)
		-- Only used in the idle-fast-path failure case.
		-- Safe because was_idle implies there was no prior pending output.
		if mode == 'ring' then
			if self.tx then self.tx:reset() end
		else
			self._big, self._big_off = nil, 0
		end
	end

	local function step(is_probe)
		-- Sticky backend write error always wins.
		if self._sticky_werr ~= nil then
			local e = self._sticky_werr
			return true, function () return nil, e end
		end

		if kind == 'write' then
			-- Writes do not proceed once closing/closed or backend absent.
			if self:_is_dead() or self:_is_closing() then
				return true, function () return nil, 'closed' end
			end

			local len = #str
			local ok, mode = can_accept(len)
			if not ok then
				if not is_probe then self:_kick_pump() end
				return false, WANT_STATE
			end

			local was_idle = drained()

			return true, function ()
				publish(mode, str)

				-- Opportunistic progress when previously idle; surfaces peer-close promptly.
				local progressed = false
				if was_idle then
					progressed = self:_pump() or false
				end

				-- If the very first attempt discovers a terminal error before any progress,
				-- fail this write (and drop the just-published bytes).
				if was_idle and not progressed and self._sticky_werr ~= nil then
					local e = self._sticky_werr
					rollback_published(mode)
					self:_signal_state()
					return nil, e
				end

				if pending() and not self._pump_token then
					self:_kick_pump()
				end

				self:_signal_state()
				return len, nil
			end
		end

		-- kind == 'flush'
		if self:_is_dead() then
			if drained() then
				return true, function () return true, nil end
			end
			return true, function () return nil, 'closed' end
		end

		if drained() then
			return true, function () return true, nil end
		end

		if is_probe then return false, WANT_STATE end

		self:_kick_pump()
		return false, WANT_STATE
	end

	local function probe_step() return step(true) end
	local function run_step() return step(false) end

	probe_step = lane.wrap_probe(probe_step)
	run_step   = lane.wrap_run(run_step)

	local function wrap(th)
		local a, b = th()
		lane.release()
		return a, b
	end

	local ev = wait.waitable2(register, probe_step, run_step, wrap)
	return ev:on_abort(function () lane.release() end)
end

function Stream:core_write_op(str)
	assert(self.tx, 'stream is not writable')
	assert(type(str) == 'string', 'core_write_op expects a string')
	if str == '' then return op.always(0, nil) end
	return output_lane_op(self, 'write', str)
end

local function flush_required_for_write(self, str)
	local mode = self._bufmode or 'full'
	if mode == 'no' then
		return true
	end
	if mode == 'line' and type(str) == 'string' then
		return str:find('\n', 1, true) ~= nil
	end
	return false
end

function Stream:write_op(...)
	assert(self.tx, 'stream is not writable')

	local count = select('#', ...)
	if count == 0 then return op.always(0, nil) end

	local parts = {}
	for i = 1, count do
		local v = select(i, ...)
		parts[i] = (type(v) == 'string') and v or tostring(v)
	end
	local str = table.concat(parts)
	return self:core_write_op(str):wrap(function (n, err)
		if n == nil then return nil, err end

		if flush_required_for_write(self, str) then
			local ok, ferr = perform(self:flush_op())
			if ok == nil then return nil, ferr end
		end

		return n, nil
	end)
end

function Stream:flush_op()
	if not self.tx then return op.always(true, nil) end
	return output_lane_op(self, 'flush')
end

----------------------------------------------------------------------
-- Misc
----------------------------------------------------------------------

function Stream:flush_input()
	if self.rx then self.rx:reset() end
	self:_signal_state()
end

function Stream:seek(whence, offset)
	self:flush()
	if not (self.io and self.io.seek) then
		return nil, 'stream is not seekable'
	end
	whence = whence or 'cur'
	offset = offset or 0
	return self.io:seek(whence, offset)
end

local function next_pow2(n)
	if n <= 1 then return 1 end
	local p = 1
	while p < n do p = p * 2 end
	return p
end

function Stream:setvbuf(mode, size)
	if mode ~= 'no' and mode ~= 'line' and mode ~= 'full' then
		error('bad mode: ' .. tostring(mode))
	end

	self._bufmode = mode
	self.line_buffering = (mode == 'line')

	if size ~= nil then
		assert(type(size) == 'number' and size > 0, 'setvbuf: size must be positive')
		size = next_pow2(math.floor(size))
		self._bufsize = size

		if self.rx and self.rx:read_avail() == 0 then
			self.rx = RingBuf.new(size)
		end
		if self.tx and (not self._big) and self.tx:read_avail() == 0 then
			self.tx = RingBuf.new(size)
		end
		self:_signal_state()
	end

	return self
end

function Stream:filename()
	return self.io and self.io.filename
end

----------------------------------------------------------------------
-- Synchronous convenience wrappers
----------------------------------------------------------------------

function Stream:read_line(opts) return perform(self:read_line_op(opts)) end

function Stream:read_exactly(n) return perform(self:read_exactly_op(n)) end

function Stream:read_some(max) return perform(self:read_some_op(max)) end

function Stream:read_all() return perform(self:read_all_op()) end

function Stream:write(...) return perform(self:write_op(...)) end

function Stream:flush() return perform(self:flush_op()) end

function Stream:close() return perform(self:close_op()) end

----------------------------------------------------------------------
-- Lua io-like compatibility
----------------------------------------------------------------------

function Stream:read_op(fmt)
	assert(self.rx, 'stream is not readable')

	if fmt == nil or fmt == '*l' then return self:read_line_op() end
	if fmt == '*L' then return self:read_line_op { keep_terminator = true } end
	if fmt == '*a' then return self:read_all_op() end

	if type(fmt) == 'number' then
		assert(fmt >= 0, 'read_op: n must be non-negative')
		if fmt == 0 then return op.always('', nil) end

		return self:core_read_op { min = 1, max = fmt, eof_ok = true }
			:wrap(function (s, cnt, err)
				if err then return nil, err end
				if not s or cnt == 0 then return nil, nil end
				return s, nil
			end)
	end

	error('read_op: invalid format ' .. tostring(fmt))
end

function Stream:read(fmt)
	return perform(self:read_op(fmt))
end

----------------------------------------------------------------------
-- Module-level helpers
----------------------------------------------------------------------

--- Race a single line read across multiple named streams.
---
--- When performed, returns:
---   name : string
---   line : string|nil
---   err  : string|nil
---@param named_streams table<string, Stream>
---@param opts? { terminator?: string, keep_terminator?: boolean, max?: integer }
---@return Op
local function merge_lines_op(named_streams, opts)
	local arms = {}
	for name, s in pairs(named_streams) do
		arms[name] = s:read_line_op(opts)
	end
	return op.named_choice(arms)
end

return {
	open           = open,
	is_stream      = is_stream,
	merge_lines_op = merge_lines_op,
	Stream         = Stream,
}
