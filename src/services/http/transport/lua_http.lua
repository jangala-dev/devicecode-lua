-- services/http/transport/lua_http.lua
--
-- Fibers-facing lua-http backend wrapper.
--
-- lua-http still owns HTTP parsing, HTTP/2 stream state, WebSocket handshake
-- plumbing, and cqueues coroutine execution.  UI service code sees Fibers Ops
-- and transport-shaped objects.  The lua-http onstream callback is kept at this
-- edge: it creates an HttpContext, admits it to the listener queue, and then
-- runs the stream command loop.

local op      = require 'fibers.op'
local wait    = require 'fibers.wait'
local fifo    = require 'fibers.utils.fifo'
local runtime = require 'fibers.runtime'
local safe    = require 'coxpcall'

local cqueues_driver = require 'services.http.transport.cqueues_driver'
local terminate = require 'services.http.transport.terminate'

local unpack = rawget(table, 'unpack') or _G.unpack
local pack   = rawget(table, 'pack') or function (...)
	return { n = select('#', ...), ... }
end

local M = {}

local Listener = {}
Listener.__index = Listener

local HttpContext = {}
HttpContext.__index = HttpContext

local function copy_table(t)
	local out = {}
	if not t then return out end
	for k, v in pairs(t) do out[k] = v end
	return out
end

local function tostring_error(e)
	if type(e) == 'string' or type(e) == 'number' then return e end
	return tostring(e)
end

local function notify_waitset(ws, key)
	local sched = runtime.current_scheduler
	if sched then ws:notify_all(key, sched) end
end

local function default_condition_factory()
	local ok, cc = pcall(require, 'cqueues.condition')
	if not ok or not cc then return nil, 'cqueues.condition module is not available' end
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

local function make_server(opts)
	if opts.server then return opts.server end

	local http_server = opts.http_server
	if not http_server then
		local ok, mod = pcall(require, 'http.server')
		if not ok then return nil, mod end
		http_server = mod
	end

	local listen_opts = copy_table(opts.server_options or opts)
	listen_opts.server = nil
	listen_opts.http_server = nil
	listen_opts.driver = nil
	listen_opts.driver_options = nil
	listen_opts.max_accept_queue = nil
	listen_opts.condition_factory = nil
	listen_opts.context_terminator = nil
	listen_opts.on_context = nil
	listen_opts.on_context_admitted = nil
	listen_opts.on_context_transferred = nil
	listen_opts.on_context_terminated = nil
	listen_opts.on_terminate = nil
	listen_opts.backend_timeout = nil

	return http_server.listen(listen_opts)
end

local next_context_id = 0

local function new_context(listener, server, stream)
	next_context_id = next_context_id + 1

	local factory = listener._condition_factory or default_condition_factory
	local cv, err = factory()
	if not cv then error(err or 'failed to create cqueues condition', 2) end

	return setmetatable({
		_id               = next_context_id,
		_listener         = listener,
		_driver           = listener._driver,
		_server           = server,
		_stream           = stream,
		_cmdq             = fifo.new(),
		_cmd_cv           = cv,
		_cmd_waiters      = wait.new_waitset(),
		_closed           = false,
		_close_reason     = nil,
		_terminator       = listener._context_terminator,
		_active_cmd       = nil,
		_commands_started = 0,
		_commands_done    = 0,
	}, HttpContext)
end

function HttpContext:id() return self._id end
function HttpContext:_raw_stream_for_test() return self._stream end
function HttpContext:_raw_server_for_test() return self._server end
function HttpContext:is_closed() return self._closed end
function HttpContext:why() return self._close_reason end

function HttpContext:_notify_public_terminated(reason)
	local ws = rawget(self, '_http_transport_websocket')
	if ws and type(ws._notify_terminated) == 'function' then
		ws:_notify_terminated(reason or self._close_reason or 'closed')
	end

	local public = rawget(self, '_http_public_context')
	if public and type(public._notify_terminated) == 'function' then
		public:_notify_terminated(reason or self._close_reason or 'closed')
	end
end

function HttpContext:_complete_command(cmd, ok, results_or_err)
	if cmd.done or cmd.abandoned then return end
	cmd.done = true
	cmd.phase = 'done'
	cmd.ok = ok
	if ok then cmd.results = results_or_err or pack() else cmd.err = results_or_err end
	self._commands_done = self._commands_done + 1
	notify_waitset(self._cmd_waiters, cmd)
end

