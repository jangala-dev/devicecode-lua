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
			sink_factory = function(meta)
				local parts = {}
				return {
					begin = function() return true end,
					write = function(_, seq, off, raw)
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
		local id, err = left:start_send(src, { kind = 'firmware', name = 'fw.bin', format = 'bin' })
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

return T
