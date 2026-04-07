-- tests/unit/fabric/transfer_spec.lua

local blob_source = require 'services.fabric.blob_source'
local checksum    = require 'services.fabric.checksum'
local protocol    = require 'services.fabric.protocol'
local transfer    = require 'services.fabric.transfer'

local runfibers = require 'tests.support.run_fibers'
local probe     = require 'tests.support.bus_probe'

local T = {}

local function fake_conn()
	local retained = {}

	local conn = {}

	function conn:retain(topic, payload)
		retained[#retained + 1] = {
			topic   = topic,
			payload = payload,
		}
		return true
	end

	function conn:retained()
		return retained
	end

	return conn
end

local function fake_svc()
	local t = 0

	return {
		now = function(self)
			t = t + 0.001
			return t
		end,
		wall = function()
			return '2026-01-01 00:00:00'
		end,
		obs_event = function(...) end,
	}
end

function T.start_send_completes_stop_and_wait()
	runfibers.run(function()
		local conn = fake_conn()
		local svc  = fake_svc()

		local seen = {
			begin  = 0,
			chunk  = 0,
			commit = 0,
		}

		local xfer
		xfer = transfer.new({
			svc       = svc,
			conn      = conn,
			link_id   = 'mcu0',
			peer_id   = 'mcu-1',
			chunk_raw = 4,
			send_frame = function(msg)
				if msg.t == 'xfer_begin' then
					seen.begin = seen.begin + 1
					local ok, err = xfer:handle_incoming(protocol.xfer_ready(msg.id, true, 0, nil))
					assert(ok == true, tostring(err))
				elseif msg.t == 'xfer_chunk' then
					seen.chunk = seen.chunk + 1
					local ok, err = xfer:handle_incoming(protocol.xfer_need(msg.id, msg.seq + 1, nil))
					assert(ok == true, tostring(err))
				elseif msg.t == 'xfer_commit' then
					seen.commit = seen.commit + 1
					local ok, err = xfer:handle_incoming(protocol.xfer_done(msg.id, true, {
						accepted = true,
					}, nil))
					assert(ok == true, tostring(err))
				elseif msg.t == 'xfer_abort' then
					error('unexpected xfer_abort: ' .. tostring(msg.reason))
				else
					error('unexpected message type: ' .. tostring(msg.t))
				end
				return true, nil
			end,
		})

		local src = blob_source.from_string('fw.bin', 'abcdefghij', {
			format = 'bin',
		})

		local id, err = xfer:start_send(src, {
			kind   = 'firmware.rp2350',
			format = 'bin',
			name   = 'fw.bin',
		})
		assert(id ~= nil, tostring(err))

		local ok = probe.wait_until(function()
			local st = xfer:status(id)
			return st and st.status == 'done'
		end, { timeout = 1.0, interval = 0.01 })

		assert(ok == true, 'expected outgoing transfer to finish')

		local st, serr = xfer:status(id)
		assert(st ~= nil, tostring(serr))
		assert(st.status == 'done')
		assert(st.dir == 'out')
		assert(st.name == 'fw.bin')
		assert(st.size == 10)
		assert(st.chunks == 3)
		assert(st.bytes_done == 10)
		assert(st.chunks_done == 3)
		assert(type(st.info) == 'table')
		assert(st.info.accepted == true)

		assert(seen.begin == 1)
		assert(seen.chunk == 3)
		assert(seen.commit == 1)
	end, { timeout = 2.0 })
end

function T.handle_incoming_rejects_begin_without_sink_factory()
	local conn = fake_conn()
	local svc  = fake_svc()
	local last = nil

	local xfer = transfer.new({
		svc       = svc,
		conn      = conn,
		link_id   = 'mcu0',
		peer_id   = 'mcu-1',
		send_frame = function(msg)
			last = msg
			return true, nil
		end,
	})

	local ok, err = xfer:handle_incoming(protocol.xfer_begin(
		'xfer-in-1',
		'firmware.rp2350',
		'rx.uf2',
		'uf2',
		'b64url',
		3,
		3,
		1,
		checksum.sha256_hex('abc'),
		nil
	))
	assert(ok == true, tostring(err))

	assert(type(last) == 'table')
	assert(last.t == 'xfer_ready')
	assert(last.id == 'xfer-in-1')
	assert(last.ok == false)
	assert(last.err == 'unsupported')
end

function T.handle_incoming_accepts_chunks_and_commits_with_sink()
	local conn = fake_conn()
	local svc  = fake_svc()
	local sent = {}

	local sink = {
		buf = {},
		begin_calls = 0,
		write_calls = 0,
		commit_calls = 0,
	}

	function sink:begin(meta)
		self.begin_calls = self.begin_calls + 1
		self.meta = meta
		return true, nil
	end

	function sink:write(seq, off, bytes)
		self.write_calls = self.write_calls + 1
		self.buf[#self.buf + 1] = bytes
		self.last_seq = seq
		self.last_off = off
		return true, nil
	end

	function sink:sha256hex()
		return checksum.sha256_hex(table.concat(self.buf))
	end

	function sink:commit(meta)
		self.commit_calls = self.commit_calls + 1
		self.commit_meta = meta
		return {
			staged = true,
			bytes = #table.concat(self.buf),
		}, nil
	end

	function sink:abort(reason)
		self.abort_reason = reason
		return true
	end

	local xfer = transfer.new({
		svc         = svc,
		conn        = conn,
		link_id     = 'mcu0',
		peer_id     = 'mcu-1',
		sink_factory = function(meta)
			assert(meta.id == 'xfer-in-2')
			assert(meta.kind == 'firmware.rp2350')
			assert(meta.format == 'uf2')
			return sink, nil
		end,
		send_frame = function(msg)
			sent[#sent + 1] = msg
			return true, nil
		end,
	})

	local raw = 'abc'
	local ok, err = xfer:handle_incoming(protocol.xfer_begin(
		'xfer-in-2',
		'firmware.rp2350',
		'rx.uf2',
		'uf2',
		'b64url',
		#raw,
		#raw,
		1,
		checksum.sha256_hex(raw),
		{ slot = 'ota0' }
	))
	assert(ok == true, tostring(err))
	assert(sent[#sent].t == 'xfer_ready')
	assert(sent[#sent].ok == true)

	ok, err = xfer:handle_incoming(protocol.xfer_chunk(
		'xfer-in-2',
		0,
		0,
		#raw,
		checksum.crc32_hex(raw),
		require('services.fabric.b64url').encode(raw)
	))
	assert(ok == true, tostring(err))
	assert(sent[#sent].t == 'xfer_need')
	assert(sent[#sent].next == 1)

	ok, err = xfer:handle_incoming(protocol.xfer_commit(
		'xfer-in-2',
		#raw,
		checksum.sha256_hex(raw)
	))
	assert(ok == true, tostring(err))
	assert(sent[#sent].t == 'xfer_done')
	assert(sent[#sent].ok == true)
	assert(type(sent[#sent].info) == 'table')
	assert(sent[#sent].info.staged == true)

	assert(sink.begin_calls == 1)
	assert(sink.write_calls == 1)
	assert(sink.commit_calls == 1)
	assert(table.concat(sink.buf) == raw)

	local st, serr = xfer:status('xfer-in-2')
	assert(st ~= nil, tostring(serr))
	assert(st.status == 'done')
	assert(st.dir == 'in')
	assert(st.bytes_done == #raw)
	assert(st.chunks_done == 1)
end

return T
