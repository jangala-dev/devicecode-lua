-- services/ui.lua
--
-- UI service for the newer runtime shape.
--
-- Responsibilities:
--   * local login/session handling
--   * act on behalf of logged-in users via opts.connect(principal)
--   * expose retained snapshots for cfg/svc/state/cap/dev topics
--   * expose config mutation and generic RPC helpers
--   * expose fabric firmware transfer helpers
--
-- Expected opts:
--   * connect(principal) -> bus connection
--   * run_http(svc, api, opts) -> transport runner
--
-- First pass policy:
--   * admin-only access
--   * session-backed, in-process auth
--   * retained reads are pulled by transient subscriptions

local fibers = require 'fibers'
local sleep  = require 'fibers.sleep'
local uuid   = require 'uuid'

local safe   = require 'coxpcall'

local base   = require 'devicecode.service_base'
local authz  = require 'devicecode.authz'

local M = {}

local perform      = fibers.perform
local named_choice = fibers.named_choice

local function now()
	return fibers.now()
end

local function getenv_nonempty(name)
	local v = os.getenv(name)
	if v == nil or v == '' then
		return nil
	end
	return v
end

local function copy_plain(t, seen)
	if type(t) ~= 'table' then
		return t
	end
	if getmetatable(t) ~= nil then
		error('copy_plain: metatables are not supported', 2)
	end

	seen = seen or {}
	if seen[t] then
		return seen[t]
	end

	local out = {}
	seen[t] = out

	for k, v in pairs(t) do
		out[copy_plain(k, seen)] = copy_plain(v, seen)
	end

	return out
end

