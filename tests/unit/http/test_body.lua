local fibers = require 'fibers'
local body = require 'services.http.body'

local M = {}

local function eq(a, b, msg)
	if a ~= b then error((msg or 'assertion failed') .. ': expected ' .. tostring(b) .. ', got ' .. tostring(a), 2) end
end
local function ok(v, msg) if not v then error(msg or 'assertion failed', 2) end return v end

function M.test_descriptor_rejects_inline_bytes()
	local desc, err = body.validate_descriptor({ kind = 'x', data = 'bytes' }, 'source')
	eq(desc, nil)
	eq(err, 'invalid_args')
end

function M.test_source_and_sink_leases_copy_inside_ops()
	fibers.run(function ()
		body.clear_resolvers_for_test()
		body.register_resolver('unit_source', function ()
			local chunks = { 'ab', 'cd' }
			local i = 0
			return {
				terminated = false,
				read_chunk_op = function ()
					return fibers.guard(function ()
						i = i + 1
						return fibers.always(chunks[i], nil)
					end)
				end,
				terminate = function (self, reason) self.terminated = reason or true; return true end,
			}
		end)
		local written = {}
		body.register_resolver('unit_sink', function ()
			return {
				write_chunk_op = function (_, chunk) return fibers.always((table.insert(written, chunk) and true) or true) end,
				finish_op = function () return fibers.always(true) end,
				terminate = function () return true end,
			}
		end)

		local source = ok(fibers.perform(body.resolve_op({ kind = 'unit_source' }, { direction = 'source' })))
		local sink = ok(fibers.perform(body.resolve_op({ kind = 'unit_sink' }, { direction = 'sink' })))
		local rep = ok(fibers.perform(body.copy_source_to_sink_op(source, sink, { max_bytes = 16 })))
		eq(rep.bytes, 4)
		eq(table.concat(written), 'abcd')
	end)
end

function M.test_resolver_registries_are_service_owned()
	fibers.run(function ()
		local r1 = body.new_registry()
		local r2 = body.new_registry()
		r1:register_resolver('x', function () return { marker = 'r1' } end)
		r2:register_resolver('x', function () return { marker = 'r2' } end)
		local a = ok(fibers.perform(r1:resolve_op({ kind = 'x' }, { direction = 'source' })))
		local b = ok(fibers.perform(r2:resolve_op({ kind = 'x' }, { direction = 'source' })))
		eq(a.marker, 'r1')
		eq(b.marker, 'r2')
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


function M.test_resolver_is_called_when_resolve_op_is_performed_not_constructed()
	fibers.run(function ()
		local registry = body.new_registry()
		local calls = 0
		registry:register_resolver('late_source', function ()
			calls = calls + 1
			return { terminate = function () return true end }
		end)

		local resolve = registry:resolve_op({ kind = 'late_source' }, { direction = 'source' })
		eq(calls, 0, 'resolver must not run at Op construction time')
		local lease = ok(fibers.perform(resolve))
		eq(calls, 1)
		ok(lease)
	end)
end

function M.test_resolver_errors_are_caught_and_normalised()
	fibers.run(function ()
		local registry = body.new_registry()
		registry:register_resolver('boom', function () error('backend exploded', 0) end)
		local lease, err = fibers.perform(registry:resolve_op({ kind = 'boom' }, { direction = 'source' }))
		eq(lease, nil)
		eq(err, 'invalid_args', 'resolver exceptions should become a stable public error')
	end)
end

return M
