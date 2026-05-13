-- services/fabric/config.lua
--
-- Pure Fabric configuration compiler.
--
-- This module validates untrusted raw configuration and returns a normalised
-- runtime plan for the new Fabric semantic modules. It intentionally performs
-- no I/O, starts no fibres, and calls no bus/HAL APIs.
--
---@module 'services.fabric.config'
--
-- Fabric configuration compiler.
--
-- Contract:
--   * raw config is untrusted and fully validated here;
--   * the returned compiled config is normalised and may be trusted by services;
--   * compiled config does not alias raw config tables;
--   * compiled tables are sealed against new fields, but not proxy-immutable
--     (Lua 5.1 cannot trap writes to existing keys without much heavier wrappers).

local M = {}

local SCHEMA = 'devicecode.config/fabric/1'

local DEFAULTS = {
	reader = {
		bad_frame_limit    = 5,
		bad_frame_window_s = 10.0,
	},
	session = {
		hello_interval_s   = 2.0,
		ping_interval_s    = 10.0,
		liveness_timeout_s = 30.0,
	},
	writer = {
		rpc_quota  = 4,
		bulk_quota = 1,
	},
	bridge = {
		max_pending_calls   = 64,
		max_inbound_calls   = 64,
		call_timeout_s      = 5.0,
	},
	transfer = {
		chunk_size = 1024,
		timeout_s  = 30.0,
	},
	queues = {
		rpc_in     = 64,
		xfer_in    = 64,
		tx_control = 32,
		tx_rpc     = 128,
		tx_bulk    = 64,
	},
}

local ROOT_KEYS = {
	schema = true, local_node = true, links = true,
}

local LINK_KEYS = {
	id = true, peer_id = true,
	transport = true, session = true, reader = true, writer = true,
	bridge = true, transfer = true, queues = true,
}

local TRANSPORT_KEYS = {
	kind = true, source = true, class = true, id = true,
	open_verb = true, open_opts = true, terminator = true,
}

local SESSION_KEYS = {
	local_node = true, identity_claim = true, auth_claim = true,
	hello_interval_s = true, ping_interval_s = true, liveness_timeout_s = true,
}

local READER_KEYS = {
	bad_frame_limit = true, bad_frame_window_s = true,
}

local WRITER_KEYS = { rpc_quota = true, bulk_quota = true }

local BRIDGE_KEYS = {
	imports = true, exports = true, rpc = true,
	max_pending_calls = true, max_inbound_calls = true, call_timeout_s = true,
}

local BRIDGE_RPC_KEYS = { inbound = true, outbound = true }

local RULE_KEYS = {
	id = true, ['local'] = true, remote = true, topic = true, timeout_s = true,
}

local EXPORT_RULE_KEYS = {
	id = true, ['local'] = true, remote = true, topic = true,
	timeout_s = true, publish = true, retain = true,
}

local TRANSFER_KEYS = {
	chunk_size = true, timeout_s = true, xfer_begin_retry_s = true,
}

local QUEUE_KEYS = {
	rpc_in = true, xfer_in = true,
	tx_control = true, tx_rpc = true, tx_bulk = true,
}

-------------------------------------------------------------------------------
-- Tiny validator / compiler helpers
-------------------------------------------------------------------------------

local SEALED_MT = {
	__newindex = function(_, k)
		error('attempt to add field to compiled fabric config: ' .. tostring(k), 2)
	end,
	__metatable = false,
}

local function fail(msg) return nil, msg end

local function is_finite_number(v)
	return type(v) == 'number' and v == v and v ~= math.huge and v ~= -math.huge
end

local function copy_plain(v)
	if type(v) ~= 'table' then return v end
	local out = {}
	for k, subv in pairs(v) do out[k] = copy_plain(subv) end
	return out
end

local function seal(v, seen)
	if type(v) ~= 'table' then return v end
	seen = seen or {}
	if seen[v] then return v end
	seen[v] = true
	for _, subv in pairs(v) do seal(subv, seen) end
	return setmetatable(v, SEALED_MT)
end

local function allowed(t, keys, path)
	for k in pairs(t) do
		if not keys[k] then
			return nil, path .. ' has unknown field: ' .. tostring(k)
		end
	end
	return true, nil
end

local function table_or_empty(v, path)
	if v == nil then return {}, nil end
	if type(v) ~= 'table' then return nil, path .. ' must be a table' end
	return v, nil
end

