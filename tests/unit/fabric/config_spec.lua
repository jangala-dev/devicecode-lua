local cfg = require 'services.fabric.config'

local T = {}

function T.normalise_accepts_uart_serial_ref()
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

function T.normalise_preserves_keepalive()
	local out, err = cfg.normalise({
		schema = 'devicecode.fabric/1',
		links = {
			mcu0 = {
				peer_id = 'mcu-1',
				transport = {
					kind       = 'uart',
					serial_ref = 'uart-0',
				},
				keepalive = {
					hello_retry_s = 1.0,
					idle_ping_s = 12.5,
					stale_after_s = 30.0,
				},
			},
		},
	})

	assert(out ~= nil, tostring(err))
	assert(type(out.links.mcu0.keepalive) == 'table')
	assert(out.links.mcu0.keepalive.hello_retry_s == 1.0)
	assert(out.links.mcu0.keepalive.idle_ping_s == 12.5)
	assert(out.links.mcu0.keepalive.stale_after_s == 30.0)
end

return T
