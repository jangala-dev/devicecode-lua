-- services/fabric/config.lua
--
-- Config normalisation for config/fabric.

local M = {}

local function is_plain_table(x)
	return type(x) == 'table' and getmetatable(x) == nil
end

local function norm_topic_array(t, path)
	if type(t) ~= 'table' then
		return nil, (path or 'topic') .. ' must be an array'
	end

	local out = {}
	for i = 1, #t do
		local v = t[i]
		if type(v) ~= 'string' or v == '' then
			return nil, ('%s[%d] must be non-empty string'):format(path or 'topic', i)
		end
		out[i] = v
	end
	return out
end

local function norm_transport(t, path)
	if not is_plain_table(t) then
		return nil, path .. ' must be a table'
	end

	local kind = t.kind or 'uart'
	if kind == 'uart' then
		if type(t.serial_ref) ~= 'string' or t.serial_ref == '' then
			return nil, path .. '.serial_ref must be a non-empty string'
		end
		return {
			kind       = 'uart',
			serial_ref = t.serial_ref,
			max_line_bytes = (type(t.max_line_bytes) == 'number' and t.max_line_bytes > 0)
				and math.floor(t.max_line_bytes)
				or nil,
		}, nil
	end

	if kind == 'websocket' then
		if type(t.url) ~= 'string' or t.url == '' then
			return nil, path .. '.url must be a non-empty string'
		end
		return {
			kind = 'websocket',
			url  = t.url,
			tls  = not not t.tls,
		}, nil
	end

	return nil, path .. '.kind is unsupported: ' .. tostring(kind)
end

local function norm_transfer(t, path)
	if t == nil then
		return {
			chunk_raw     = 768,
			ack_timeout_s = 2.0,
			max_retries   = 5,
		}, nil
	end

	if not is_plain_table(t) then
		return nil, path .. ' must be a table'
	end

	local chunk_raw = t.chunk_raw
	if chunk_raw ~= nil then
		if type(chunk_raw) ~= 'number' or chunk_raw <= 0 or chunk_raw % 1 ~= 0 then
			return nil, path .. '.chunk_raw must be a positive integer'
		end
		chunk_raw = math.floor(chunk_raw)
	end

	local ack_timeout_s = t.ack_timeout_s
	if ack_timeout_s ~= nil then
		if type(ack_timeout_s) ~= 'number' or ack_timeout_s <= 0 then
			return nil, path .. '.ack_timeout_s must be a positive number'
		end
	end

	local max_retries = t.max_retries
	if max_retries ~= nil then
		if type(max_retries) ~= 'number' or max_retries <= 0 or max_retries % 1 ~= 0 then
			return nil, path .. '.max_retries must be a positive integer'
		end
		max_retries = math.floor(max_retries)
	end

	return {
		chunk_raw     = chunk_raw or 768,
		ack_timeout_s = ack_timeout_s or 2.0,
		max_retries   = max_retries or 5,
	}, nil
end

local function is_concrete_topic(t)
	for i = 1, #t do
		if t[i] == '+' or t[i] == '#' then
			return false
		end
	end
	return true
end

local function norm_pub_rule(r, path)
	if not is_plain_table(r) then
		return nil, path .. ' must be a table'
	end

	local src_t, err = norm_topic_array(r.src, path .. '.src')
	if not src_t then return nil, err end

	local dst_t, err2 = norm_topic_array(r.dst, path .. '.dst')
	if not dst_t then return nil, err2 end

	return {
		local_topic  = src_t,
		remote_topic = dst_t,
		retain       = not not r.retain,
		queue_len    = (type(r.queue_len) == 'number' and r.queue_len > 0) and r.queue_len or 50,
	}, nil
end

local function norm_import_pub_rule(r, path)
	if not is_plain_table(r) then
		return nil, path .. ' must be a table'
	end

	local src_t, err = norm_topic_array(r.src, path .. '.src')
	if not src_t then return nil, err end

	local dst_t, err2 = norm_topic_array(r.dst, path .. '.dst')
	if not dst_t then return nil, err2 end

	return {
		remote_topic = src_t,
		local_topic  = dst_t,
		retain       = not not r.retain,
	}, nil
end

