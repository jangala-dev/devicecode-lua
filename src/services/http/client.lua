-- services/http/client.lua
-- Policy-facing outgoing HTTP client operations. lua-http request machinery is
-- confined to services.http.transport.client; request/response body object
-- capabilities are owned here by operation scopes.

local fibers = require 'fibers'
local op = require 'fibers.op'
local policy = require 'services.http.policy'
local transport_client = require 'services.http.transport.client'
local request_body = require 'services.http.transport.request_body'
local exchange = require 'services.http.exchange'
local body = require 'services.http.body'

local M = {}

local function copy(t)
	local out = {}
	for k, v in pairs(t or {}) do out[k] = v end
	return out
end

local function checked_args(args, opts)
	if not opts.driver or type(opts.driver.run_op) ~= 'function' then return nil, 'driver_required' end
	-- Service operations may pass the already-normalised table returned by
	-- policy.validate_exchange_args.  Do not send that internal shape back
	-- through the public-payload allow-list.
	if type(args) == 'table' and args._uri ~= nil then return args end
	return policy.validate_exchange_args(args, opts.policy or opts)
end

local function unwrap(scope_op)
	return scope_op:wrap(function (st, _rep, result_or_primary, err)
		if st == 'ok' then
			if result_or_primary == nil and err ~= nil then return nil, err end
			return result_or_primary, nil
		end
		return nil, result_or_primary or st
	end)
end


local function install_request_source(scope, checked, opts)
	if not checked.body_source then return checked, nil end

	local source = checked.body_source
	local source_owned = true
	scope:finally(function (_, status, primary)
		if source_owned then body.terminate(source, primary or status or 'exchange_source_finalised') end
	end)

	if type(source.read_chunk_op) ~= 'function' then
		return nil, 'request_body_source_invalid'
	end

	local pipe, perr = request_body.new_pipe({
		max_buffered_chunks = opts.max_request_body_buffer_chunks or 8,
		condition_factory = opts.request_body_condition_factory,
	})
	if not pipe then return nil, perr or 'request_body_pipe_failed' end

	local pipe_owned = true
	scope:finally(function (_, status, primary)
		if pipe_owned then pipe:terminate(primary or status or 'exchange_request_body_finalised') end
	end)

	local spawned, spawn_err = scope:spawn(function ()
		local copied, cerr = fibers.perform(body.copy_source_to_sink_op(source, pipe, {
			max_bytes = opts.max_request_body_bytes or opts.max_request_body or math.huge,
			max_chunk = opts.max_request_body_chunk or 65536,
			too_large_error = 'request_body_too_large',
		}))
		if not copied then
			pipe:fail(cerr or 'request_body_source_failed')
			error(cerr or 'request_body_source_failed', 0)
		end
		return true
	end)
	if spawned ~= true then
		pipe:terminate(spawn_err or 'request_body_spawn_failed')
		return nil, spawn_err or 'request_body_spawn_failed'
	end

	local prepared = copy(checked)
	prepared._request_body = pipe:body_iterator()
	return prepared, {
		source = source,
		pipe = pipe,
		abort_now = function (reason)
			local why = reason or 'request_body_aborted'
			body.terminate(source, why)
			pipe:terminate(why)
			return true
		end,
		mark_done = function ()
			-- req:go() has returned response headers; lua-http has consumed the
			-- request body iterator.  The source is still operation-owned and is
			-- released by the operation finaliser; the pipe is no longer needed.
			pipe_owned = false
			pipe:terminate('request_body_consumed')
			return true
		end,
	}
end

local function open_exchange_result_op(driver, checked, opts)
	return unwrap(fibers.run_scope_op(function (scope)
		-- lua-http consumes request bodies from a cqueues iterator.  The legacy
		-- close-delimited transport runs in Fibers and must read the source through
		-- its Fibers body capability directly, otherwise the cqueues condition used
		-- by request_body.new_pipe can deadlock.
		if checked.response_parser == 'legacy-http1-close' then
			local prepared = copy(checked)
			local source = checked.body_source
			local source_owned = source ~= nil
			if source_owned then
				scope:finally(function (_, status, primary)
					if source_owned then body.terminate(source, primary or status or 'legacy_exchange_source_finalised') end
				end)
				prepared._request_source = source
			end
			local response_headers, stream_or_err = fibers.perform(transport_client.open_exchange_op(driver, prepared, opts))
			if not response_headers then return nil, stream_or_err end
			if source_owned then
				source_owned = false
				body.terminate(source, 'legacy_exchange_source_consumed')
			end
			return { response_headers = response_headers, stream = stream_or_err }
		end

		local prepared, req_body = install_request_source(scope, checked, opts)
		if not prepared then return nil, req_body end

		local response_headers, stream_or_err = fibers.perform(transport_client.open_exchange_op(driver, prepared, opts))
		if not response_headers then
			if req_body and req_body.abort_now then req_body.abort_now(stream_or_err or 'open_exchange_failed') end
			return nil, stream_or_err
		end
		if req_body then req_body.mark_done() end
		return { response_headers = response_headers, stream = stream_or_err }
	end))
end

function M.open_exchange_op(driver, args, opts)
	opts = opts or {}
	return op.guard(function ()
		local checked, perr = checked_args(args, { driver = driver, policy = opts.policy or opts })
		if not checked then return op.always(nil, perr) end
		return open_exchange_result_op(driver, checked, opts):wrap(function (opened, err)
			if not opened then return nil, err end
			return exchange.make(driver, opened.response_headers, opened.stream, opts), nil
		end)
	end)
end

function M.exchange_op(driver, args, opts)
	opts = opts or {}
	return op.guard(function ()
		local checked, perr = checked_args(args, { driver = driver, policy = opts.policy or opts })
		if not checked then return op.always(nil, perr) end
		return unwrap(fibers.run_scope_op(function (scope)
			local sink, ex
			local sink_owned, ex_owned = false, false
			local sink_final_reason, ex_final_reason = 'exchange_sink_finalised', 'exchange_finalised'

			if checked.response_sink then
				sink = checked.response_sink
				sink_owned = true
				scope:finally(function (_, status, primary)
					if sink_owned then body.terminate(sink, sink_final_reason or primary or status or 'exchange_sink_finalised') end
				end)
			end

			local err
			ex, err = fibers.perform(M.open_exchange_op(driver, checked, opts))
			if not ex then sink_final_reason = 'failed'; return nil, err end
			ex_owned = true
			scope:finally(function (_, status, primary)
				if ex_owned and not ex:is_closed() then ex:terminate(ex_final_reason or primary or status or 'exchange_finalised') end
			end)

			local sink_result
			if sink then
				local written, werr = fibers.perform(body.copy_response_to_sink_op(ex, sink, {
					max_bytes = checked.max_response_bytes or opts.max_response_body_bytes or opts.max_response_body or math.huge,
					max_chunk = opts.max_response_body_chunk or 65536,
				}))
				if not written then sink_final_reason = 'failed'; ex_final_reason = 'failed'; return nil, werr end
				sink_owned = false
				sink_result = { bytes = written.bytes }
			else
				local drained, derr = fibers.perform(body.drain_response_op(ex, {
					max_bytes = checked.max_response_bytes or opts.max_response_body_bytes or opts.max_response_body or math.huge,
					max_chunk = opts.max_response_body_chunk or 65536,
				}))
				if not drained then ex_final_reason = 'failed'; return nil, derr end
				sink_result = nil
			end

			return {
				status = ex:status(),
				headers = ex:response_headers_table(),
				response_sink = sink_result,
			}
		end))
	end)
end

M.HttpExchange = exchange.HttpExchange
return M
