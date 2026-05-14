local fibers = require 'fibers'
local body = require 'services.http.body'
local blob = require 'devicecode.blob_source'

local M = {}

local function eq(a, b, msg)
	if a ~= b then error((msg or 'assertion failed') .. ': expected ' .. tostring(b) .. ', got ' .. tostring(a), 2) end
end
local function ok(v, msg) if not v then error(msg or 'assertion failed', 2) end return v end

function M.test_rejects_inline_bytes()
	local bodies, err = body.validate_exchange_bodies({ body = 'bytes' })
	eq(bodies, nil)
	eq(err, 'invalid_args')
	bodies, err = body.validate_exchange_bodies({ data = 'bytes' })
	eq(bodies, nil)
	eq(err, 'invalid_args')
end

function M.test_accepts_lua_body_source_and_response_sink_capabilities()
	local source = blob.from_string('abcd')
	local sink = blob.to_memory()
	local bodies = ok(body.validate_exchange_bodies({ body_source = source, response_sink = sink }))
	eq(bodies.source, source)
	eq(bodies.sink, sink)
end

function M.test_rejects_bad_body_source_and_sink_shapes()
	local bodies, err = body.validate_exchange_bodies({ body_source = { terminate = function () return true end } })
	eq(bodies, nil)
	eq(err, 'invalid_args')
	bodies, err = body.validate_exchange_bodies({ response_sink = { write_chunk_op = function () end } })
	eq(bodies, nil)
	eq(err, 'invalid_args')
end

function M.test_source_and_sink_capabilities_copy_inside_ops()
	fibers.run(function ()
		local source = blob.from_string('abcd')
		local sink = blob.to_memory()
		local rep = ok(fibers.perform(body.copy_source_to_sink_op(source, sink, { max_bytes = 16 })))
		eq(rep.bytes, 4)
		eq(sink:result(), 'abcd')
	end)
end

function M.test_request_body_pipe_is_a_bounded_fibers_sink_and_lua_http_iterator()
	fibers.run(function ()
		local request_body = require 'services.http.transport.request_body'
		local c = require 'fibers.cond'
		local wake = c.new()
		local pipe = ok(request_body.new_pipe({
			condition_factory = function ()
				return {
					wait = function () return fibers.perform(wake:wait_op()) end,
					signal = function () wake:signal(); wake = c.new(); return true end,
				}
			end,
			max_buffered_chunks = 2,
		}))

		ok(fibers.perform(pipe:write_chunk_op('ab')))
		ok(fibers.perform(pipe:write_chunk_op('cd')))
		ok(fibers.perform(pipe:finish_op()))
		local iter = pipe:body_iterator()
		eq(iter(), 'ab')
		eq(iter(), 'cd')
		eq(iter(), nil)
	end)
end

return M
