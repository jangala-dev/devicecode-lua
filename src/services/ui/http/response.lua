-- services/ui/http/response.lua
--
-- Response owner for one HTTP request.
--
-- The response owner is the only UI object that writes an HTTP response.  It
-- owns the response state machine and exposes Op-returning write methods for
-- request-owned scopes.  Finalisers must use terminate(reason) only; they
-- never write bytes.

local fibers = require 'fibers'
local op     = require 'fibers.op'
local errors = require 'services.ui.errors'
local tablex = require 'shared.table'
local safe   = require 'coxpcall'

local ok_http_headers, http_headers = pcall(require, 'services.http.headers')
if not ok_http_headers then http_headers = nil end

local M = {}
local Response = {}
Response.__index = Response

local TERMINAL = {
	replied = true,
	ended = true,
	abandoned = true,
}

local shallow_copy = tablex.shallow_copy

local function normalise_write_result(ok, err, fallback)
	if ok == false or ok == nil then
		return nil, err or fallback or 'response write failed'
	end
	return true, nil
end

local function terminate_ctx(ctx, reason)
	if not ctx then return true, nil end
	local fn = ctx.terminate or ctx.abandon_now
	if type(fn) ~= 'function' then return nil, 'response context has no terminate' end
	local called, ok, err = safe.pcall(fn, ctx, reason)
	if not called then return nil, ok or 'response context termination failed' end
	if ok == false or ok == nil then return nil, err or 'response context termination failed' end
	return true, nil
end

local function is_http_service_context(ctx)
	return type(ctx) == 'table' and (type(ctx._raw_context) == 'function' or type(ctx.registry_id) == 'function')
end

local function response_headers(status, fields)
	if http_headers and type(http_headers.status) == 'function' then
		return http_headers.status(status, fields or {})
	end
	local out = shallow_copy(fields)
	out[':status'] = tostring(status or 200)
	return out, nil
end

local function call_write_headers_op(ctx, fn, status, headers, opts)
	if is_http_service_context(ctx) then
		local h, herr = response_headers(status, headers)
		if not h then return fibers.always(nil, herr or 'response headers construction failed') end
		return fn(ctx, h, not not (opts and opts.end_stream))
	end
	return fn(ctx, status, headers, opts)
end

local function call_write_chunk_op(ctx, fn, chunk, opts)
	if is_http_service_context(ctx) then
		return fn(ctx, chunk or '', not not (opts and opts.end_stream))
	end
	return fn(ctx, chunk or '', opts)
end

local function ensure_method(self, name)
	if not (self._ctx and type(self._ctx[name]) == 'function') then
		return nil, 'response context has no ' .. name
	end
	return self._ctx[name]
end

local function mark_abandoned(self, reason)
	if TERMINAL[self._state] then return false, 'response already resolved' end
	self._state = 'abandoned'
	self._abandoned = reason or 'abandoned'
	return true, nil
end

local function new_start_token(self)
	local response_ref = self
	local token = { active = true }

	function token:release()
		if not self.active then return false end
		self.active = false
		if response_ref._start_token == token then
			response_ref._start_token = nil
		end
		return true
	end

	return token
end

local function acquire_start_token_op(self)
	local function try()
		if self._start_token ~= nil then
			return true, nil, 'response already starting'
		end
		if self._state ~= 'unresolved' then
			return true, nil, 'response already started'
		end

		-- Do not mutate response state during readiness probing.  The token is
		-- committed by the primitive wrap only after this arm has won.
		return true, new_start_token(self), nil
	end

	local function block()
		error('response start token op should never block', 0)
	end

	local function wrap(token, err)
		if not token then return nil, err end
		if self._start_token ~= nil then
			return nil, 'response already starting'
		end
		if self._state ~= 'unresolved' then
			return nil, 'response already started'
		end
		self._start_token = token
		return token, nil
	end

	return op.new_primitive(wrap, try, block)
end

function M.new(ctx, opts)
	opts = opts or {}
	return setmetatable({
		_ctx = ctx or {},
		_state = 'unresolved',
		_status = nil,
		_abandoned = nil,
		_start_token = nil,
		_encode = opts.encode,
	}, Response)
end

function Response:state()
	return self._state
end

function Response:done()
	return TERMINAL[self._state] or false
end

