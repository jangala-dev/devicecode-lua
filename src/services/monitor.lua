-- services/monitor.lua
--
-- Monitor service:
--   * subscribes to obs/# and peer/# and prints messages
--   * bounded, drop-oldest

local fibers  = require 'fibers'
local runtime = require 'fibers.runtime'
local file    = require 'fibers.io.file'
local sleep   = require 'fibers.sleep'
local cjson   = require 'cjson'

local perform      = fibers.perform
local named_choice = fibers.named_choice

local base = require 'devicecode.service_base'

local M = {}
local topic_to_string

local AUTO_PROBE_START_DELAY_S = 1.0
local AUTO_PROBE_RETRY_DELAY_S = 0.75
local AUTO_PROBE_MAX_ATTEMPTS = 3

local function t(...) return { ... } end

local function reply_best_effort(conn, msg, payload)
	if msg.reply_to == nil then
		return false, 'no_reply_to'
	end
	return conn:publish_one(msg.reply_to, payload, { id = msg.id })
end

local function empty_array()
	return setmetatable({}, cjson.array_mt)
end

local function normalise_probe_req(req)
	if req == nil then
		return {}, nil
	end
	if type(req) ~= 'table' then
		return nil, 'request payload must be a table or nil'
	end
	return req, nil
end

local function publish_config_mcu(conn, svc, req)
	local payload = req.payload
	if payload == nil then
		payload = {
			source = 'monitor',
			ts = svc:now(),
		}
	elseif type(payload) ~= 'table' then
		return {
			ok = false,
			err = 'payload must be a table when provided',
		}
	end

	local topic = t('config', 'mcu')
	conn:retain(topic, payload)
	svc:obs_event('fabric_probe_publish', {
		topic = topic_to_string(topic),
	})

	return {
		ok = true,
		topic = topic,
		retain = true,
		payload = payload,
	}
end

local function call_peer_hal_dump(conn, svc, req)
	local peer_id = req.peer_id
	if peer_id == nil or peer_id == '' then
		peer_id = 'mcu-1'
	elseif type(peer_id) ~= 'string' then
		return {
			ok = false,
			err = 'peer_id must be a string when provided',
		}
	end

	local payload = req.payload
	if payload == nil then
		payload = {}
	elseif type(payload) ~= 'table' then
		return {
			ok = false,
			err = 'payload must be a table when provided',
		}
	end

	local timeout_s = req.timeout_s
	if timeout_s == nil then
		timeout_s = 5.0
	elseif type(timeout_s) ~= 'number' or timeout_s <= 0 then
		return {
			ok = false,
			err = 'timeout_s must be a positive number when provided',
		}
	end

	local topic = t('rpc', 'peer', peer_id, 'hal', 'dump')
	local reply, err = conn:call(topic, payload, { timeout = timeout_s })
	svc:obs_event('fabric_probe_call', {
		topic = topic_to_string(topic),
		peer_id = peer_id,
		ok = (reply ~= nil),
	})

	if reply == nil then
		return {
			ok = false,
			err = tostring(err or 'rpc_failed'),
			topic = topic,
			peer_id = peer_id,
		}
	end

	return {
		ok = true,
		topic = topic,
		peer_id = peer_id,
		reply = reply,
	}
end

local function spawn_rpc_endpoint(conn, svc, method, handler)
	local topic = t('rpc', svc.name, method)
	local ep = conn:bind(topic, { queue_len = 8 })

	fibers.spawn(function()
		while true do
			local msg, err = perform(ep:recv_op())
			if not msg then
				svc:obs_log('warn', {
					what = 'rpc_endpoint_closed',
					method = method,
					err = tostring(err),
				})
				return
			end

			local req, rerr = normalise_probe_req(msg.payload)
			local out
			if req == nil then
				out = { ok = false, err = rerr }
			else
				out = handler(conn, svc, req)
			end

			local ok, reason = reply_best_effort(conn, msg, out)
			if not ok then
				svc:obs_log('warn', {
					what = 'rpc_reply_failed',
					method = method,
					reason = tostring(reason),
				})
			end
		end
	end)
end

local function auto_probe_enabled()
	local v = os.getenv('DEVICECODE_MONITOR_FABRIC_AUTO_PROBE')
	if v == nil or v == '' then
		return (os.getenv('DEVICECODE_ENV') or 'dev') ~= 'prod'
	end
	v = tostring(v):lower()
	return not (v == '0' or v == 'false' or v == 'no' or v == 'off')
