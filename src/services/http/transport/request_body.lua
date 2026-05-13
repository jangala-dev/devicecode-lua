-- services/http/transport/request_body.lua
-- Bounded bridge from a Fibers-native body source into lua-http's request body
-- iterator contract.  Bytes stay in process-local memory and never cross the
-- bus.  The iterator is consumed by lua-http in a cqueues coroutine; the source
-- side is written by a Fibers worker through write_chunk_op()/finish_op().

local op   = require 'fibers.op'
local cond = require 'fibers.cond'

local M = {}
local Pipe = {}
Pipe.__index = Pipe

local function default_condition_factory()
	local cc = require 'cqueues.condition'
	if type(cc.new) == 'function' then return cc.new() end
	if type(cc) == 'function' then return cc() end
	return nil, 'cqueues.condition has no constructor'
end

local function signal_condition(cv)
	if cv and type(cv.signal) == 'function' then return cv:signal() end
	return nil, 'condition has no signal method'
end

local function wait_condition(cv)
	if cv and type(cv.wait) == 'function' then return cv:wait() end
	return nil, 'condition has no wait method'
end

local function new_space_cond(self)
	self._space_cond = cond.new()
	return self._space_cond
end

local function signal_space(self)
	local c = self._space_cond
	new_space_cond(self)
	if c then c:signal() end
end

local function pop_first(q)
	local v = q[1]
	for i = 1, #q - 1 do q[i] = q[i + 1] end
	q[#q] = nil
	return v
end

function M.new_pipe(opts)
	opts = opts or {}
	local factory = opts.condition_factory or default_condition_factory
	local cv, err = factory()
	if not cv then return nil, err or 'request_body_condition_failed' end

	local max_chunks = opts.max_buffered_chunks or 8
	if type(max_chunks) ~= 'number' or max_chunks < 1 then return nil, 'invalid_args' end

	local self = setmetatable({
		_cv = cv,
		_q = {},
		_max_chunks = max_chunks,
		_closed = false,
		_done = false,
		_err = nil,
		_bytes = 0,
	}, Pipe)
	new_space_cond(self)
	return self, nil
end

function Pipe:stats()
	return {
		queued = #self._q,
		bytes = self._bytes,
		closed = self._closed,
		done = self._done,
		err = self._err,
	}
end

function Pipe:_push(chunk)
	if self._closed then return nil, self._err or 'closed' end
	if self._done then return nil, 'request_body_finished' end
	if type(chunk) ~= 'string' then return nil, 'invalid_args' end
	self._q[#self._q + 1] = chunk
	self._bytes = self._bytes + #chunk
	signal_condition(self._cv)
	return true, nil
end

function Pipe:write_chunk_op(chunk)
	return op.guard(function ()
		if self._closed then return op.always(nil, self._err or 'closed') end
		if #self._q < self._max_chunks then return op.always(self:_push(chunk)) end

		return self._space_cond:wait_op():wrap(function ()
			if self._closed then return nil, self._err or 'closed' end
			if #self._q >= self._max_chunks then return nil, 'request_body_backpressure_wake_failed' end
			return self:_push(chunk)
		end)
	end)
end

function Pipe:finish_op()
	return op.guard(function ()
		if self._closed then return op.always(nil, self._err or 'closed') end
		self._done = true
		signal_condition(self._cv)
		return op.always(true, nil)
	end)
end

function Pipe:fail(reason)
	if self._closed then return true end
	self._err = reason or 'request_body_failed'
	self._closed = true
	self._q = {}
	signal_condition(self._cv)
	signal_space(self)
	return true
end

function Pipe:terminate(reason)
	return self:fail(reason or 'request_body_terminated')
end

function Pipe:body_iterator()
	return function ()
		while not self._closed and not self._done and #self._q == 0 do
			local ok, err = wait_condition(self._cv)
			if ok == nil and err ~= nil then error(err, 0) end
		end

		if self._closed then error(self._err or 'request_body_closed', 0) end

		if #self._q > 0 then
			local chunk = pop_first(self._q)
			signal_space(self)
			return chunk
		end

		return nil
	end
end

function M.new_body(opts)
	local pipe, err = M.new_pipe(opts)
	if not pipe then return nil, err end
	return pipe:body_iterator(), pipe
end

M.Pipe = Pipe
return M