function Response:write_headers_op(status, headers, opts)
	status = status or 200
	headers = shallow_copy(headers)
	opts = opts or {}

	return fibers.run_scope_op(function (scope)
		local fn, missing = ensure_method(self, 'write_headers_op')
		if not fn then return { ok = nil, err = missing } end

		local token, token_err = fibers.perform(acquire_start_token_op(self))
		if not token then return { ok = nil, err = token_err } end

		local finished = false
		scope:finally(function ()
			if not finished then
				token:release()
				mark_abandoned(self, 'response_headers_aborted')
				terminate_ctx(self._ctx, 'response_headers_aborted')
			end
		end)

		local ok, err = fibers.perform(call_write_headers_op(self._ctx, fn, status, headers, {
			end_stream = not not opts.end_stream,
			timeout = opts.timeout,
		}))

		finished = true
		token:release()

		local write_ok, write_err = normalise_write_result(ok, err, 'response headers write failed')
		if write_ok ~= true then
			self._state = 'abandoned'
			self._abandoned = write_err
			return { ok = nil, err = write_err }
		end

		self._status = status
		self._state = opts.end_stream and 'ended' or 'headers_sent'
		return { ok = true }
	end):wrap(function (st, _rep, result_or_primary)
		if st ~= 'ok' then
			return nil, result_or_primary or st
		end
		local result = result_or_primary or {}
		return result.ok, result.err
	end)
end

function Response:write_chunk_op(chunk, opts)
	opts = opts or {}

	return fibers.guard(function ()
		if self._state ~= 'headers_sent' then
			return fibers.always(nil, 'response stream is not open')
		end

		local fn, missing = ensure_method(self, 'write_chunk_op')
		if not fn then return fibers.always(nil, missing) end

		local finished = false
		return call_write_chunk_op(self._ctx, fn, chunk or '', {
			end_stream = not not opts.end_stream,
			timeout = opts.timeout,
		}):wrap(function (ok, err)
			finished = true
			local write_ok, write_err = normalise_write_result(ok, err, 'response chunk write failed')
			if write_ok ~= true then
				self._state = 'abandoned'
				self._abandoned = write_err
				return nil, write_err
			end
			if opts.end_stream then self._state = 'ended' end
			return true, nil
		end):on_abort(function ()
			if not finished then
				mark_abandoned(self, 'response_chunk_aborted')
				terminate_ctx(self._ctx, 'response_chunk_aborted')
			end
		end)
	end)
end

function Response:end_stream_op(opts)
	opts = opts or {}
	opts.end_stream = true
	return self:write_chunk_op('', opts)
end

function Response:reply_op(status, body, headers, opts)
	status = status or 200
	body = body or ''
	headers = shallow_copy(headers)
	opts = opts or {}

	return fibers.guard(function ()
		if self._state ~= 'unresolved' then
			return fibers.always(nil, 'response already resolved')
		end

		local no_body = body == '' or body == nil or not not opts.no_body
		return fibers.run_scope_op(function ()
			local ok, err = fibers.perform(self:write_headers_op(status, headers, {
				end_stream = no_body,
				timeout = opts.timeout,
			}))
			if ok ~= true then error(err or 'response headers write failed', 0) end

			if not no_body then
				ok, err = fibers.perform(self:write_chunk_op(body, {
					end_stream = true,
					timeout = opts.timeout,
				}))
				if ok ~= true then error(err or 'response chunk write failed', 0) end
			end

			self._state = 'replied'
			return { ok = true }
		end):on_abort(function ()
			if not TERMINAL[self._state] then
				mark_abandoned(self, 'response_aborted')
				terminate_ctx(self._ctx, 'response_aborted')
			end
		end):wrap(function (st, _rep, result_or_primary)
			if st ~= 'ok' then
				if not TERMINAL[self._state] then
					mark_abandoned(self, result_or_primary or st)
					terminate_ctx(self._ctx, result_or_primary or st)
				end
				return nil, result_or_primary or st
			end
			return result_or_primary and result_or_primary.ok == true, nil
		end)
	end)
end

function Response:reply_json_op(status, body, headers, opts)
	headers = shallow_copy(headers)
	headers['content-type'] = headers['content-type'] or 'application/json'
	local payload = body
	if self._encode then payload = self._encode(body) end
	return self:reply_op(status, payload, headers, opts)
end

function Response:reply_error_op(status, err)
	local e = err
	if type(status) ~= 'number' then
		e = err or status
		status = errors.http_status(e)
	elseif e == nil then
		e = status
	end
	return self:reply_json_op(status, errors.http_body(e))
end

function Response:abandon_now(reason)
	local ok, err = mark_abandoned(self, reason or 'abandoned')
	if ok ~= true then return ok, err end
	return terminate_ctx(self._ctx, self._abandoned)
end

function Response:terminate(reason)
	if TERMINAL[self._state] then return true, nil end
	return self:abandon_now(reason or 'response_terminated')
end

M.Response = Response
return M