end

local function spawn_auto_fabric_probe(conn, svc)
	if not auto_probe_enabled() then
		return
	end

	local sub_link = conn:subscribe({ 'state', 'fabric', 'link', '#' }, {
		queue_len = 32,
		full = 'drop_oldest',
	})

	local seen = {}

	local function dump_reply_applied(dump)
		if type(dump) ~= 'table' or dump.ok ~= true then
			return false
		end
		local reply = dump.reply
		if type(reply) ~= 'table' then
			return false
		end
		if reply.applied == true then
			return true
		end
		return type(reply.config_count) == 'number' and reply.config_count > 0
	end

	fibers.spawn(function()
		while true do
			local msg, err = perform(sub_link:recv_op())
			if not msg then
				svc:obs_log('warn', {
					what = 'fabric_auto_probe_stopped',
					err = tostring(err),
				})
				return
			end

				local payload = msg.payload
				if type(payload) == 'table' and payload.ready == true then
					local link_id = payload.link_id or msg.topic[4] or 'unknown'
					local peer_id = payload.peer_id or 'mcu-1'
					local peer_sid = payload.peer_sid or ''
					local key = tostring(link_id) .. '|' .. tostring(peer_id) .. '|' .. tostring(peer_sid)

					if not seen[key] then
						seen[key] = true

						fibers.spawn(function()
							svc:obs_event('fabric_auto_probe_started', {
								link_id = link_id,
								peer_id = peer_id,
								peer_sid = peer_sid,
							})

							fibers.perform(sleep.sleep_op(AUTO_PROBE_START_DELAY_S))

							local pub = publish_config_mcu(conn, svc, {
								payload = {
									devices = empty_array(),
									pollers = empty_array(),
								},
							})
							svc:obs_event('fabric_auto_probe_publish', pub)

							local dump
							local attempts = 0
							for attempt = 1, AUTO_PROBE_MAX_ATTEMPTS do
								attempts = attempt
								dump = call_peer_hal_dump(conn, svc, {
									peer_id = peer_id,
									timeout_s = 1.0,
									payload = { ask = 'status', source = 'monitor_auto_probe' },
								})
								if dump_reply_applied(dump) then
									break
								end
								if attempt < AUTO_PROBE_MAX_ATTEMPTS then
									fibers.perform(sleep.sleep_op(AUTO_PROBE_RETRY_DELAY_S))
								end
							end
							if type(dump) == 'table' then
								dump.attempts = attempts
							end
							svc:obs_event('fabric_auto_probe_dump', dump)
						end)
					end
				end
			end
		end)
end

-- pretty printer kept as-is (it is purely a dev/operator tool)

local function is_array(t)
	local n = 0
	for _ in ipairs(t) do n = n + 1 end
	for k in pairs(t) do
		if type(k) ~= 'number' or k < 1 or k % 1 ~= 0 or k > n then
			return false
		end
	end
	return true
end