function HttpContext:_abandon_command(cmd, reason)
	if cmd.done or cmd.abandoned then return end

	local abort_reason = reason or 'aborted'
	local phase = cmd.phase or 'queued'

	cmd.abandoned = true
	cmd.abort_reason = abort_reason
	cmd.phase = 'abandoned'

	if phase == 'active' then
		if cmd.on_active_abort then
			safe.pcall(cmd.on_active_abort, abort_reason, cmd)
		else
			-- Active stream work may already have consumed request bytes, emitted
			-- response bytes, or changed HTTP/2 stream state.  Losing interest in
			-- the Fibers waiter must therefore close the owning context.
			self:terminate(abort_reason)
		end
	elseif cmd.on_abort then
		safe.pcall(cmd.on_abort, abort_reason, cmd)
	end

	notify_waitset(self._cmd_waiters, cmd)
end

function HttpContext:_enqueue_command(label, fn, opts)
	opts = opts or {}
	if self._closed then return nil, self._close_reason or 'closed' end
	assert(type(fn) == 'function', 'run_stream_op expects a function')

	local cmd = {
		label = label or 'http_stream_command',
		phase = 'queued',
		fn = fn,
		done = false,
		ok = nil,
		results = nil,
		err = nil,
		abandoned = false,
		abort_reason = nil,
		on_abort = opts.on_abort,
		on_active_abort = opts.on_active_abort,
	}

	self._commands_started = self._commands_started + 1
	self._cmdq:push(cmd)
	-- The onstream coroutine waits on a cqueues condition.  Signalling that
	-- condition is the precise wake-up; poking the shared HTTP driver here also
	-- wakes unrelated listener pumps and can turn a context command into a
	-- service-wide busy loop under simple pollable fakes.
	signal_condition(self._cmd_cv)
	return cmd, nil
end

function HttpContext:_command_outcome_op(cmd)
	local function step()
		if cmd.done then
			if cmd.ok then
				local r = cmd.results or pack()
				return true, unpack(r, 1, r.n)
			end
			return true, nil, cmd.err or 'http stream command failed'
		end
		if cmd.abandoned then return true, nil, cmd.abort_reason or 'aborted' end
		if self._closed then return true, nil, self._close_reason or 'closed' end
		return false
	end

	local function register(task)
		return self._cmd_waiters:add(cmd, task)
	end

	return wait.waitable(register, step)
end

--- Run fn(stream, context) inside the original lua-http onstream coroutine.
function HttpContext:run_stream_op(label, fn, opts)
	return op.guard(function ()
		local cmd, err = self:_enqueue_command(label, fn, opts)
		if not cmd then return op.always(nil, err) end

		return self:_command_outcome_op(cmd):on_abort(function ()
			self:_abandon_command(cmd, 'aborted')
		end)
	end)
end

function HttpContext:_run_one_command(cmd)
	if cmd.abandoned then return end

	cmd.phase = 'active'
	self._active_cmd = cmd
	local ok, results_or_err = safe.xpcall(function ()
		return pack(cmd.fn(self._stream, self))
	end, function (e, tb)
		return tb or tostring_error(e)
	end)
	self._active_cmd = nil

	if cmd.abandoned then return end
	if ok then
		self:_complete_command(cmd, true, results_or_err)
	else
		self:_complete_command(cmd, false, results_or_err)
	end
end

-- Test hook: run one queued command without a real cqueues condition loop.
function HttpContext:_drain_one_for_test()
	if self._cmdq:empty() then return false end
	local cmd = self._cmdq:pop()
	self:_run_one_command(cmd)
	return true
end

--- Runs inside lua-http's onstream cqueues coroutine.
function HttpContext:_command_loop()
	while not self._closed do
		local cmd
		if not self._cmdq:empty() then cmd = self._cmdq:pop() end

		if cmd then
			self:_run_one_command(cmd)
		else
			wait_condition(self._cmd_cv)
		end
	end
end

function HttpContext:terminate(reason)
	if self._closed then return true end

	self._closed = true
	self._close_reason = reason or 'closed'

	while not self._cmdq:empty() do
		self:_abandon_command(self._cmdq:pop(), self._close_reason)
	end
	if self._active_cmd then self:_abandon_command(self._active_cmd, self._close_reason) end

	local term = self._terminator
	if term then
		safe.pcall(term, self._stream, self._close_reason, self)
	else
		terminate.terminate_stream(self._stream, self._close_reason)
	end

	-- Wake only the owning onstream command loop.  Listener/server pump
	-- termination is handled by Listener:terminate().
	signal_condition(self._cmd_cv)

	self:_notify_public_terminated(self._close_reason)

	local listener = self._listener
	if listener then listener._contexts[self] = nil end
	return true