local function topic_to_string(topic)
	if type(topic) ~= 'table' then
		return tostring(topic)
	end
	local parts = {}
	for i = 1, #topic do
		parts[#parts + 1] = tostring(topic[i])
	end
	return table.concat(parts, '/')
end

local function msgs_to_topic_map(msgs)
	local out = {}
	for i = 1, #(msgs or {}) do
		local msg = msgs[i]
		if type(msg) == 'table' and type(msg.topic) == 'table' then
			out[topic_to_string(msg.topic)] = msg.payload
		end
	end
	return out
end

local function msgs_to_service_map(msgs, service_idx)
	local out = {}
	for i = 1, #(msgs or {}) do
		local msg = msgs[i]
		local topic = msg and msg.topic
		local svc = type(topic) == 'table' and topic[service_idx] or nil
		if type(svc) == 'string' and svc ~= '' then
			out[svc] = msg.payload
		end
	end
	return out
end

local function last_payload(msgs)
	if type(msgs) ~= 'table' or #msgs == 0 then
		return nil
	end
	local msg = msgs[#msgs]
	return msg and msg.payload or nil
end

local function temporary_verify_login(username, password)
	-- Temporary bootstrap mechanism:
	--   * only "admin" is recognised
	--   * password comes from DEVICECODE_UI_ADMIN_PASSWORD
	--
	-- Replace this with a proper auth service and slow password hashes.
	local expected = getenv_nonempty('DEVICECODE_UI_ADMIN_PASSWORD')
	if not expected then
		return nil, 'ui admin password is not configured'
	end

	if username ~= 'admin' then
		return nil, 'invalid credentials'
	end

	if type(password) ~= 'string' or password ~= expected then
		return nil, 'invalid credentials'
	end

	return authz.user_principal('admin', { roles = { 'admin' } }), nil
end

local function make_session_store()
	local by_id = {}
	local store = {}

	function store:create(principal, ttl_s)
		local sid = tostring(uuid.new())
		local rec = {
			id         = sid,
			principal  = principal,
			created_at = now(),
			expires_at = now() + (ttl_s or 3600),
		}
		by_id[sid] = rec
		return rec
	end

	function store:get(session_id)
		local rec = by_id[session_id]
		if not rec then
			return nil
		end
		if rec.expires_at <= now() then
			by_id[session_id] = nil
			return nil
		end
		return rec
	end

	function store:touch(session_id, ttl_s)
		local rec = self:get(session_id)
		if not rec then
			return nil
		end
		rec.expires_at = now() + (ttl_s or 3600)
		return rec
	end

	function store:delete(session_id)
		by_id[session_id] = nil
		return true
	end

	function store:prune()
		local t = now()
		for sid, rec in pairs(by_id) do
			if rec.expires_at <= t then
				by_id[sid] = nil
			end
		end
	end

	function store:count()
		local n = 0
		for _ in pairs(by_id) do n = n + 1 end
		return n
	end

	return store
end

---@param user_conn any
---@param topic table
---@param opts? { timeout_s?: number, idle_s?: number, queue_len?: integer }
---@return table
local function collect_retained(user_conn, topic, opts)
	opts = opts or {}

	local timeout_s = (type(opts.timeout_s) == 'number' and opts.timeout_s > 0) and opts.timeout_s or 1.0
	local idle_s    = (type(opts.idle_s) == 'number' and opts.idle_s > 0) and opts.idle_s or 0.05
	local queue_len = (type(opts.queue_len) == 'number' and opts.queue_len >= 0) and opts.queue_len or 64

	local sub = user_conn:subscribe(topic, {
		queue_len = queue_len,
		full      = 'drop_oldest',
	})

	local msgs = {}
	local deadline = now() + timeout_s

	while true do
		local tnow = now()
		local remain = deadline - tnow
		if remain <= 0 then
			break
		end

		local arms = {
			recv = sub:recv_op(),
			deadline = sleep.sleep_op(remain):wrap(function() return true end),
		}

		if #msgs > 0 then
			arms.idle = sleep.sleep_op(idle_s):wrap(function() return true end)
		end

		local which, a = perform(named_choice(arms))

		if which == 'recv' then
			local msg = a
			if msg == nil then
				break
			end
			msgs[#msgs + 1] = msg
		else
			break
		end
	end

	pcall(function() sub:unsubscribe() end)
	return msgs
end

function M.start(conn, opts)
	opts = opts or {}

	local svc = base.new(conn, {
		name = opts.name or 'ui',
		env  = opts.env,
	})

	if type(opts.connect) ~= 'function' then
		error('ui: opts.connect(principal) is required', 2)
	end

	local verify_login = opts.verify_login or temporary_verify_login
	local session_ttl_s = (type(opts.session_ttl_s) == 'number' and opts.session_ttl_s > 0)
		and opts.session_ttl_s
		or 3600

	local sessions = make_session_store()

	svc:status('starting')
	svc:obs_log('info', { what = 'start_entered' })

	conn:retain({ 'svc', svc.name, 'announce' }, {
		role = 'ui',
		auth = 'local-session',
		caps = {
			session_auth        = true,
			config_get          = true,
			config_set          = true,
			service_status      = true,
			capability_snapshot = true,
			rpc_call            = true,
			fabric_status       = true,
			firmware_push       = true,
		},
	})

	local function retain_ui_state(fields)
		local payload = {
			status   = 'running',
			sessions = sessions:count(),
			t        = now(),
		}
		for k, v in pairs(fields or {}) do
			payload[k] = v
		end
		conn:retain({ 'state', 'ui', 'main' }, payload)
	end

	local function with_user_conn(principal, fn)
		local user_conn = opts.connect(principal)
		local ok, a, b, c = safe.pcall(fn, user_conn)
		pcall(function() user_conn:disconnect() end)
		if not ok then
			return nil, tostring(a)
		end
		return a, b, c
	end

	local function require_session(session_id)
		if type(session_id) ~= 'string' or session_id == '' then
			return nil, 'missing session'
		end

		local rec = sessions:get(session_id)
		if not rec then
			return nil, 'invalid or expired session'
		end

		sessions:touch(session_id, session_ttl_s)
		return rec, nil
	end

	local function get_exact_payload(principal, topic, timeout_s)
		local msgs, err = with_user_conn(principal, function(user_conn)
			return collect_retained(user_conn, topic, { timeout_s = timeout_s or 1.0, idle_s = 0.05, queue_len = 8 })
		end)
		if msgs == nil then
			return nil, err or 'read failed'
		end

		local payload = last_payload(msgs)
		if payload == nil then
			return nil, 'not found'
		end
		return payload, nil
	end

	local function get_snapshot_map(principal, topic, timeout_s, idle_s)
		local msgs, err = with_user_conn(principal, function(user_conn)
			return collect_retained(user_conn, topic, {
				timeout_s = timeout_s or 1.0,
				idle_s    = idle_s or 0.05,
				queue_len = 128,
			})
		end)
		if msgs == nil then
			return nil, err or 'read failed'
		end
		return msgs, nil
	end

	local api = {}

	function api.login(username, password)
		local principal, err = verify_login(username, password)
		if not principal then
			svc:obs_log('warn', {
				what = 'login_failed',
				user = tostring(username),
				err  = tostring(err),
			})
			return nil, err or 'login failed'
		end

		local rec = sessions:create(principal, session_ttl_s)

		svc:obs_log('info', {
			what = 'login_ok',
			user = tostring(principal.id),
		})

		conn:publish({ 'obs', 'audit', 'ui', 'login' }, {
			user = principal.id,
			t    = now(),
		})

		retain_ui_state()

		return {
			session_id = rec.id,
			user = {
				id    = principal.id,
				kind  = principal.kind,
				roles = copy_plain(principal.roles or {}),
			},
			expires_at = rec.expires_at,
		}, nil
	end

	function api.logout(session_id)
		local rec = sessions:get(session_id)
		if rec then
			conn:publish({ 'obs', 'audit', 'ui', 'logout' }, {
				user = rec.principal.id,
				t    = now(),
			})
		end

		sessions:delete(session_id)
		retain_ui_state()
		return true, nil
	end

	function api.get_session(session_id)
		local rec, err = require_session(session_id)
		if not rec then
			return nil, err
		end

		return {
			session_id = rec.id,
			user = {
				id    = rec.principal.id,
				kind  = rec.principal.kind,
				roles = copy_plain(rec.principal.roles or {}),
			},
			expires_at = rec.expires_at,
		}, nil
	end

	function api.health()
		return {
			service  = svc.name,
			sessions = sessions:count(),
			now      = now(),
		}, nil
	end

	function api.config_get(session_id, service_name)
		local rec, err = require_session(session_id)
		if not rec then
			return nil, err
		end

		if type(service_name) ~= 'string' or service_name == '' then
			return nil, 'service_name must be a non-empty string'
		end

		local payload, gerr = get_exact_payload(rec.principal, { 'cfg', service_name }, 1.0)
		if payload == nil then
			return nil, gerr
		end

		return payload, nil
	end

	function api.config_set(session_id, service_name, data)
		local rec, err = require_session(session_id)
		if not rec then
			return nil, err
		end

		if type(service_name) ~= 'string' or service_name == '' then
			return nil, 'service_name must be a non-empty string'
		end
		if type(data) ~= 'table' or getmetatable(data) ~= nil then
			return nil, 'data must be a plain table'
		end

		local msg, rerr = with_user_conn(rec.principal, function(user_conn)
			return perform(user_conn:request_once_op(
				{ 'config', service_name, 'set' },
				{ data = copy_plain(data) }
			))
		end)

		if msg == nil then
			return nil, rerr or 'config_set failed'
		end

		local out = msg.payload
		if type(out) ~= 'table' then
			return nil, 'config_set returned non-table reply payload'
		end

		conn:publish({ 'obs', 'audit', 'ui', 'config_set' }, {
			user    = rec.principal.id,
			service = service_name,
			ok      = (out.ok == true),
			t       = now(),
		})

		return out, nil
	end

	function api.service_status(session_id, service_name)
		local rec, err = require_session(session_id)
		if not rec then
			return nil, err
		end

		if type(service_name) ~= 'string' or service_name == '' then
			return nil, 'service_name must be a non-empty string'
		end

		local payload, serr = get_exact_payload(rec.principal, { 'svc', service_name, 'status' }, 1.0)
		if payload == nil then
			return nil, serr
		end

		return payload, nil
	end

	function api.fabric_status(session_id)
		local rec, err = require_session(session_id)
		if not rec then
			return nil, err
		end

		local main, merr = get_exact_payload(rec.principal, { 'state', 'fabric', 'main' }, 1.0)
		if main == nil and merr ~= 'not found' then
			return nil, merr
		end

		local link_msgs, lerr = get_snapshot_map(rec.principal, { 'state', 'fabric', 'link', '+' }, 1.0, 0.05)
		if link_msgs == nil then
			return nil, lerr
		end

		local links = msgs_to_service_map(link_msgs, 4)

		return {
			main  = main,
			links = links,
		}, nil
	end

	function api.fabric_link_status(session_id, link_id)
		local rec, err = require_session(session_id)
		if not rec then
			return nil, err
		end

		if type(link_id) ~= 'string' or link_id == '' then
			return nil, 'link_id must be a non-empty string'
		end

		local link, lerr = get_exact_payload(rec.principal, { 'state', 'fabric', 'link', link_id }, 1.0)
		if link == nil and lerr ~= 'not found' then
			return nil, lerr
		end

		local transfer, terr = get_exact_payload(rec.principal, { 'state', 'fabric', 'link', link_id, 'transfer' }, 1.0)
		if transfer == nil and terr ~= 'not found' then
			return nil, terr
		end

		return {
			link     = link,
			transfer = transfer,
		}, nil
	end

	function api.capability_snapshot(session_id)
		local rec, err = require_session(session_id)
		if not rec then
			return nil, err
		end

		local cap_msgs, cerr = get_snapshot_map(rec.principal, { 'cap', '#' }, 1.0, 0.05)
		if cap_msgs == nil then
			return nil, cerr
		end

		local dev_msgs, derr = get_snapshot_map(rec.principal, { 'dev', '#' }, 1.0, 0.05)
		if dev_msgs == nil then
			return nil, derr
		end

		local ann_msgs, aerr = get_snapshot_map(rec.principal, { 'svc', '+', 'announce' }, 1.0, 0.05)
		if ann_msgs == nil then
			return nil, aerr
		end

		local st_msgs, serr = get_snapshot_map(rec.principal, { 'svc', '+', 'status' }, 1.0, 0.05)
		if st_msgs == nil then
			return nil, serr
		end

		return {
			capabilities = msgs_to_topic_map(cap_msgs),
			devices      = msgs_to_topic_map(dev_msgs),
			services = {
				announce = msgs_to_service_map(ann_msgs, 2),
				status   = msgs_to_service_map(st_msgs, 2),
			},
		}, nil
	end

	function api.rpc_call(session_id, service_name, method_name, payload, timeout_s)
		local rec, err = require_session(session_id)
		if not rec then
			return nil, err
		end

		if type(service_name) ~= 'string' or service_name == '' then
			return nil, 'service_name must be a non-empty string'
		end
		if type(method_name) ~= 'string' or method_name == '' then
			return nil, 'method_name must be a non-empty string'
		end
		if payload ~= nil and type(payload) ~= 'table' then
			return nil, 'payload must be a table or nil'
		end

		local out, rerr = with_user_conn(rec.principal, function(user_conn)
			return user_conn:call(
				{ 'rpc', service_name, method_name },
				copy_plain(payload or {}),
				{ timeout = timeout_s or 5.0 }
			)
		end)

		if out == nil and rerr ~= nil then
			return nil, rerr
		end

		conn:publish({ 'obs', 'audit', 'ui', 'rpc_call' }, {
			user    = rec.principal.id,
			service = service_name,
			method  = method_name,
			ok      = (out ~= nil),
			t       = now(),
		})

		return out, nil
	end

	function api.firmware_send(session_id, link_id, source, meta)
		local rec, err = require_session(session_id)
		if not rec then
			return nil, err
		end

		if type(link_id) ~= 'string' or link_id == '' then
			return nil, 'link_id must be a non-empty string'
		end
		if type(source) ~= 'table'
			or type(source.open) ~= 'function'
			or type(source.size) ~= 'function'
			or type(source.sha256hex) ~= 'function'
		then
			return nil, 'source is not a valid blob source'
		end

		meta = type(meta) == 'table' and copy_plain(meta) or {}
		if meta.kind == nil then meta.kind = 'firmware.rp2350' end
		if meta.name == nil and type(source.name) == 'function' then meta.name = source:name() end
		if meta.format == nil and type(source.format) == 'function' then meta.format = source:format() or 'bin' end
		if meta.format == nil then meta.format = 'bin' end

		local out, ferr = with_user_conn(rec.principal, function(user_conn)
			return user_conn:call(
				{ 'rpc', 'fabric', 'send_firmware' },
				{
					link_id = link_id,
					source  = source,
					meta    = meta,
				},
				{ timeout = 10.0 }
			)
		end)

		if out == nil then
			return nil, ferr or 'firmware_send failed'
		end

		conn:publish({ 'obs', 'audit', 'ui', 'firmware_send' }, {
			user     = rec.principal.id,
			link_id  = link_id,
			transfer = out.transfer_id,
			ok       = (out.ok == true),
			t        = now(),
		})

		return out, nil
	end

	function api.transfer_status(session_id, transfer_id)
		local rec, err = require_session(session_id)
		if not rec then
			return nil, err
		end

		if type(transfer_id) ~= 'string' or transfer_id == '' then
			return nil, 'transfer_id must be a non-empty string'
		end

		local out, serr = with_user_conn(rec.principal, function(user_conn)
			return user_conn:call(
				{ 'rpc', 'fabric', 'transfer_status' },
				{ transfer_id = transfer_id },
				{ timeout = 5.0 }
			)
		end)

		if out == nil then
			return nil, serr or 'transfer_status failed'
		end

		return out, nil
	end

	function api.transfer_abort(session_id, transfer_id)
		local rec, err = require_session(session_id)
		if not rec then
			return nil, err
		end

		if type(transfer_id) ~= 'string' or transfer_id == '' then
			return nil, 'transfer_id must be a non-empty string'
		end

		local out, aerr = with_user_conn(rec.principal, function(user_conn)
			return user_conn:call(
				{ 'rpc', 'fabric', 'transfer_abort' },
				{ transfer_id = transfer_id },
				{ timeout = 5.0 }
			)
		end)

		if out == nil then
			return nil, aerr or 'transfer_abort failed'
		end

		conn:publish({ 'obs', 'audit', 'ui', 'transfer_abort' }, {
			user     = rec.principal.id,
			transfer = transfer_id,
			ok       = (out.ok == true),
			t        = now(),
		})

		return out, nil
	end

	if type(opts.run_http) ~= 'function' then
		svc:status('failed', { reason = 'missing run_http transport callback' })
		error('ui: opts.run_http(svc, api, opts) is required', 0)
	end

	fibers.spawn(function()
		while true do
			sessions:prune()
			retain_ui_state()
			perform(sleep.sleep_op(30.0))
		end
	end)

	svc:status('running')
	retain_ui_state()
	svc:obs_log('info', { what = 'ui_ready' })

	-- Expected not to return under normal operation.
	return opts.run_http(svc, api, opts)
end

return M
