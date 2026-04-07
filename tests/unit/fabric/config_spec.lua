-- tests/unit/fabric/config_spec.lua

local cfg = require 'services.fabric.config'

local T = {}

function T.normalise_accepts_uart_serial_ref_and_transfer_defaults()
	local out, err = cfg.normalise({
		schema = 'devicecode.fabric/1',
		links = {
			mcu0 = {
				peer_id = 'mcu-1',
				transport = {
					kind       = 'uart',
					serial_ref = 'uart-0',
				},
				export = {
					publish = {
						{
							src    = { 'config', 'mcu' },
							dst    = { 'config', 'device' },
							retain = true,
						},
					},
				},
				import = {
					publish = {
						{
							src    = { 'state', '#' },
							dst    = { 'peer', 'mcu-1', 'state', '#' },
							retain = true,
						},
					},
					call = {
						{
							src       = { 'rpc', 'hal', 'read_state' },
							dst       = { 'rpc', 'hal', 'read_state' },
							timeout_s = 5.0,
						},
					},
				},
				proxy_calls = {
					{
						src       = { 'rpc', 'peer', 'mcu-1', 'hal', 'dump' },
						dst       = { 'rpc', 'hal', 'dump' },
						timeout_s = 5.0,
					},
				},
			},
		},
	})

	assert(out ~= nil, tostring(err))
	assert(out.link_count == 1)
	assert(out.links.mcu0.transport.kind == 'uart')
	assert(out.links.mcu0.transport.serial_ref == 'uart-0')

	assert(type(out.links.mcu0.transfer) == 'table')
	assert(out.links.mcu0.transfer.chunk_raw == 768)
	assert(out.links.mcu0.transfer.ack_timeout_s == 2.0)
	assert(out.links.mcu0.transfer.max_retries == 5)
end

function T.normalise_accepts_uart_max_line_bytes_and_transfer_overrides()
	local out, err = cfg.normalise({
		schema = 'devicecode.fabric/1',
		links = {
			mcu0 = {
				peer_id = 'mcu-1',
				transport = {
					kind           = 'uart',
					serial_ref     = 'uart-0',
					max_line_bytes = 8192,
				},
				transfer = {
					chunk_raw     = 1024,
					ack_timeout_s = 1.5,
					max_retries   = 7,
				},
			},
		},
	})

	assert(out ~= nil, tostring(err))
	assert(out.links.mcu0.transport.max_line_bytes == 8192)

	assert(type(out.links.mcu0.transfer) == 'table')
	assert(out.links.mcu0.transfer.chunk_raw == 1024)
	assert(out.links.mcu0.transfer.ack_timeout_s == 1.5)
	assert(out.links.mcu0.transfer.max_retries == 7)
end

function T.normalise_rejects_missing_uart_serial_ref()
	local out, err = cfg.normalise({
		schema = 'devicecode.fabric/1',
		links = {
			mcu0 = {
				peer_id = 'mcu-1',
				transport = {
					kind = 'uart',
				},
			},
		},
	})

	assert(out == nil)
	assert(type(err) == 'string')
	assert(err:find('serial_ref', 1, true) ~= nil)
end

function T.normalise_rejects_bad_transfer_chunk_raw()
	local out, err = cfg.normalise({
		schema = 'devicecode.fabric/1',
		links = {
			mcu0 = {
				peer_id = 'mcu-1',
				transport = {
					kind       = 'uart',
					serial_ref = 'uart-0',
				},
				transfer = {
					chunk_raw = 0,
				},
			},
		},
	})

	assert(out == nil)
	assert(type(err) == 'string')
	assert(err:find('chunk_raw', 1, true) ~= nil)
end

function T.normalise_rejects_bad_transfer_ack_timeout()
	local out, err = cfg.normalise({
		schema = 'devicecode.fabric/1',
		links = {
			mcu0 = {
				peer_id = 'mcu-1',
				transport = {
					kind       = 'uart',
					serial_ref = 'uart-0',
				},
				transfer = {
					ack_timeout_s = -1,
				},
			},
		},
	})

	assert(out == nil)
	assert(type(err) == 'string')
	assert(err:find('ack_timeout_s', 1, true) ~= nil)
end

function T.normalise_rejects_bad_transfer_max_retries()
	local out, err = cfg.normalise({
		schema = 'devicecode.fabric/1',
		links = {
			mcu0 = {
				peer_id = 'mcu-1',
				transport = {
					kind       = 'uart',
					serial_ref = 'uart-0',
				},
				transfer = {
					max_retries = 0,
				},
			},
		},
	})

	assert(out == nil)
	assert(type(err) == 'string')
	assert(err:find('max_retries', 1, true) ~= nil)
end

function T.normalise_rejects_wild_proxy_call_topic()
	local out, err = cfg.normalise({
		schema = 'devicecode.fabric/1',
		links = {
			mcu0 = {
				peer_id = 'mcu-1',
				transport = {
					kind       = 'uart',
					serial_ref = 'uart-0',
				},
				proxy_calls = {
					{
						src = { 'rpc', 'peer', '+', 'hal', 'dump' },
						dst = { 'rpc', 'hal', 'dump' },
					},
				},
			},
		},
	})

	assert(out == nil)
	assert(type(err) == 'string')
	assert(err:find('concrete', 1, true) ~= nil)
end

return T