local function sort_keys(t)
	local ks = {}
	for k in pairs(t) do ks[#ks + 1] = k end
	table.sort(ks, function(a, b)
		local ta, tb = type(a), type(b)
		if ta ~= tb then return ta < tb end
		if ta == 'number' then return a < b end
		return tostring(a) < tostring(b)
	end)
	return ks
end

local function pretty(v, opts, depth, seen)
	opts            = opts or {}
	depth           = depth or 0
	seen            = seen or {}

	local max_depth = opts.max_depth or 5
	local max_items = opts.max_items or 30

	local tv = type(v)
	if tv == 'string' then return string.format('%q', v) end
	if tv == 'number' or tv == 'boolean' or tv == 'nil' then return tostring(v) end
	if tv ~= 'table' then return ('<%s:%s>'):format(tv, tostring(v)) end

	if seen[v] then return '<cycle>' end
	seen[v] = true

	if depth >= max_depth then
		seen[v] = nil
		return '{...}'
	end

	local out = {}
	local count = 0

	if is_array(v) then
		out[#out + 1] = '['
		for i = 1, #v do
			count = count + 1
			if count > max_items then out[#out + 1] = '...'; break end
			out[#out + 1] = pretty(v[i], opts, depth + 1, seen)
		end
		out[#out + 1] = ']'
	else
		out[#out + 1] = '{'
		local keys = sort_keys(v)
		for i = 1, #keys do
			count = count + 1
			if count > max_items then out[#out + 1] = '...'; break end
			local k = keys[i]
			local kk = (type(k) == 'string') and k or ('[' .. tostring(k) .. ']')
			out[#out + 1] = tostring(kk) .. '=' .. pretty(v[k], opts, depth + 1, seen)
		end
		out[#out + 1] = '}'
	end

	seen[v] = nil
	return table.concat(out, ' ')
end

function topic_to_string(topic)
	local parts = {}
	for i = 1, #topic do parts[#parts + 1] = tostring(topic[i]) end
	return table.concat(parts, '/')
end

local function fmt_time()
	local mono = runtime.now and runtime.now() or 0
	return os.date('%Y-%m-%d %H:%M:%S') .. string.format(' (mono=%.3f)', mono)
end

local function classify(msg)
	local t = msg.topic or {}
	local kind = t[2]
	if kind == 'log' then
		return 'log', t[3] or 'unknown', t[4] or 'info'
	elseif kind == 'metric' then
		return 'metric', t[3] or 'unknown', nil
	elseif kind == 'event' then
		return 'event', t[3] or 'unknown', t[4] or 'event'
	elseif kind == 'state' then
		return 'state', t[3] or 'unknown', t[4] or 'state'
	end
	return 'obs', t[2] or 'unknown', nil
end

local function format_line(msg)
	local kind, svc, lvl_or_name = classify(msg)

	local payload = msg.payload
	local payload_s = (type(payload) == 'string') and payload
		or pretty(payload, { max_depth = 6, max_items = 40 })

	if kind == 'log' then
		return string.format('%s  LOG  %-10s %-5s  %s',
			fmt_time(), tostring(svc), tostring(lvl_or_name or 'info'), payload_s)
	end

	if kind == 'metric' then
		return string.format('%s  MET  %-10s %-24s  %s',
			fmt_time(), tostring(svc), topic_to_string(msg.topic), payload_s)
	end

	if kind == 'event' then
		return string.format('%s  EVT  %-10s %-12s  %s',
			fmt_time(), tostring(svc), tostring(lvl_or_name or 'event'), payload_s)
	end

	if kind == 'state' then
		return string.format('%s  STA  %-10s %-12s  %s',
			fmt_time(), tostring(svc), tostring(lvl_or_name or 'state'), payload_s)
	end

	return string.format('%s  OBS  %-10s %-24s  %s',
		fmt_time(), tostring(svc), topic_to_string(msg.topic), payload_s)
end

function M.start(conn, ctx)
	ctx = ctx or {}
	local svc = base.new(conn, { name = ctx.name or 'monitor', env = ctx.env })
	local name = svc.name

	local out = file.fdopen(1, 'w', 'stdout')
	out:setvbuf('line')

	local function write_line(line)
		local which, a, b = perform(named_choice {
			wrote = out:write_op(line, '\n'),
			timeout = sleep.sleep_op(0.5):wrap(function () return nil, 'write timeout' end),
		})
		if which == 'wrote' then
			local n, err = a, b
			if n == nil and err ~= nil then error(err) end
		end
	end

	local rpc_methods = {
		'fabric_publish_config_mcu',
		'fabric_dump_peer_hal',
	}

	svc:status('running', {
		subscribed = { 'obs/#', 'peer/#' },
		rpc_root = 'rpc/' .. name,
		rpc_methods = rpc_methods,
	})

	local sub_obs = conn:subscribe({ 'obs', '#' }, { queue_len = 500, full = 'drop_oldest' })
	local sub_peer = conn:subscribe({ 'peer', '#' }, { queue_len = 500, full = 'drop_oldest' })

	spawn_rpc_endpoint(conn, svc, 'fabric_publish_config_mcu', publish_config_mcu)
	spawn_rpc_endpoint(conn, svc, 'fabric_dump_peer_hal', call_peer_hal_dump)
	spawn_auto_fabric_probe(conn, svc)

	write_line(string.format('%s  STA  %-10s %-12s  %s',
		fmt_time(), name, 'start',
		'subscribed to obs/# and peer/#; rpc on rpc/' .. name .. '/{fabric_publish_config_mcu,fabric_dump_peer_hal}'))

	while true do
		local which, msg, err = perform(named_choice {
			obs  = sub_obs:recv_op(),
			peer = sub_peer:recv_op(),
		})

		if msg == nil then
			write_line(string.format('%s  STA  %-10s %-12s  %s',
				fmt_time(), name, 'stop', ('subscription ended: %s (%s)'):format(tostring(err), tostring(which))))
			return
		end

		write_line(format_line(msg))
	end
end

return M
