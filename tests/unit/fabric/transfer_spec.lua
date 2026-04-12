local busmod      = require 'bus'
local blob_source = require 'services.fabric.blob_source'
local checksum    = require 'services.fabric.checksum'
local transfer    = require 'services.fabric.transfer'

local runfibers   = require 'tests.support.run_fibers'
local probe       = require 'tests.support.bus_probe'

local T = {}

local function make_svc()
	return {
		now = function(self)
			return require('fibers').now()
		end,
		wall = function(self)
			return 'now'
		end,
		obs_event = function() end,
	}
end

function T.transfer_round_trips_blob_between_two_managers()
	runfibers.run(function()
		local bus = busmod.new()
		local conn = bus:connect()

		local received = {
			bytes = nil,
			meta = nil,
		}

		local left, right

		left = transfer.new({
			svc = make_svc(),
			conn = conn,
			link_id = 'left',
			peer_id = 'right',
			send_frame = function(msg)
				local ok, err = right:handle_incoming(msg)
				if ok ~= true then return nil, err end
				return true, nil
			end,
		})

		right = transfer.new({
			svc = make_svc(),
			conn = conn,
			link_id = 'right',
			peer_id = 'left',
			send_frame = function(msg)
				local ok, err = left:handle_incoming(msg)
				if ok ~= true then return nil, err end
				return true, nil
			end,
			sink_factory = function(_meta)
				local parts = {}
				return {
					begin = function() return true end,
					write = function(_, _seq, _off, raw)
						parts[#parts + 1] = raw
						return true
					end,
					sha256hex = function()
						return checksum.sha256_hex(table.concat(parts))
					end,
					commit = function(_, info)
						received.bytes = table.concat(parts)
						received.meta = info
						return { stored = true }, nil
					end,
					abort = function() return true end,
				}
			end,
		})

		local src = blob_source.from_string('fw.bin', 'hello-transfer', { format = 'bin' })
		local id, err = left:start_send(src, {
			kind = 'firmware',
			name = 'fw.bin',
			format = 'bin',
		})
		assert(id ~= nil, tostring(err))

		local ok = probe.wait_until(function()
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
		local bus = busmod.new()
		local conn = bus:connect()

		local left, right

		left = transfer.new({
			svc = make_svc(),
			conn = conn,
			link_id = 'left',
			peer_id = 'right',
			send_frame = function(msg)
				local ok, err = right:handle_incoming(msg)
				if ok ~= true then return nil, err end
				return true, nil
			end,
			ack_timeout_s = 0.1,
			max_retries = 2,
		})

		right = transfer.new({
			svc = make_svc(),
			conn = conn,
			link_id = 'right',
			peer_id = 'left',
			send_frame = function(msg)
				local ok, err = left:handle_incoming(msg)
				if ok ~= true then return nil, err end
				return true, nil
			end,
		})

		local src = blob_source.from_string('fw.bin', 'x', { format = 'bin' })
		local id, err = left:start_send(src, {
			kind = 'firmware',
			name = 'fw.bin',
			format = 'bin',
		})
		assert(id ~= nil, tostring(err))

		local ok = probe.wait_until(function()
			local st = left:status(id)
			return st ~= nil and st.status == 'aborted'
		end, { timeout = 1.0, interval = 0.01 })
		assert(ok == true, 'expected transfer to abort')

		local st = assert(left:status(id))
		assert(tostring(st.err):match('unsupported'))
	end, { timeout = 1.0 })
end

function T.transfer_retries_after_receiver_requests_same_chunk_again()
	runfibers.run(function()
		local bus = busmod.new()
		local conn = bus:connect()

		local received = { bytes = nil }
		local injected_bad_crc = false
		local seq0_sends = 0

		local left, right

		left = transfer.new({
			svc = make_svc(),
			conn = conn,
			link_id = 'left',
			peer_id = 'right',
			chunk_raw = 4,
			send_frame = function(msg)
				if msg.t == 'xfer_chunk' and msg.seq == 0 then
					seq0_sends = seq0_sends + 1

					if not injected_bad_crc then
						injected_bad_crc = true

						local bad = {}
						for k, v in pairs(msg) do bad[k] = v end
						bad.crc32 = '00000000'

						local ok, err = right:handle_incoming(bad)
						if ok ~= true then return nil, err end
						return true, nil
					end
				end

				local ok, err = right:handle_incoming(msg)
				if ok ~= true then return nil, err end
				return true, nil
			end,
		})

		right = transfer.new({
			svc = make_svc(),
			conn = conn,
			link_id = 'right',
			peer_id = 'left',
			send_frame = function(msg)
				local ok, err = left:handle_incoming(msg)
				if ok ~= true then return nil, err end
				return true, nil
			end,
			sink_factory = function(_meta)
				local parts = {}
				return {
					begin = function() return true end,
					write = function(_, _seq, _off, raw)
						parts[#parts + 1] = raw
						return true
					end,
					sha256hex = function()
						return checksum.sha256_hex(table.concat(parts))
					end,
					commit = function()
						received.bytes = table.concat(parts)
						return { stored = true }, nil
					end,
					abort = function() return true end,
				}
			end,
		})

		local src = blob_source.from_string('fw.bin', 'abcdefghij', { format = 'bin' })
		local id, err = left:start_send(src, {
			kind = 'firmware',
			name = 'fw.bin',
			format = 'bin',
		})
		assert(id ~= nil, tostring(err))

		local ok = probe.wait_until(function()
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
		local bus = busmod.new()
		local conn = bus:connect()

		local aborted_reason = nil

		local left, right

		left = transfer.new({
			svc = make_svc(),
			conn = conn,
			link_id = 'left',
			peer_id = 'right',
			send_frame = function(msg)
				local ok, err = right:handle_incoming(msg)
				if ok ~= true then return nil, err end
				return true, nil
			end,
		})

		right = transfer.new({
			svc = make_svc(),
			conn = conn,
			link_id = 'right',
			peer_id = 'left',
			send_frame = function(msg)
				local ok, err = left:handle_incoming(msg)
				if ok ~= true then return nil, err end
				return true, nil
			end,
			sink_factory = function(_meta)
				local parts = {}
				return {
					begin = function() return true end,
					write = function(_, _seq, _off, raw)
						parts[#parts + 1] = raw
						return true
					end,
					sha256hex = function()
						return string.rep('0', 64)
					end,
					commit = function()
						return { stored = true }, nil
					end,
					abort = function(_, reason)
						aborted_reason = reason
						return true
					end,
				}
			end,
		})

		local src = blob_source.from_string('fw.bin', 'hello-transfer', { format = 'bin' })
		local id, err = left:start_send(src, {
			kind = 'firmware',
			name = 'fw.bin',
			format = 'bin',
		})
		assert(id ~= nil, tostring(err))

		local ok = probe.wait_until(function()
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
		assert(aborted_reason == 'sha256_mismatch')
	end, { timeout = 1.5 })
end


local function stub_conn()
	return {
		retain = function()
			return true
		end,
	}
end

function T.transfer_status_reports_unknown_transfer()
	local mgr = transfer.new({
		svc = make_svc(),
		conn = stub_conn(),
		link_id = 'left',
		peer_id = 'right',
		send_frame = function()
			return true, nil
		end,
	})

	local st, err = mgr:status('missing-transfer-id')

	assert(st == nil, 'expected nil status for unknown transfer')
	assert(err == 'unknown transfer', 'expected "unknown transfer", got: ' .. tostring(err))
end

return T