local function norm_proxy_call_rule(r, path)
	if not is_plain_table(r) then
		return nil, path .. ' must be a table'
	end

	local src_t, err = norm_topic_array(r.src, path .. '.src')
	if not src_t then return nil, err end

	local dst_t, err2 = norm_topic_array(r.dst, path .. '.dst')
	if not dst_t then return nil, err2 end

	if not is_concrete_topic(src_t) then
		return nil, path .. '.src must be a concrete topic for proxy_calls'
	end
	if not is_concrete_topic(dst_t) then
		return nil, path .. '.dst must be a concrete topic for proxy_calls'
	end

	return {
		local_topic  = src_t,
		remote_topic = dst_t,
		timeout_s    = (type(r.timeout_s) == 'number' and r.timeout_s > 0) and r.timeout_s or 5.0,
		queue_len    = (type(r.queue_len) == 'number' and r.queue_len >= 0) and r.queue_len or 8,
	}, nil
end

local function norm_import_call_rule(r, path)
	if not is_plain_table(r) then
		return nil, path .. ' must be a table'
	end

	local src_t, err = norm_topic_array(r.src, path .. '.src')
	if not src_t then return nil, err end

	local dst_t, err2 = norm_topic_array(r.dst, path .. '.dst')
	if not dst_t then return nil, err2 end

	if not is_concrete_topic(src_t) then
		return nil, path .. '.src must be a concrete topic for import.call'
	end
	if not is_concrete_topic(dst_t) then
		return nil, path .. '.dst must be a concrete topic for import.call'
	end

	return {
		remote_topic = src_t,
		local_topic  = dst_t,
		timeout_s    = (type(r.timeout_s) == 'number' and r.timeout_s > 0) and r.timeout_s or 5.0,
	}, nil
end

function M.normalise(payload)
	if not is_plain_table(payload) then
		return nil, 'fabric config must be a plain table'
	end
	if type(payload.schema) ~= 'string' or payload.schema == '' then
		return nil, 'fabric config requires schema'
	end

	local links_in = payload.links
	if type(links_in) ~= 'table' then
		return nil, 'fabric config requires links table'
	end

	local out = {
		schema     = payload.schema,
		links      = {},
		link_count = 0,
	}

	for link_id, rec in pairs(links_in) do
		if type(link_id) ~= 'string' or link_id == '' then
			return nil, 'link ids must be non-empty strings'
		end
		if not is_plain_table(rec) then
			return nil, ('links.%s must be a table'):format(link_id)
		end
		local transport, terr = norm_transport(rec.transport, ('links.%s.transport'):format(link_id))
		if not transport then
			return nil, terr
		end
		local transfer, trerr = norm_transfer(rec.transfer, ('links.%s.transfer'):format(link_id))
		if not transfer then
			return nil, trerr
		end
		if type(rec.peer_id) ~= 'string' or rec.peer_id == '' then
			return nil, ('links.%s.peer_id must be a non-empty string'):format(link_id)
		end

		local export_cfg = is_plain_table(rec.export) and rec.export or {}
		local import_cfg = is_plain_table(rec.import) and rec.import or {}
		local proxy_cfg  = type(rec.proxy_calls) == 'table' and rec.proxy_calls or {}

		local link       = {
			peer_id     = rec.peer_id,
			transport   = transport,
			transfer    = transfer,
			export      = {
				publish = {},
			},
			import      = {
				publish = {},
				call    = {},
			},
			proxy_calls = {},
		}

		local exp_pub    = type(export_cfg.publish) == 'table' and export_cfg.publish or {}
		for i = 1, #exp_pub do
			local nr, err = norm_pub_rule(exp_pub[i], ('links.%s.export.publish[%d]'):format(link_id, i))
			if not nr then return nil, err end
			link.export.publish[#link.export.publish + 1] = nr
		end

		local imp_pub = type(import_cfg.publish) == 'table' and import_cfg.publish or {}
		for i = 1, #imp_pub do
			local nr, err = norm_import_pub_rule(imp_pub[i], ('links.%s.import.publish[%d]'):format(link_id, i))
			if not nr then return nil, err end
			link.import.publish[#link.import.publish + 1] = nr
		end

		local imp_call = type(import_cfg.call) == 'table' and import_cfg.call or {}
		for i = 1, #imp_call do
			local nr, err = norm_import_call_rule(imp_call[i], ('links.%s.import.call[%d]'):format(link_id, i))
			if not nr then return nil, err end
			link.import.call[#link.import.call + 1] = nr
		end

		for i = 1, #proxy_cfg do
			local nr, err = norm_proxy_call_rule(proxy_cfg[i], ('links.%s.proxy_calls[%d]'):format(link_id, i))
			if not nr then return nil, err end
			link.proxy_calls[#link.proxy_calls + 1] = nr
		end

		out.links[link_id] = link
		out.link_count = out.link_count + 1
	end

	return out, nil
end

return M
