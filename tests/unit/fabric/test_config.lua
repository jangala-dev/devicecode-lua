local cfg = require 'services.fabric.config'

local T = {}

function T.compile_builds_canonical_runtime_plan()
	local compiled, err = cfg.compile({
		schema = 'devicecode.config/fabric/1',
		local_node = 'host-a',
		links = {
			{
				id = 'uart0',
				peer_id = 'peer-main',
				transport = {
					kind = 'uart',
					source = 'uart',
					id = 'main',
					terminator = '\n',
					open_opts = { baud = 115200 },
				},
				session = {
					hello_interval_s = 1.5,
					rehello_after_s = 6.5,
					identity_claim = { id = 'host-a' },
					auth_claim = nil,
				},
				bridge = {
					max_pending_calls = 9,
					max_inbound_calls = 7,
					call_timeout_s = 4.5,
					imports = {
						{
							id = 'import-state',
							['local'] = { 'raw', 'member', 'peer', 'state' },
							['remote'] = { 'state' },
						},
					},
					exports = {
						{
							id = 'export-cfg',
							['local'] = { 'cfg', 'member', 'peer' },
							['remote'] = { 'cfg' },
							publish = true,
							retain = true,
						},
					},
					rpc = {
						outbound = {
							{
								id = 'cap-out',
								['local'] = { 'cap', 'component', 'peer' },
								['remote'] = { 'cap', 'component', 'peer' },
								timeout_s = 2.0,
							},
						},
						inbound = {
							{
								id = 'diag-in',
								['local'] = { 'cap', 'diag' },
								['remote'] = { 'cap', 'diag' },
							},
						},
					},
				},
				transfer = {
					chunk_size = 8192,
					timeout_s = 22.0,
					xfer_begin_retry_s = 1.25,
				},
			},
		},
	})

	assert(compiled ~= nil, tostring(err))
	assert(compiled.service.local_node == 'host-a')
	assert(#compiled.links == 1)

	local link = compiled.links[1]
	assert(link.link_id == 'uart0')
	assert(link.peer_id == 'peer-main')

	assert(link.transport.kind == 'uart')
	assert(link.transport.class == 'uart')
	assert(link.transport.id == 'main')
	assert(link.transport.open_opts.baud == 115200)

	assert(link.session.local_node == 'host-a')
	assert(link.session.hello_interval_s == 1.5)
	assert(link.session.rehello_after_s == 6.5)
	assert(link.session.ping_interval_s == cfg.DEFAULTS.session.ping_interval_s)
	assert(link.session.identity_claim.id == 'host-a')

	assert(#link.bridge.import_rules == 1)
	assert(#link.bridge.export_publish_rules == 1)
	assert(#link.bridge.export_retained_rules == 1)
	assert(#link.bridge.outbound_call_rules == 1)
	assert(#link.bridge.inbound_call_rules == 1)
	assert(link.bridge.outbound_call_rules[1].local_topic[1] == 'cap')
	assert(link.bridge.outbound_call_rules[1].remote_topic[1] == 'cap')
	assert(link.bridge.outbound_call_rules[1].local_prefix == nil)
	assert(link.bridge.inbound_call_rules[1].local_topic[2] == 'diag')
	assert(link.bridge.max_pending_calls == 9)
	assert(link.bridge.max_inbound_calls == 7)
	assert(link.bridge.call_timeout_s == 4.5)

	assert(link.transfer.chunk_size == 8192)
	assert(link.transfer.timeout_s == 22.0)
	assert(link.transfer.xfer_begin_retry_s == 1.25)

	assert(compiled.routing.by_link_id['uart0'] == link)
	assert(compiled.routing.by_peer_id['peer-main'][1] == link)
end

function T.compile_applies_defaults()
	local compiled, err = cfg.compile({
		schema = 'devicecode.config/fabric/1',
		links = {
			{
				id = 'uart0',
				peer_id = 'peer-a',
				bridge = {},
				transfer = {},
			},
		},
	})

	assert(compiled ~= nil, tostring(err))
	local link = compiled.links[1]
	assert(link.transport.kind == 'uart')
	assert(link.transport.source == 'uart')
	assert(link.transport.class == 'uart')
	assert(link.transport.id == 'uart0')

	assert(link.session.hello_interval_s == cfg.DEFAULTS.session.hello_interval_s)
	assert(link.session.ping_interval_s == cfg.DEFAULTS.session.ping_interval_s)
	assert(link.session.liveness_timeout_s == cfg.DEFAULTS.session.liveness_timeout_s)
	assert(link.session.rehello_after_s == nil)

	assert(link.bridge.max_pending_calls == cfg.DEFAULTS.bridge.max_pending_calls)
	assert(link.transfer.chunk_size == cfg.DEFAULTS.transfer.chunk_size)
	assert(link.transfer.timeout_s == cfg.DEFAULTS.transfer.timeout_s)
	assert(link.transfer.xfer_begin_retry_s == nil)
end

function T.compile_rejects_wrong_schema()
	local compiled, err = cfg.compile({
		schema = 'nope',
		links = {},
	})
	assert(compiled == nil)
	assert(tostring(err):match('schema'))
end

function T.compile_rejects_bridge_connections_compat_path()
	local compiled, err = cfg.compile({
		schema = 'devicecode.config/fabric/1',
		links = {
			{
				id = 'uart0',
				peer_id = 'peer-a',
				bridge = {
					connections = {
						{ direction = 'inout' },
					},
				},
			},
		},
	})
	assert(compiled == nil)
	assert(tostring(err):match('bridge has unknown field: connections'))
end

function T.compile_rejects_duplicate_link_ids_but_allows_shared_peer_id()
	local compiled1, err1 = cfg.compile({
		schema = 'devicecode.config/fabric/1',
		links = {
			{ id = 'uart0', peer_id = 'peer-a' },
			{ id = 'uart0', peer_id = 'peer-b' },
		},
	})
	assert(compiled1 == nil)
	assert(tostring(err1):match('duplicate link id'))

	local compiled2, err2 = cfg.compile({
		schema = 'devicecode.config/fabric/1',
		links = {
			{ id = 'uart0', peer_id = 'peer-a' },
			{ id = 'uart1', peer_id = 'peer-a' },
		},
	})
	assert(compiled2 ~= nil, tostring(err2))
	assert(#compiled2.routing.by_peer_id['peer-a'] == 2)
end

function T.compile_rejects_transfer_targets_as_application_routing()
	local compiled, err = cfg.compile({
		schema = 'devicecode.config/fabric/1',
		links = {
			{
				id = 'uart0',
				peer_id = 'peer-a',
				transfer = {
					targets = {
						{ id = 't1', remote_target = 'staging.a' },
					},
				},
			},
		},
	})
	assert(compiled == nil)
	assert(tostring(err):match('transfer has unknown field: targets'))
end

function T.compile_rejects_invalid_topics_and_shapes()
	local compiled, err = cfg.compile({
		schema = 'devicecode.config/fabric/1',
		links = {
			{
				id = 'uart0',
				peer_id = 'peer-a',
				bridge = {
					imports = {
						{ ['local'] = { 'ok', bad = true }, ['remote'] = { 'state' } },
					},
				},
			},
		},
	})
	assert(compiled == nil)
	assert(tostring(err):match('dense topic array'))
end

function T.compile_rejects_rpc_topic_alias_and_requires_exact_local_remote_topics()
	local compiled, err = cfg.compile({
		schema = 'devicecode.config/fabric/1',
		links = {
			{
				id = 'uart0',
				peer_id = 'peer-a',
				bridge = {
					rpc = {
						outbound = {
							{
								topic = { 'cap', 'diag' },
								['local'] = { 'cap', 'diag' },
								['remote'] = { 'cap', 'diag' },
							},
						},
					},
				},
			},
		},
	})
	assert(compiled == nil)
	assert(tostring(err):match('topic is not supported for rpc rules'))
end

function T.compile_rejects_profile_field()
	local compiled, err = cfg.compile({
		schema = 'devicecode.config/fabric/1',
		links = {
			{ id = 'uart0', peer_id = 'peer-a', profile = 'legacy' },
		},
	})
	assert(compiled == nil)
	assert(tostring(err):match('unknown field: profile'))
end

return T
