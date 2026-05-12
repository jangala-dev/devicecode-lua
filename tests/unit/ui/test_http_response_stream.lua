-- tests/unit/ui/test_http_response_stream.lua

local fibers = require 'fibers'
local response = require 'services.ui.http.response'
local cjson = require 'cjson.safe'

local tests = {}

local function fail(msg) error(msg or 'assertion failed', 2) end
local function assert_eq(a, b, msg) if a ~= b then fail(msg or ('expected '..tostring(b)..', got '..tostring(a))) end end
local function assert_nil(v, msg) if v ~= nil then fail(msg or ('expected nil, got '..tostring(v))) end end
local function assert_true(v, msg) if v ~= true then fail(msg or ('expected true, got '..tostring(v))) end end
local function assert_not_nil(v, msg) if v == nil then fail(msg or 'expected non-nil') end end

local function ctx()
	return {
		calls = {},
		write_headers_op = function(self, status, headers, opts)
			return fibers.always(function()
				self.calls[#self.calls + 1] = { kind = 'headers', status = status, headers = headers, end_stream = opts and opts.end_stream }
				return true, nil
			end):wrap(function(th) return th() end)
		end,
		write_chunk_op = function(self, chunk, opts)
			return fibers.always(function()
				self.calls[#self.calls + 1] = { kind = 'chunk', chunk = chunk, end_stream = opts and opts.end_stream }
				return true, nil
			end):wrap(function(th) return th() end)
		end,
		terminate = function(self, reason)
			self.abandoned = reason
			return true, nil
		end,
	}
end

function tests.test_stream_headers_chunks_and_end_state()
	fibers.run(function()
		local raw = ctx()
		local owner = response.new(raw)
		local ok, err = fibers.perform(owner:write_headers_op(200, { ['content-type'] = 'text/plain' }))
		assert_true(ok, err)
		ok, err = fibers.perform(owner:write_chunk_op('abc'))
		assert_true(ok, err)
		ok, err = fibers.perform(owner:end_stream_op())
		assert_true(ok, err)
		assert_eq(owner:state(), 'ended')
		assert_eq(raw.calls[1].kind, 'headers')
		assert_eq(raw.calls[2].chunk, 'abc')
		assert_eq(raw.calls[3].end_stream, true)
	end)
end

function tests.test_invalid_response_state_transitions_fail()
	fibers.run(function()
		local owner = response.new(ctx())
		local ok, err = fibers.perform(owner:write_chunk_op('late'))
		assert_nil(ok)
		assert_eq(err, 'response stream is not open')
		ok, err = fibers.perform(owner:write_headers_op(200, {}))
		assert_true(ok, err)
		ok, err = fibers.perform(owner:reply_op(200, 'body', {}))
		assert_nil(ok)
		assert_eq(err, 'response already resolved')
	end)
end

function tests.test_reply_op_uses_streaming_transport()
	fibers.run(function()
		local raw = ctx()
		local owner = response.new(raw)
		local ok, err = fibers.perform(owner:reply_op(201, 'hello', { ['content-type'] = 'text/plain' }))
		assert_true(ok, err)
		assert_eq(owner:state(), 'replied')
		assert_eq(#raw.calls, 2)
		assert_eq(raw.calls[1].kind, 'headers')
		assert_eq(raw.calls[1].status, 201)
		assert_eq(raw.calls[2].kind, 'chunk')
		assert_eq(raw.calls[2].chunk, 'hello')
		assert_eq(raw.calls[2].end_stream, true)
	end)
end

function tests.test_reply_json_op_encodes_table_without_injected_encoder()
	fibers.run(function()
		local raw = ctx()
		local owner = response.new(raw)
		local ok, err = fibers.perform(owner:reply_json_op(200, { session_id = 's1' }))
		assert_true(ok, err)
		assert_eq(owner:state(), 'replied')
		assert_eq(raw.calls[1].headers['content-type'], 'application/json')
		local body = assert(cjson.decode(raw.calls[2].chunk))
		assert_eq(body.session_id, 's1')
	end)
end

function tests.test_terminate_abandons_without_writing()
	local raw = ctx()
	local owner = response.new(raw)
	local ok, err = owner:terminate('closed')
	assert_true(ok, err)
	assert_eq(raw.abandoned, 'closed')
	assert_eq(#raw.calls, 0)
	assert_eq(owner:state(), 'abandoned')
end

function tests.test_transport_write_failure_abandons_response()
	fibers.run(function()
		local raw = ctx()
		raw.write_chunk_op = function()
			return fibers.always(nil, 'chunk_failed')
		end
		local owner = response.new(raw)
		local ok, err = fibers.perform(owner:write_headers_op(200, {}))
		assert_true(ok, err)
		ok, err = fibers.perform(owner:write_chunk_op('abc'))
		assert_nil(ok)
		assert_eq(err, 'chunk_failed')
		assert_eq(owner:state(), 'abandoned')
	end)
end

function tests.test_cancellation_while_streaming_chunk_abandons_response_now()
	fibers.run(function()
		local raw = ctx()
		local abandoned
		raw.terminate = function(_, reason)
			abandoned = reason
			return true, nil
		end
		raw.write_chunk_op = function()
			return require('fibers.sleep').sleep_op(1):wrap(function () return true, nil end)
		end

		local owner = response.new(raw)
		local ok, err = fibers.perform(owner:write_headers_op(200, {}))
		assert_true(ok, err)

		local completed = fibers.perform(fibers.boolean_choice(
			owner:write_chunk_op('slow'),
			require('fibers.sleep').sleep_op(0.01)
		))
		assert_eq(completed, false)
		assert_eq(owner:state(), 'abandoned')
		assert_eq(abandoned, 'response_chunk_aborted')
	end)
end


function tests.test_headers_op_losing_choice_releases_start_token_and_abandons()
	fibers.run(function()
		local sleep = require 'fibers.sleep'
		local raw = ctx()
		local abandoned
		raw.terminate = function(_, reason)
			abandoned = reason
			return true, nil
		end
		raw.write_headers_op = function()
			return sleep.sleep_op(1):wrap(function () return true, nil end)
		end

		local owner = response.new(raw)
		local completed = fibers.perform(fibers.boolean_choice(
			owner:write_headers_op(200, {}),
			sleep.sleep_op(0.01)
		))
		assert_eq(completed, false)
		assert_eq(owner:state(), 'abandoned')
		assert_eq(abandoned, 'response_headers_aborted')

		local ok, err = fibers.perform(owner:write_headers_op(200, {}))
		assert_nil(ok)
		assert_eq(err, 'response already started')
	end)
end

return tests