end

-- HTTP stream-shaped Ops ------------------------------------------------------

function HttpContext:get_headers_op()
	return self:run_stream_op('http.get_headers', function (stream)
		return stream:get_headers()
	end)
end

function HttpContext:read_chunk_op(_max)
	return self:run_stream_op('http.get_next_chunk', function (stream)
		return stream:get_next_chunk()
	end)
end

function HttpContext:read_chars_op(n)
	return self:run_stream_op('http.get_body_chars', function (stream)
		return stream:get_body_chars(n)
	end)
end

function HttpContext:read_body_as_string_op()
	return self:run_stream_op('http.get_body_as_string', function (stream)
		return stream:get_body_as_string()
	end)
end

function HttpContext:write_headers_op(headers, end_stream)
	return self:run_stream_op('http.write_headers', function (stream)
		return stream:write_headers(headers, not not end_stream)
	end)
end

function HttpContext:write_chunk_op(chunk, end_stream)
	return self:run_stream_op('http.write_chunk', function (stream)
		return stream:write_chunk(chunk, not not end_stream)
	end)
end

function HttpContext:write_body_from_string_op(str)
	return self:run_stream_op('http.write_body_from_string', function (stream)
		return stream:write_body_from_string(str)
	end)
end

function HttpContext:peername_op()
	return self:run_stream_op('http.peername', function (stream)
		if type(stream.peername) ~= 'function' then return nil, 'peername_not_available' end
		return stream:peername()
	end)
end

function HttpContext:localname_op()
	return self:run_stream_op('http.localname', function (stream)
		if type(stream.localname) ~= 'function' then return nil, 'localname_not_available' end
		return stream:localname()
	end)
end

function HttpContext:checktls_op()
	return self:run_stream_op('http.checktls', function (stream)
		if type(stream.checktls) ~= 'function' then return nil, 'checktls_not_available' end
		return stream:checktls()
	end)
end

function HttpContext:connection_version_op()
	return self:run_stream_op('http.connection_version', function (stream)
		if type(stream.connection_version) ~= 'function' then return nil, 'connection_version_not_available' end
		return stream:connection_version()
	end)
end

function HttpContext:write_continue_op()
	return self:run_stream_op('http.write_continue', function (stream)
		if type(stream.write_continue) ~= 'function' then return nil, 'write_continue_not_available' end
		return stream:write_continue()
	end)
end

function HttpContext:unget_op(str)
	return self:run_stream_op('http.unget', function (stream)
		if type(stream.unget) ~= 'function' then return nil, 'unget_not_available' end
		return stream:unget(str)
	end)
end

function HttpContext:shutdown_op()
	return self:run_stream_op('http.stream_shutdown', function (stream)
		return stream:shutdown()
	end)
end

-- Listener -------------------------------------------------------------------

function Listener:_notify_accept()
	local sched = runtime.current_scheduler
	if sched then self._accept_waiters:notify_one('accept', sched) end
end

function Listener:_notify_admission()
	local sched = runtime.current_scheduler
	if sched then self._admission_waiters:notify_one('admission', sched) end
end

function Listener:admission_op()
	local function step()
		if not self._admissionq:empty() then
			return true, self._admissionq:pop(), nil
		end
		if self._closed then return true, nil, self._close_reason or 'closed' end
		return false
	end

	local function register(task)
		return self._admission_waiters:add('admission', task)
	end

	return wait.waitable(register, step)
end

function Listener:_admit_context(ctx)
	if self._closed then
		ctx:terminate(self._close_reason or 'listener_closed')
		return nil, 'closed'
	end

	if self._acceptq:length() >= self._max_accept_queue then
		ctx:terminate('accept_queue_full')
		return nil, 'accept_queue_full'
	end

	self._contexts[ctx] = true
	self._acceptq:push(ctx)
	self._admissionq:push(ctx)
	self:_notify_admission()
	self:_notify_accept()
	return true, nil
end

function Listener:_onstream(server, stream)
	local ctx = new_context(self, server, stream)
	local ok = self:_admit_context(ctx)
	if not ok then return end
	ctx:_command_loop()
end