local function list_or_empty(v, path)
	if v == nil then return {}, nil end
	if type(v) ~= 'table' then return nil, path .. ' must be a dense list' end
	local n = #v
	for k in pairs(v) do
		if type(k) ~= 'number' or k < 1 or k % 1 ~= 0 or k > n then
			return nil, path .. ' must be a dense list'
		end
	end
	return v, nil
end

local function str(v, path)
	if type(v) ~= 'string' or v == '' then
		return nil, path .. ' must be a non-empty string'
	end
	return v, nil
end

local function opt_str(v, path, default)
	if v == nil then return default, nil end
	return str(v, path)
end

local function bool(v, path, default)
	if v == nil then return default, nil end
	if type(v) ~= 'boolean' then return nil, path .. ' must be boolean' end
	return v, nil
end

local function opt_number(v, path, default)
	if v == nil then return default, nil end
	if not is_finite_number(v) then return nil, path .. ' must be a finite number' end
	return v, nil
end

local function opt_pos_number(v, path)
	if v == nil then return nil, nil end
	if not is_finite_number(v) or v <= 0 then
		return nil, path .. ' must be a positive finite number'
	end
	return v, nil
end

local function pos_number(v, path, default)
	if v == nil then v = default end
	if not is_finite_number(v) or v <= 0 then
		return nil, path .. ' must be a positive finite number'
	end
	return v, nil
end

local function nonneg_int(v, path, default)
	local n, err = opt_number(v, path, default)
	if err then return nil, err end
	if type(n) ~= 'number' or n < 0 or n % 1 ~= 0 then
		return nil, path .. ' must be a non-negative integer'
	end
	return n, nil
end

local function pos_int(v, path, default)
	local n, err = opt_number(v, path, default)
	if err then return nil, err end
	if type(n) ~= 'number' or n <= 0 or n % 1 ~= 0 then
		return nil, path .. ' must be a positive integer'
	end
	return n, nil
end

local function topic_token_ok(v)
	if type(v) == 'string' then return v ~= '' end
	return is_finite_number(v)
end

local function topic(v, path)
	if type(v) ~= 'table' then return nil, path .. ' must be a dense topic array' end
	local n = #v
	for i = 1, n do
		if not topic_token_ok(v[i]) then
			return nil, path .. '[' .. tostring(i) .. '] must be string or finite number'
		end
	end
	for k in pairs(v) do
		if type(k) ~= 'number' or k < 1 or k % 1 ~= 0 or k > n then
			return nil, path .. ' must be a dense topic array'
		end
	end
	local out = {}
	for i = 1, n do out[i] = v[i] end
	return out, nil
end

