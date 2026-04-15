local config = require 'services.fabric.config'

local T = {}

function T.normalise_accepts_minimal_uart_link_and_fills_defaults()
	local cfg, err = config.normalise({
		schema = 'devicecode.fabric/1',
		links = {
			uart0 = {
				peer_id = 'peer-a',
				transport = {
					kind = 'uart',
					cap_id = 'uart0',
				},
			},
		},
	})

	assert(cfg ~= nil, tostring(err))
	assert(cfg.link_count == 1)
	assert(cfg.links.uart0.peer_id == 'peer-a')
	assert(cfg.links.uart0.transport.kind == 'uart')
	assert(cfg.links.uart0.transport.cap_id == 'uart0')
	assert(cfg.links.uart0.transport.open_timeout_s == 30.0)
	assert(cfg.links.uart0.transfer.chunk_raw == 768)
	assert(cfg.links.uart0.transfer.ack_timeout_s == 2.0)
	assert(cfg.links.uart0.transfer.max_retries == 5)
	assert(cfg.links.uart0.transfer.chunk_gap_s == 0.0)
	assert(cfg.links.uart0.transfer.retry_gap_s == 0.0)
end

function T.normalise_preserves_transfer_pacing_overrides()
	local cfg, err = config.normalise({
		schema = 'devicecode.fabric/1',
		links = {
			uart0 = {
				peer_id = 'peer-a',
				transport = {
					kind = 'uart',
					cap_id = 'uart0',
				},
				transfer = {
					chunk_gap_s = 0.25,
					retry_gap_s = 0.5,
				},
			},
		},
	})

	assert(cfg ~= nil, tostring(err))
	assert(cfg.links.uart0.transfer.chunk_gap_s == 0.25)
	assert(cfg.links.uart0.transfer.retry_gap_s == 0.5)
end

function T.normalise_rejects_negative_chunk_gap_s()
	local cfg, err = config.normalise({
		schema = 'devicecode.fabric/1',
		links = {
			uart0 = {
				peer_id = 'peer-a',
				transport = {
					kind = 'uart',
					cap_id = 'uart0',
				},
				transfer = {
					chunk_gap_s = -0.1,
				},
			},
		},
	})

	assert(cfg == nil)
	assert(tostring(err):match('chunk_gap_s'))
end

function T.normalise_rejects_negative_retry_gap_s()
	local cfg, err = config.normalise({
		schema = 'devicecode.fabric/1',
		links = {
			uart0 = {
				peer_id = 'peer-a',
				transport = {
					kind = 'uart',
					cap_id = 'uart0',
				},
				transfer = {
					retry_gap_s = -0.1,
				},
			},
		},
	})

	assert(cfg == nil)
	assert(tostring(err):match('retry_gap_s'))
end

function T.normalise_rejects_wildcards_in_proxy_call_topics()
	local cfg, err = config.normalise({
		schema = 'devicecode.fabric/1',
		links = {
			uart0 = {
				peer_id = 'peer-a',
				transport = {
					kind = 'uart',
					cap_id = 'uart0',
				},
				proxy_calls = {
					{
						src = { 'rpc', '+', 'echo' },
						dst = { 'rpc', 'remote', 'echo' },
					},
				},
			},
		},
	})

	assert(cfg == nil)
	assert(tostring(err):match('concrete topic'))
end

function T.normalise_rejects_bad_transfer_values()
	local cfg, err = config.normalise({
		schema = 'devicecode.fabric/1',
		links = {
			uart0 = {
				peer_id = 'peer-a',
				transport = {
					kind = 'uart',
					cap_id = 'uart0',
				},
				transfer = {
					chunk_raw = 0,
				},
			},
		},
	})

	assert(cfg == nil)
	assert(tostring(err):match('chunk_raw'))
end

return T