function M.listen(opts)
	opts = opts or {}

	local driver = opts.driver
	if not driver then driver = assert(cqueues_driver.new(opts.driver_options or {})) end

	local self = setmetatable({
		_driver             = driver,
		_server             = nil,
		_acceptq            = fifo.new(),
		_accept_waiters     = wait.new_waitset(),
		_admissionq         = fifo.new(),
		_admission_waiters  = wait.new_waitset(),
		_closed             = false,
		_close_reason       = nil,
		_max_accept_queue   = opts.max_accept_queue or 64,
		_contexts           = {},
		_condition_factory  = opts.condition_factory,
		_context_terminator = opts.context_terminator,
		_backend_timeout    = opts.backend_timeout,
	}, Listener)

	local server_opts = copy_table(opts)
	if server_opts.cq == nil and driver.controller then server_opts.cq = driver:controller() end
	server_opts.onstream = function (server, stream)
		return self:_onstream(server, stream)
	end
	server_opts.driver = nil
	server_opts.max_accept_queue = nil
	server_opts.condition_factory = nil
	server_opts.context_terminator = nil
	server_opts.on_context = nil
	server_opts.on_context_admitted = nil
	server_opts.on_context_transferred = nil
	server_opts.on_context_terminated = nil
	server_opts.on_terminate = nil
	server_opts.driver_options = nil
	server_opts.backend_timeout = nil

	local server, err = make_server(server_opts)
	if not server then return nil, err end
	self._server = server
	return self
end

function Listener:_raw_server_for_test() return self._server end
function Listener:localname()
	if self._server and type(self._server.localname) == 'function' then return self._server:localname() end
	return nil, 'localname_not_available'
end
function Listener:is_closed() return self._closed end
function Listener:why() return self._close_reason end

function Listener:accept_op()
	local function step()
		if not self._acceptq:empty() then
			local ctx = self._acceptq:pop()
			-- Ownership transfer: once accepted, the caller/request scope owns
			-- normal use and graceful response work.  The listener keeps only
			-- unaccepted contexts for listener-close cleanup.
			self._contexts[ctx] = nil
			return true, ctx
		end
		if self._closed then return true, nil, self._close_reason or 'closed' end
		return false
	end

	local function register(task)
		return self._accept_waiters:add('accept', task)
	end

	return wait.waitable(register, step)
end

function Listener:pump_once_op()
	return self._driver:pollable_step_op(self._server, function (server)
		return server:step(0)
	end)
end

function Listener:run()
	local perform = require 'fibers.performer'.perform
	while not self._closed do
		local ok, err = perform(self:pump_once_op())
		if ok == nil then
			self:terminate(err or 'lua-http server pump failed')
			return nil, err
		end
	end
	return true, nil
end

function Listener:start(scope)
	assert(scope and scope.spawn, 'Listener:start expects a scope')
	local ok, err = scope:spawn(function (owning_scope)
		-- Listener:start may be called from a setup or request operation while
		-- the listener pump is deliberately owned by another scope, typically
		-- the HTTP service scope.  Once that target scope has started, its
		-- finalisers must be installed from inside it.
		owning_scope:finally(function ()
			self:terminate('scope_finalised')
		end)

		return self:run()
	end)
	if not ok then return nil, err end
	return true, nil
end

function Listener:listen_op()
	return self._driver:run_op('http.server.listen', function ()
		return self._server:listen(self._backend_timeout)
	end)
end

function Listener:pause()
	if self._server and type(self._server.pause) == 'function' then return self._server:pause() end
	return true
end

function Listener:resume()
	if self._server and type(self._server.resume) == 'function' then return self._server:resume() end
	return true
end

function Listener:terminate(reason)
	if self._closed then return true end

	self._closed = true
	self._close_reason = reason or 'closed'

	terminate.terminate_server(self._server, self._close_reason)

	local contexts = {}
	for ctx in pairs(self._contexts) do contexts[#contexts + 1] = ctx end
	for _, ctx in ipairs(contexts) do ctx:terminate(self._close_reason) end
	while not self._acceptq:empty() do
		local ctx = self._acceptq:pop()
		if ctx and (type(ctx.is_closed) ~= 'function' or not ctx:is_closed()) then
			ctx:terminate(self._close_reason)
		end
	end

	local sched = runtime.current_scheduler
	if sched then
		self._accept_waiters:notify_all('accept', sched)
		self._admission_waiters:notify_all('admission', sched)
	end
	if self._driver and self._driver.poke then self._driver:poke() end
	return true
end

M.Listener = Listener
M.HttpContext = HttpContext
M._new_context_for_test = new_context
M._default_condition_factory = default_condition_factory

return M