local function append_index(index, key, value)
	local bucket = index[key]
	if bucket == nil then
		bucket = {}
		index[key] = bucket
	end
	bucket[#bucket + 1] = value
end


-------------------------------------------------------------------------------
-- Section compilers
-------------------------------------------------------------------------------

local function compile_transport(raw, link_id)
	raw = raw or {}
	if type(raw) ~= 'table' then return nil, 'transport must be a table' end
	local ok, err = allowed(raw, TRANSPORT_KEYS, 'transport')
	if not ok then return nil, err end

	local kind, e1 = opt_str(raw.kind, 'transport.kind', 'uart')
	if e1 then return nil, e1 end
	local source, e2 = opt_str(raw.source, 'transport.source', kind)
	if e2 then return nil, e2 end
	local class, e3 = opt_str(raw.class, 'transport.class', kind)
	if e3 then return nil, e3 end
	local id, e4 = opt_str(raw.id, 'transport.id', link_id)
	if e4 then return nil, e4 end
	local open_verb, e5 = opt_str(raw.open_verb, 'transport.open_verb', 'open')
	if e5 then return nil, e5 end

	local terminator = raw.terminator
	if terminator == nil then terminator = '\n' end
	if type(terminator) ~= 'string' then
		return nil, 'transport.terminator must be a string'
	end

	return {
		kind       = kind,
		source     = source,
		class      = class,
		id         = id,
		open_verb  = open_verb,
		open_opts  = copy_plain(raw.open_opts),
		terminator = terminator,
	}, nil
end

local function compile_session(raw, service_local_node)
	raw = raw or {}
	if type(raw) ~= 'table' then return nil, 'session must be a table' end
	local ok, err = allowed(raw, SESSION_KEYS, 'session')
	if not ok then return nil, err end

	local local_node, e1 = opt_str(raw.local_node, 'session.local_node', service_local_node)
	if e1 then return nil, e1 end
	local hello, e2 = pos_number(raw.hello_interval_s, 'session.hello_interval_s', DEFAULTS.session.hello_interval_s)
	if e2 then return nil, e2 end
	local ping, e3 = pos_number(raw.ping_interval_s, 'session.ping_interval_s', DEFAULTS.session.ping_interval_s)
	if e3 then return nil, e3 end
	local live, e4 = pos_number(raw.liveness_timeout_s, 'session.liveness_timeout_s', DEFAULTS.session.liveness_timeout_s)
	if e4 then return nil, e4 end

	return {
		local_node         = local_node,
		identity_claim     = copy_plain(raw.identity_claim),
		auth_claim         = copy_plain(raw.auth_claim),
		hello_interval_s   = hello,
		ping_interval_s    = ping,
		liveness_timeout_s = live,
	}, nil
end

local function compile_reader(raw)
	raw = raw or {}
	if type(raw) ~= 'table' then return nil, 'reader must be a table' end
	local ok, err = allowed(raw, READER_KEYS, 'reader')
	if not ok then return nil, err end

	local bad_frame_limit, e1 = pos_int(raw.bad_frame_limit, 'reader.bad_frame_limit', DEFAULTS.reader.bad_frame_limit)
	if e1 then return nil, e1 end
	local bad_frame_window_s, e2 = pos_number(raw.bad_frame_window_s, 'reader.bad_frame_window_s', DEFAULTS.reader.bad_frame_window_s)
	if e2 then return nil, e2 end

	return {
		bad_frame_limit    = bad_frame_limit,
		bad_frame_window_s = bad_frame_window_s,
	}, nil
end

local function compile_writer(raw)
	raw = raw or {}
	if type(raw) ~= 'table' then return nil, 'writer must be a table' end
	local ok, err = allowed(raw, WRITER_KEYS, 'writer')
	if not ok then return nil, err end

	local rpc_quota, e1 = pos_int(raw.rpc_quota, 'writer.rpc_quota', DEFAULTS.writer.rpc_quota)
	if e1 then return nil, e1 end
	local bulk_quota, e2 = pos_int(raw.bulk_quota, 'writer.bulk_quota', DEFAULTS.writer.bulk_quota)
	if e2 then return nil, e2 end

	return { rpc_quota = rpc_quota, bulk_quota = bulk_quota }, nil
end

local function compile_rule_item(raw, direction, path, keys)
	if type(raw) ~= 'table' then return nil, path .. ' must be a table' end
	local ok, err = allowed(raw, keys, path)
	if not ok then return nil, err end
	if raw.timeout ~= nil then return nil, path .. '.timeout is not supported; use timeout_s' end

	local local_prefix, e1 = topic(raw['local'], path .. '.local')
	if e1 then return nil, e1 end
	local remote_prefix, e2 = topic(raw.remote, path .. '.remote')
	if e2 then return nil, e2 end

	local rule_topic = nil
	if raw.topic ~= nil then
		local e3
		rule_topic, e3 = topic(raw.topic, path .. '.topic')
		if e3 then return nil, e3 end
	end

	local timeout_s, e4 = opt_pos_number(raw.timeout_s, path .. '.timeout_s')
	if e4 then return nil, e4 end

	local local_watch_topic = rule_topic
	if local_watch_topic == nil then
		local_watch_topic = {}
		for i = 1, #local_prefix do local_watch_topic[i] = local_prefix[i] end
		local_watch_topic[#local_watch_topic + 1] = '#'
	end

	return {
		id            = raw.id,
		local_prefix  = local_prefix,
		remote_prefix = remote_prefix,
		topic         = rule_topic,
		local_watch_topic = local_watch_topic,
		timeout       = timeout_s,
		direction     = direction,
	}, nil
end

local function compile_rule_list(raw, direction, path, keys)
	local list, err = list_or_empty(raw, path)
	if not list then return nil, err end
	local out = {}
	for i = 1, #list do
		local rule, rerr = compile_rule_item(list[i], direction, path .. '[' .. tostring(i) .. ']', keys)
		if not rule then return nil, rerr end
		out[#out + 1] = rule
	end
	return out, nil
end

local function compile_rpc_rule_item(raw, direction, path)
	if type(raw) ~= 'table' then return nil, path .. ' must be a table' end
	local ok, err = allowed(raw, RULE_KEYS, path)
	if not ok then return nil, err end
	if raw.timeout ~= nil then return nil, path .. '.timeout is not supported; use timeout_s' end
	if raw.topic ~= nil then return nil, path .. '.topic is not supported for rpc rules; use exact local/remote topics' end

	local local_topic, e1 = topic(raw['local'], path .. '.local')
	if e1 then return nil, e1 end
	local remote_topic, e2 = topic(raw.remote, path .. '.remote')
	if e2 then return nil, e2 end
	local timeout_s, e3 = opt_pos_number(raw.timeout_s, path .. '.timeout_s')
	if e3 then return nil, e3 end

	return {
		id           = raw.id,
		local_topic  = local_topic,
		remote_topic = remote_topic,
		timeout      = timeout_s,
		direction    = direction,
	}, nil
end

local function compile_rpc_rule_list(raw, direction, path)
	local list, err = list_or_empty(raw, path)
	if not list then return nil, err end
	local out = {}
	for i = 1, #list do
		local rule, rerr = compile_rpc_rule_item(list[i], direction, path .. '[' .. tostring(i) .. ']')
		if not rule then return nil, rerr end
		out[#out + 1] = rule
	end
	return out, nil
end

local function compile_bridge(raw)
	raw = raw or {}
	if type(raw) ~= 'table' then return nil, 'bridge must be a table' end
	local ok, err = allowed(raw, BRIDGE_KEYS, 'bridge')
	if not ok then return nil, err end

	local import_rules, e1 = compile_rule_list(raw.imports, 'import', 'bridge.imports', RULE_KEYS)
	if e1 then return nil, e1 end

	local exports, e2 = list_or_empty(raw.exports, 'bridge.exports')
	if not exports then return nil, e2 end

	local export_publish_raw, export_retained_raw = {}, {}
	for i = 1, #exports do
		local item = exports[i]
		local path = 'bridge.exports[' .. tostring(i) .. ']'
		if type(item) ~= 'table' then return nil, path .. ' must be a table' end
		local eok, eerr = allowed(item, EXPORT_RULE_KEYS, path)
		if not eok then return nil, eerr end
		if item.timeout ~= nil then return nil, path .. '.timeout is not supported; use timeout_s' end

		local publish, perr = bool(item.publish, path .. '.publish', true)
		if perr then return nil, perr end
		local retain, rerr = bool(item.retain, path .. '.retain', false)
		if rerr then return nil, rerr end
		if not publish and not retain then return nil, path .. ' must enable publish or retain' end

		if publish then export_publish_raw[#export_publish_raw + 1] = item end
		if retain then export_retained_raw[#export_retained_raw + 1] = item end
	end

	local export_publish_rules, e3 = compile_rule_list(export_publish_raw, 'export_publish', 'bridge.exports', EXPORT_RULE_KEYS)
	if e3 then return nil, e3 end
	local export_retained_rules, e4 = compile_rule_list(export_retained_raw, 'export_retained', 'bridge.exports', EXPORT_RULE_KEYS)
	if e4 then return nil, e4 end

	local rpc, e5 = table_or_empty(raw.rpc, 'bridge.rpc')
	if not rpc then return nil, e5 end
	local rok, rerr = allowed(rpc, BRIDGE_RPC_KEYS, 'bridge.rpc')
	if not rok then return nil, rerr end

	local outbound_call_rules, e6 = compile_rpc_rule_list(rpc.outbound, 'outbound_call', 'bridge.rpc.outbound')
	if e6 then return nil, e6 end
	local inbound_call_rules, e7 = compile_rpc_rule_list(rpc.inbound, 'inbound_call', 'bridge.rpc.inbound')
	if e7 then return nil, e7 end

	local max_pending_calls, e8 = nonneg_int(raw.max_pending_calls, 'bridge.max_pending_calls', DEFAULTS.bridge.max_pending_calls)
	if e8 then return nil, e8 end
	local max_inbound_calls, e9 = nonneg_int(raw.max_inbound_calls, 'bridge.max_inbound_calls', DEFAULTS.bridge.max_inbound_calls)
	if e9 then return nil, e9 end
	local call_timeout_s, e10 = pos_number(raw.call_timeout_s, 'bridge.call_timeout_s', DEFAULTS.bridge.call_timeout_s)
	if e10 then return nil, e10 end

	return {
		import_rules          = import_rules,
		export_publish_rules  = export_publish_rules,
		export_retained_rules = export_retained_rules,
		outbound_call_rules   = outbound_call_rules,
		inbound_call_rules    = inbound_call_rules,
		max_pending_calls     = max_pending_calls,
		max_inbound_calls     = max_inbound_calls,
		call_timeout_s        = call_timeout_s,
	}, nil
end

local function compile_transfer(raw)
	raw = raw or {}
	if type(raw) ~= 'table' then return nil, 'transfer must be a table' end
	local ok, err = allowed(raw, TRANSFER_KEYS, 'transfer')
	if not ok then return nil, err end

	local chunk_size, e2 = pos_int(raw.chunk_size, 'transfer.chunk_size', DEFAULTS.transfer.chunk_size)
	if e2 then return nil, e2 end
	local timeout_s, e3 = pos_number(raw.timeout_s, 'transfer.timeout_s', DEFAULTS.transfer.timeout_s)
	if e3 then return nil, e3 end
	local xfer_begin_retry_s, e4 = opt_pos_number(raw.xfer_begin_retry_s, 'transfer.xfer_begin_retry_s')
	if e4 then return nil, e4 end

	return {
		chunk_size = chunk_size,
		timeout_s  = timeout_s,
		xfer_begin_retry_s = xfer_begin_retry_s,
	}, nil
end

local function compile_queues(raw)
	raw = raw or {}
	if type(raw) ~= 'table' then return nil, 'queues must be a table' end
	local ok, err = allowed(raw, QUEUE_KEYS, 'queues')
	if not ok then return nil, err end

	local out = {}
	for k, default in pairs(DEFAULTS.queues) do
		local v, verr = pos_int(raw[k], 'queues.' .. k, default)
		if verr then return nil, verr end
		out[k] = v
	end
	return out, nil
end

local function compile_link(raw, service_local_node)
	if type(raw) ~= 'table' then return nil, 'link must be a table' end
	local ok, err = allowed(raw, LINK_KEYS, 'link')
	if not ok then return nil, err end

	local link_id, e1 = str(raw.id, 'link.id')
	if e1 then return nil, e1 end
	local peer_id, e2 = str(raw.peer_id, 'link.peer_id')
	if e2 then return nil, e2 end

	local transport, e4 = compile_transport(raw.transport, link_id)
	if e4 then return nil, e4 end
	local session, e5 = compile_session(raw.session, service_local_node)
	if e5 then return nil, e5 end
	local reader, e6 = compile_reader(raw.reader)
	if e6 then return nil, e6 end
	local writer, e7 = compile_writer(raw.writer)
	if e7 then return nil, e7 end
	local bridge, e8 = compile_bridge(raw.bridge)
	if e8 then return nil, e8 end
	local transfer, e9 = compile_transfer(raw.transfer)
	if e9 then return nil, e9 end
	local queues, e10 = compile_queues(raw.queues)
	if e10 then return nil, e10 end

	return {
		link_id       = link_id,
		peer_id       = peer_id,
		transport     = transport,
		session       = session,
		reader        = reader,
		writer        = writer,
		bridge        = bridge,
		transfer      = transfer,
		queues        = queues,
	}, nil
end

-------------------------------------------------------------------------------
-- Public compiler
-------------------------------------------------------------------------------

function M.compile(raw)
	if type(raw) ~= 'table' then return fail('fabric config must be a table') end
	local ok, err = allowed(raw, ROOT_KEYS, 'fabric config')
	if not ok then return fail(err) end
	if raw.schema ~= SCHEMA then
		return fail('fabric config schema must be ' .. SCHEMA)
	end

	local local_node, nerr = opt_str(raw.local_node, 'fabric.local_node')
	if nerr then return fail(nerr) end

	local links_in, lerr = list_or_empty(raw.links, 'fabric.links')
	if not links_in then return fail(lerr) end

	local compiled = {
		service = {
			schema     = raw.schema,
			local_node = local_node,
		},
		links = {},
		routing = {
			by_link_id = {},
			by_peer_id = {},
		},
	}

	for i = 1, #links_in do
		local link, cerr = compile_link(links_in[i], local_node)
		if not link then return fail('links[' .. tostring(i) .. ']: ' .. tostring(cerr)) end

		if compiled.routing.by_link_id[link.link_id] ~= nil then
			return fail('duplicate link id: ' .. link.link_id)
		end
		compiled.links[#compiled.links + 1] = link
		compiled.routing.by_link_id[link.link_id] = link
		append_index(compiled.routing.by_peer_id, link.peer_id, link)
	end

	return seal(compiled), nil
end

M.DEFAULTS = seal(copy_plain(DEFAULTS))
M.SCHEMA = SCHEMA

return M
