local blob_source = require 'services.fabric.blob_source'
local checksum    = require 'services.fabric.checksum'
local protocol    = require 'services.fabric.protocol'
local transfer    = require 'services.fabric.transfer'

local fibers      = require 'fibers'
local sleep       = require 'fibers.sleep'

local runfibers   = require 'tests.support.run_fibers'

local T = {}

local function make_svc()
	return {
		now = function()
			return os.clock()
		end,
		wall = function()
			return 'now'
		end,
		obs_event = function() end,
	}
end

local function make_stub_conn()
	local retains = {}

	return {
		_retain_log = retains,

		retain = function(self, topic, payload)
			retains[#retains + 1] = {
				topic   = topic,
				payload = payload,
			}
			return true
		end,
	}
end

local function wait_until(pred, opts)
	opts = opts or {}
	local timeout  = opts.timeout or 1.0
	local interval = opts.interval or 0.01
	local deadline = fibers.now() + timeout

	while fibers.now() < deadline do
		if pred() then
			return true
		end
		fibers.perform(sleep.sleep_op(interval))
	end

	return pred()
end

local function shallow_copy(t)
	local out = {}
	for k, v in pairs(t or {}) do
		out[k] = v
	end
	return out
end

local function make_collecting_sink(state, opts)
	opts = opts or {}

	return function(_meta)
		local parts = {}

		return {
			begin = function()
				if opts.begin_err ~= nil then
					return nil, opts.begin_err
				end
				return true
			end,

			write = function(_, _seq, _off, raw)
				if opts.write_err ~= nil then
					return nil, opts.write_err
				end
				parts[#parts + 1] = raw
				return true
			end,

			sha256hex = function()
				if opts.sha256hex then
					return opts.sha256hex(parts)
				end
				return checksum.sha256_hex(table.concat(parts))
			end,

			commit = function(_, info)
				if opts.commit_err ~= nil then
					return nil, opts.commit_err
				end
				state.bytes = table.concat(parts)
				state.info  = info
				return opts.commit_info or { stored = true }, nil
			end,

			abort = function(_, reason)
				state.abort_reason = reason
				return true
			end,
		}
	end
end

local function make_pair(opts)
	opts = opts or {}

	local conn  = opts.conn or make_stub_conn()
	local state = opts.state or {}

	local left, right

	left = transfer.new({
		svc           = opts.left_svc or make_svc(),
		conn          = conn,
		link_id       = 'left',
		peer_id       = 'right',
		chunk_raw     = opts.left_chunk_raw,
		ack_timeout_s = opts.left_ack_timeout_s,
		max_retries   = opts.left_max_retries,
		send_frame    = function(msg)
			if type(opts.left_send) == 'function' then
				return opts.left_send(msg, left, right, state)
			end

			local ok, err = right:handle_incoming(msg)
			if ok ~= true then return nil, err end
			return true, nil
		end,
	})

	right = transfer.new({
		svc           = opts.right_svc or make_svc(),
		conn          = conn,
		link_id       = 'right',
		peer_id       = 'left',
		chunk_raw     = opts.right_chunk_raw,
		ack_timeout_s = opts.right_ack_timeout_s,
		max_retries   = opts.right_max_retries,
		send_frame    = function(msg)
			if type(opts.right_send) == 'function' then
				return opts.right_send(msg, left, right, state)
			end

			local ok, err = left:handle_incoming(msg)
			if ok ~= true then return nil, err end
			return true, nil
		end,
		sink_factory = opts.sink_factory,
	})

	return left, right, conn, state
end

local function start_basic_send(left, bytes, meta)
	meta = meta or {
		kind   = 'firmware',
		name   = 'fw.bin',
		format = 'bin',
	}

	local src = blob_source.from_string(meta.name or 'fw.bin', bytes, {
		format = meta.format or 'bin',
	})

	return left:start_send(src, meta)
end

local function good_begin(id)
	return protocol.xfer_begin(
		id or 'xfer-1',
		'firmware',
		'fw.bin',
		'bin',
		'b64url',
		4,
		4,
		1,
		string.rep('a', 64),
		nil
	)
end

function T.transfer_round_trips_blob_between_two_managers()
	runfibers.run(function()
		local received = {
			bytes = nil,
			info  = nil,
		}

		local left, right = make_pair({
			state        = received,
			sink_factory = make_collecting_sink(received),
		})

		local id, err = start_basic_send(left, 'hello-transfer')
		assert(id ~= nil, tostring(err))

		local ok = wait_until(function()
			local st = left:status(id)
			return st ~= nil and st.status == 'done' and received.bytes == 'hello-transfer'
		end, { timeout = 1.0, interval = 0.01 })
		assert(ok == true, 'expected transfer to complete')

		local lst = assert(left:status(id))
		local rst = assert(right:status(id))

		assert(lst.status == 'done')
		assert(rst.status == 'done')
		assert(received.bytes == 'hello-transfer')
	end, { timeout = 1.5 })
end

function T.transfer_rejects_when_receiver_has_no_sink_factory()
	runfibers.run(function()
		local left = transfer.new({
			svc           = make_svc(),
			conn          = make_stub_conn(),
			link_id       = 'left',
			peer_id       = 'right',
			ack_timeout_s = 0.1,
			max_retries   = 2,
			send_frame    = function()
				return true, nil
			end,
		})

		local right = transfer.new({
			svc        = make_svc(),
			conn       = make_stub_conn(),
			link_id    = 'right',
			peer_id    = 'left',
			send_frame = function(msg)
				local ok, err = left:handle_incoming(msg)
				if ok ~= true then return nil, err end
				return true, nil
			end,
		})

		left = transfer.new({
			svc           = make_svc(),
			conn          = make_stub_conn(),
			link_id       = 'left',
			peer_id       = 'right',
			ack_timeout_s = 0.1,
			max_retries   = 2,
			send_frame    = function(msg)
				local ok, err = right:handle_incoming(msg)
				if ok ~= true then return nil, err end
				return true, nil
			end,
		})

		local id, err = start_basic_send(left, 'x')
		assert(id ~= nil, tostring(err))

		local ok = wait_until(function()
			local st = left:status(id)
			return st ~= nil and st.status == 'aborted'
		end, { timeout = 1.0, interval = 0.01 })
		assert(ok == true, 'expected transfer to abort')

		local st = assert(left:status(id))
		assert(tostring(st.err):match('unsupported'))
	end, { timeout = 1.0 })
end

function T.transfer_rejects_second_outgoing_transfer_while_first_is_active()
	runfibers.run(function()
		local left = transfer.new({
			svc           = make_svc(),
			conn          = make_stub_conn(),
			link_id       = 'left',
			peer_id       = 'right',
			ack_timeout_s = 0.05,
			max_retries   = 1,
			send_frame    = function()
				-- Never deliver, so the first transfer stays active briefly.
				return true, nil
			end,
		})

		local id1, err1 = start_basic_send(left, 'first')
		assert(id1 ~= nil, tostring(err1))

		local id2, err2 = start_basic_send(left, 'second')
		assert(id2 == nil, 'expected second start_send to fail')
		assert(err2 == 'outgoing transfer already active',
			'expected outgoing-transfer-active error, got: ' .. tostring(err2))

		-- Let the first worker finish so the assertion runner does not time out.
		local ok = wait_until(function()
			local st = left:status(id1)
			return st ~= nil and st.status == 'aborted'
		end, { timeout = 0.5, interval = 0.01 })
		assert(ok == true, 'expected first transfer to finish')
	end, { timeout = 1.0 })
end

function T.transfer_rejects_second_incoming_transfer_as_busy()
	local sent = {}

	local mgr = transfer.new({
		svc        = make_svc(),
		conn       = make_stub_conn(),
		link_id    = 'right',
		peer_id    = 'left',
		send_frame = function(msg)
			sent[#sent + 1] = msg
			return true, nil
		end,
		sink_factory = make_collecting_sink({}),
	})

	local ok1, err1 = mgr:handle_incoming(good_begin('first'))
	assert(ok1 == true, tostring(err1))

	local ok2, err2 = mgr:handle_incoming(good_begin('second'))
	assert(ok2 == true, tostring(err2))

	assert(#sent >= 2, 'expected two xfer_ready replies')
	assert(sent[1].t == 'xfer_ready' and sent[1].id == 'first' and sent[1].ok == true)
	assert(sent[2].t == 'xfer_ready' and sent[2].id == 'second' and sent[2].ok == false)
	assert(sent[2].err == 'busy')
end

function T.transfer_rejects_incoming_transfer_when_sink_factory_fails()
	local sent = {}

	local mgr = transfer.new({
		svc        = make_svc(),
		conn       = make_stub_conn(),
		link_id    = 'right',
		peer_id    = 'left',
		send_frame = function(msg)
			sent[#sent + 1] = msg
			return true, nil
		end,
		sink_factory = function()
			return nil, 'sink_factory_failed'
		end,
	})

	local ok, err = mgr:handle_incoming(good_begin('first'))
	assert(ok == true, tostring(err))

	assert(#sent == 1, 'expected one xfer_ready reply')
	assert(sent[1].t == 'xfer_ready')
	assert(sent[1].ok == false)
	assert(sent[1].err == 'sink_factory_failed')
end

function T.transfer_rejects_incoming_transfer_when_sink_begin_fails()
	local sent = {}

	local mgr = transfer.new({
		svc        = make_svc(),
		conn       = make_stub_conn(),
		link_id    = 'right',
		peer_id    = 'left',
		send_frame = function(msg)
			sent[#sent + 1] = msg
			return true, nil
		end,
		sink_factory = make_collecting_sink({}, {
			begin_err = 'sink_begin_failed',
		}),
	})

	local ok, err = mgr:handle_incoming(good_begin('first'))
	assert(ok == true, tostring(err))

	assert(#sent == 1, 'expected one xfer_ready reply')
	assert(sent[1].t == 'xfer_ready')
	assert(sent[1].ok == false)
	assert(sent[1].err == 'sink_begin_failed')
end

function T.transfer_aborts_when_sink_write_fails()
	runfibers.run(function()
		local received = {}

		local left, right = make_pair({
			state        = received,
			sink_factory = make_collecting_sink(received, {
				write_err = 'disk_full',
			}),
		})

		local id, err = start_basic_send(left, 'hello-transfer')
		assert(id ~= nil, tostring(err))

		local ok = wait_until(function()
			local st = left:status(id)
			return st ~= nil and st.status == 'aborted'
		end, { timeout = 1.0, interval = 0.01 })
		assert(ok == true, 'expected sender to abort')

		local lst = assert(left:status(id))
		local rst = assert(right:status(id))

		assert(lst.status == 'aborted')
		assert(rst.status == 'aborted')

		-- Current behaviour:
		--   * receiver abort reason is the local sink failure
		--   * sender sees the protocol consequence on resend
		assert(tostring(lst.err):match('no such incoming transfer'),
			'expected sender-side protocol failure, got: ' .. tostring(lst.err))
		assert(tostring(rst.err):match('disk_full'),
			'expected receiver-side sink failure, got: ' .. tostring(rst.err))
		assert(received.abort_reason == 'disk_full')
	end, { timeout = 1.5 })
end

function T.transfer_retries_after_receiver_requests_same_chunk_again()
	runfibers.run(function()
		local received = { bytes = nil }
		local injected_bad_crc = false
		local seq0_sends = 0

		local left, right = make_pair({
			state        = received,
			left_chunk_raw = 4,
			sink_factory = make_collecting_sink(received),
			left_send = function(msg, _left, right_mgr)
				if msg.t == 'xfer_chunk' and msg.seq == 0 then
					seq0_sends = seq0_sends + 1

					if not injected_bad_crc then
						injected_bad_crc = true

						local bad = shallow_copy(msg)
						bad.crc32 = '00000000'

						local ok, err = right_mgr:handle_incoming(bad)
						if ok ~= true then return nil, err end
						return true, nil
					end
				end

				local ok, err = right_mgr:handle_incoming(msg)
				if ok ~= true then return nil, err end
				return true, nil
			end,
		})

		local id, err = start_basic_send(left, 'abcdefghij')
		assert(id ~= nil, tostring(err))

		local ok = wait_until(function()
			local st = left:status(id)
			return st ~= nil and st.status == 'done' and received.bytes == 'abcdefghij'
		end, { timeout = 1.0, interval = 0.01 })
		assert(ok == true, 'expected transfer to complete after resend')

		local st = assert(left:status(id))
		assert(st.status == 'done')
		assert(received.bytes == 'abcdefghij')
		assert(seq0_sends >= 2, 'expected first chunk to be retried')
	end, { timeout = 1.5 })
end

function T.transfer_aborts_on_sha256_mismatch_at_commit()
	runfibers.run(function()
		local received = {}
		local left, right = make_pair({
			state        = received,
			sink_factory = make_collecting_sink(received, {
				sha256hex = function()
					return string.rep('0', 64)
				end,
			}),
		})

		local id, err = start_basic_send(left, 'hello-transfer')
		assert(id ~= nil, tostring(err))

		local ok = wait_until(function()
			local st = left:status(id)
			return st ~= nil and st.status == 'aborted'
		end, { timeout = 1.0, interval = 0.01 })
		assert(ok == true, 'expected sender to abort on commit hash mismatch')

		local lst = assert(left:status(id))
		local rst = assert(right:status(id))

		assert(lst.status == 'aborted')
		assert(rst.status == 'aborted')
		assert(tostring(lst.err):match('sha256_mismatch'))
		assert(tostring(rst.err):match('sha256_mismatch'))
		assert(received.abort_reason == 'sha256_mismatch')
	end, { timeout = 1.5 })
end

function T.transfer_aborts_on_commit_size_mismatch()
	runfibers.run(function()
		local received = {}

		local left, right = make_pair({
			state        = received,
			sink_factory = make_collecting_sink(received),
			left_send = function(msg, _left, right_mgr)
				if msg.t == 'xfer_commit' then
					local tampered = shallow_copy(msg)
					tampered.size = tampered.size + 1
					local ok, err = right_mgr:handle_incoming(tampered)
					if ok ~= true then return nil, err end
					return true, nil
				end

				local ok, err = right_mgr:handle_incoming(msg)
				if ok ~= true then return nil, err end
				return true, nil
			end,
		})

		local id, err = start_basic_send(left, 'hello-transfer')
		assert(id ~= nil, tostring(err))

		local ok = wait_until(function()
			local st = left:status(id)
			return st ~= nil and st.status == 'aborted'
		end, { timeout = 1.0, interval = 0.01 })
		assert(ok == true, 'expected sender to abort on size mismatch')

		local lst = assert(left:status(id))
		local rst = assert(right:status(id))

		assert(lst.status == 'aborted')
		assert(rst.status == 'aborted')
		assert(tostring(lst.err):match('size_mismatch'))
		assert(tostring(rst.err):match('size_mismatch'))
	end, { timeout = 1.5 })
end

function T.transfer_aborts_when_ready_times_out()
	runfibers.run(function()
		local left = transfer.new({
			svc           = make_svc(),
			conn          = make_stub_conn(),
			link_id       = 'left',
			peer_id       = 'right',
			ack_timeout_s = 0.1,
			max_retries   = 2,
			send_frame    = function()
				return true, nil
			end,
		})

		local id, err = start_basic_send(left, 'hello-transfer')
		assert(id ~= nil, tostring(err))

		local ok = wait_until(function()
			local st = left:status(id)
			return st ~= nil and st.status == 'aborted'
		end, { timeout = 1.0, interval = 0.01 })
		assert(ok == true, 'expected sender to abort on ready timeout')

		local st = assert(left:status(id))
		assert(st.status == 'aborted')
		assert(st.err == 'ready_timeout', 'expected ready_timeout, got: ' .. tostring(st.err))
	end, { timeout = 1.5 })
end

function T.transfer_aborts_when_chunk_ack_times_out()
	runfibers.run(function()
		local received = {}

		local left, right = make_pair({
			state             = received,
			left_ack_timeout_s = 0.1,
			left_max_retries   = 2,
			sink_factory      = make_collecting_sink(received),
			right_send = function(msg, left_mgr, _right_mgr)
				if msg.t == 'xfer_need' then
					return true, nil
				end

				local ok, err = left_mgr:handle_incoming(msg)
				if ok ~= true then return nil, err end
				return true, nil
			end,
		})

		local id, err = start_basic_send(left, 'hello-transfer')
		assert(id ~= nil, tostring(err))

		local ok = wait_until(function()
			local st = left:status(id)
			return st ~= nil and st.status == 'aborted'
		end, { timeout = 1.0, interval = 0.01 })
		assert(ok == true, 'expected sender to abort on chunk ack timeout')

		local lst = assert(left:status(id))
		local rst = assert(right:status(id))

		assert(lst.status == 'aborted')
		assert(rst.status == 'aborted')
		assert(lst.err == 'chunk_ack_timeout', 'expected chunk_ack_timeout, got: ' .. tostring(lst.err))
	end, { timeout = 1.5 })
end

function T.transfer_aborts_when_commit_reply_times_out()
	runfibers.run(function()
		local received = {}
		local commit_seen = 0

		local left, right = make_pair({
			state             = received,
			left_ack_timeout_s = 0.1,
			left_max_retries   = 2,
			sink_factory      = make_collecting_sink(received),

			-- Deliver the first commit so the receiver finalises successfully,
			-- then swallow later commit retries so we test sender commit timeout
			-- rather than receiver non-idempotence.
			left_send = function(msg, _left_mgr, right_mgr)
				if msg.t == 'xfer_commit' then
					commit_seen = commit_seen + 1

					if commit_seen == 1 then
						local ok, err = right_mgr:handle_incoming(msg)
						if ok ~= true then return nil, err end
						return true, nil
					end

					return true, nil
				end

				local ok, err = right_mgr:handle_incoming(msg)
				if ok ~= true then return nil, err end
				return true, nil
			end,

			-- Swallow xfer_done replies back to the sender.
			right_send = function(msg, left_mgr, _right_mgr)
				if msg.t == 'xfer_done' then
					return true, nil
				end

				local ok, err = left_mgr:handle_incoming(msg)
				if ok ~= true then return nil, err end
				return true, nil
			end,
		})

		local id, err = start_basic_send(left, 'hello-transfer')
		assert(id ~= nil, tostring(err))

		local ok = wait_until(function()
			local st = left:status(id)
			return st ~= nil and st.status == 'aborted'
		end, { timeout = 1.0, interval = 0.01 })
		assert(ok == true, 'expected sender to abort on commit timeout')

		local lst = assert(left:status(id))
		local rst = assert(right:status(id))

		assert(lst.status == 'aborted')
		assert(rst.status == 'done')
		assert(lst.err == 'commit_timeout', 'expected commit_timeout, got: ' .. tostring(lst.err))
	end, { timeout = 1.5 })
end

function T.transfer_abort_api_stops_active_outgoing_transfer()
	runfibers.run(function()
		local left = transfer.new({
			svc           = make_svc(),
			conn          = make_stub_conn(),
			link_id       = 'left',
			peer_id       = 'right',
			ack_timeout_s = 0.2,
			max_retries   = 2,
			send_frame    = function()
				return true, nil
			end,
		})

		local id, err = start_basic_send(left, 'hello-transfer')
		assert(id ~= nil, tostring(err))

		local ok_abort, aerr = left:abort(id, 'cancelled_by_test')
		assert(ok_abort == true, tostring(aerr))

		local st = assert(left:status(id))
		assert(st.status == 'aborted')
		assert(st.err == 'cancelled_by_test')

		-- Give the sender worker a moment to observe the closed control mailbox
		-- and exit, so the simple runner does not time out.
		fibers.perform(sleep.sleep_op(0.05))
	end, { timeout = 1.5 })
end

function T.transfer_abort_api_stops_active_incoming_transfer()
	local state = {}

	local mgr = transfer.new({
		svc        = make_svc(),
		conn       = make_stub_conn(),
		link_id    = 'right',
		peer_id    = 'left',
		send_frame = function()
			return true, nil
		end,
		sink_factory = make_collecting_sink(state),
	})

	local ok1, err1 = mgr:handle_incoming(good_begin('incoming-1'))
	assert(ok1 == true, tostring(err1))

	local ok2, err2 = mgr:abort('incoming-1', 'cancelled_by_test')
	assert(ok2 == true, tostring(err2))

	local st = assert(mgr:status('incoming-1'))
	assert(st.status == 'aborted')
	assert(st.err == 'cancelled_by_test')
	assert(state.abort_reason == 'cancelled_by_test')
end

function T.transfer_reports_error_for_unknown_incoming_transfer_messages()
	local mgr = transfer.new({
		svc        = make_svc(),
		conn       = make_stub_conn(),
		link_id    = 'right',
		peer_id    = 'left',
		send_frame = function()
			return true, nil
		end,
	})

	do
		local ok, err = mgr:handle_incoming(protocol.xfer_chunk('missing', 0, 0, 1, '00', 'AA'))
		assert(ok == false, 'expected false for unknown xfer_chunk')
		assert(err == 'no such incoming transfer')
	end

	do
		local ok, err = mgr:handle_incoming(protocol.xfer_commit('missing', 1, string.rep('a', 64)))
		assert(ok == false, 'expected false for unknown xfer_commit')
		assert(err == 'no such incoming transfer')
	end

	do
		local ok, err = mgr:handle_incoming(protocol.xfer_abort('missing', 'cancelled'))
		assert(ok == false, 'expected false for unknown xfer_abort')
		assert(err == 'no such incoming transfer')
	end
end

function T.transfer_status_reports_unknown_transfer()
	local mgr = transfer.new({
		svc        = make_svc(),
		conn       = make_stub_conn(),
		link_id    = 'left',
		peer_id    = 'right',
		send_frame = function()
			return true, nil
		end,
	})

	local st, err = mgr:status('missing-transfer-id')

	assert(st == nil, 'expected nil status for unknown transfer')
	assert(err == 'unknown transfer', 'expected "unknown transfer", got: ' .. tostring(err))
end

return T
