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

	assert(link.bridge.max_pending_calls == cfg.DEFAULTS.bridge.max_pending_calls)
	assert(link.transfer.chunk_size == cfg.DEFAULTS.transfer.chunk_size)
	assert(link.transfer.timeout_s == cfg.DEFAULTS.transfer.timeout_s)
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


function T.compile_defaults_to_standard_fabric_profile()
	local compiled, err = cfg.compile({
		schema = 'devicecode.config/fabric/1',
		links = { { id = 'uart0', peer_id = 'peer-a' } },
	})
	assert(compiled ~= nil, tostring(err))
	assert(compiled.links[1].protocol.kind == 'fabric_jsonl_v1')
	assert(next(compiled.links[1].protocol.args) == nil)
	assert(compiled.links[1].protocol.capabilities.transfer == true)
end

function T.compile_accepts_legacy_mcu_metrics_profile_args()
	local compiled, err = cfg.compile({
		schema = 'devicecode.config/fabric/1',
		local_node = 'bigbox-v1-cm',
		links = {
			{
				id = 'legacy-mcu-uart0',
				peer_id = 'mcu',
				protocol = {
					kind = 'legacy_mcu_metrics_v1',
					args = {
						namespace_prefix = { 'mcu' },
						publish_service = 'mcu',
						change_only = true,
						unsigned_underflow_compat = true,
						error_log_initial_s = 1,
						error_log_max_s = 60,
					},
				},
				transport = {
					kind = 'uart',
					source = 'uart_manager',
					class = 'uart',
					id = 'uart0',
					terminator = '\n',
				},
			},
		},
	})
	assert(compiled ~= nil, tostring(err))
	local link = compiled.links[1]
	assert(link.protocol.kind == 'legacy_mcu_metrics_v1')
	assert(link.protocol.args.namespace_prefix[1] == 'mcu')
	assert(link.protocol.args.publish_service == 'mcu')
	assert(link.protocol.capabilities.transfer == false)
	assert(link.session == nil)
	assert(link.bridge == nil)
	assert(link.transfer == nil)
end

function T.compile_profile_owns_legacy_defaults()
	local compiled, err = cfg.compile({
		schema = 'devicecode.config/fabric/1',
		links = {
			{
				id = 'legacy',
				peer_id = 'mcu',
				protocol = { kind = 'legacy_mcu_metrics_v1' },
			},
		},
	})
	assert(compiled ~= nil, tostring(err))
	local args = compiled.links[1].protocol.args
	assert(args.change_only == true)
	assert(args.unsigned_underflow_compat == true)
	assert(args.error_log_initial_s == 1)
	assert(args.error_log_max_s == 60)
end

function T.compile_rejects_link_sections_not_supported_by_profile()
	local compiled, err = cfg.compile({
		schema = 'devicecode.config/fabric/1',
		links = {
			{
				id = 'legacy',
				peer_id = 'mcu',
				protocol = { kind = 'legacy_mcu_metrics_v1' },
				session = {},
			},
		},
	})
	assert(compiled == nil)
	assert(tostring(err):match('link.session is not valid for protocol profile'))
end

function T.compile_rejects_profile_args_at_protocol_root()
	local compiled, err = cfg.compile({
		schema = 'devicecode.config/fabric/1',
		links = {
			{
				id = 'legacy',
				peer_id = 'mcu',
				protocol = { kind = 'legacy_mcu_metrics_v1', change_only = true },
			},
		},
	})
	assert(compiled == nil)
	assert(tostring(err):match('protocol has unknown field'))
end

function T.compile_rejects_args_unknown_to_selected_profile()
	local compiled, err = cfg.compile({
		schema = 'devicecode.config/fabric/1',
		links = {
			{
				id = 'standard',
				peer_id = 'mcu',
				protocol = {
					kind = 'fabric_jsonl_v1',
					args = { change_only = true },
				},
			},
		},
	})
	assert(compiled == nil)
	assert(tostring(err):match('unknown field for fabric_jsonl_v1'))
end

function T.compile_loads_new_profile_packages_without_central_registration()
	local module_name = 'services.fabric.profiles.test_extensible_v1.init'
	package.loaded[module_name] = nil
	package.preload[module_name] = function ()
		return {
			kind = 'test_extensible_v1',
			capabilities = { publish = true },
			link_sections = {},
			compile = function (args)
				if type(args) ~= 'table' or args.token ~= 'accepted' then
					return nil, 'test profile args rejected'
				end
				return { token = args.token }, nil
			end,
			run = function () return { ok = true } end,
		}
	end
	local compiled, err = cfg.compile({
		schema = 'devicecode.config/fabric/1',
		links = {
			{
				id = 'dynamic',
				peer_id = 'peer',
				protocol = {
					kind = 'test_extensible_v1',
					args = { token = 'accepted' },
				},
			},
		},
	})
	package.loaded[module_name] = nil
	package.preload[module_name] = nil
	assert(compiled ~= nil, tostring(err))
	assert(compiled.links[1].protocol.args.token == 'accepted')
end

function T.compile_rejects_unsafe_or_unavailable_profile_kinds()
	local unsafe, unsafe_err = cfg.compile({
		schema = 'devicecode.config/fabric/1',
		links = {
			{ id = 'unsafe', peer_id = 'mcu', protocol = { kind = '../escape' } },
		},
	})
	assert(unsafe == nil)
	assert(tostring(unsafe_err):match('must match'))

	local missing, missing_err = cfg.compile({
		schema = 'devicecode.config/fabric/1',
		links = {
			{ id = 'missing', peer_id = 'mcu', protocol = { kind = 'not_installed_v1' } },
		},
	})
	assert(missing == nil)
	assert(tostring(missing_err):match('profile unavailable'))
end


local function read_project_file(rel)
	local candidates = { rel, '../' .. rel }
	for i = 1, #candidates do
		local f = io.open(candidates[i], 'rb')
		if f then
			local data = f:read('*a')
			f:close()
			return data
		end
	end
	return nil, 'unable to read ' .. rel
end

function T.bigbox_v1_cm_selects_the_legacy_mcu_metrics_profile()
	local cjson = require 'cjson.safe'
	local text, read_err = read_project_file('src/configs/bigbox-v1-cm.json')
	assert(text ~= nil, tostring(read_err))
	local doc, decode_err = cjson.decode(text)
	assert(doc ~= nil, tostring(decode_err))
	local compiled, err = cfg.compile(doc.fabric.data)
	assert(compiled ~= nil, tostring(err))
	local link = compiled.links[1]
	assert(link.protocol.kind == 'legacy_mcu_metrics_v1')
	assert(link.protocol.args.error_log_initial_s == 1)
	assert(link.protocol.args.error_log_max_s == 60)
	assert(link.protocol.capabilities.transfer == false)
	assert(link.reader == nil)
	assert(link.session == nil)
	assert(link.bridge == nil)
end

function T.bigbox_v1_cm_2_explicitly_selects_standard_profile()
	local cjson = require 'cjson.safe'
	local text, read_err = read_project_file('src/configs/bigbox-v1-cm-2.json')
	assert(text ~= nil, tostring(read_err))
	local doc, decode_err = cjson.decode(text)
	assert(doc ~= nil, tostring(decode_err))
	local compiled, err = cfg.compile(doc.fabric.data)
	assert(compiled ~= nil, tostring(err))
	local link = compiled.links[1]
	assert(link.protocol.kind == 'fabric_jsonl_v1')
	assert(link.protocol.capabilities.session == true)
	assert(link.protocol.capabilities.transfer == true)
	assert(link.session ~= nil)
	assert(link.bridge ~= nil)
end

return T
