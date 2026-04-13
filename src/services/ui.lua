-- services/ui.lua
--
-- UI service for the dev branch.
--
-- Responsibilities:
--   * local login/session handling
--   * act on behalf of logged-in users via opts.connect(principal)
--   * read retained config/state topics
--   * call service RPCs
--   * expose fabric firmware helpers through the API layer
--
-- Deliberately does NOT:
--   * discover HAL directly
--   * call HAL capabilities directly by default
--   * own business policy for other services

local fibers = require 'fibers'
local sleep  = require 'fibers.sleep'
local op     = require 'fibers.op'
local uuid   = require 'uuid'
local safe   = require 'coxpcall'

local base  = require 'devicecode.service_base'
local authz = require 'devicecode.authz'

local perform      = fibers.perform
local named_choice = fibers.named_choice

local M = {}

local function t(...) return { ... } end

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

local function copy_plain(v, seen)
	if type(v) ~= 'table' then
		return v
	end
	if getmetatable(v) ~= nil then
		error('copy_plain: metatables are not supported', 2)
	end

	seen = seen or {}
	if seen[v] then
		return seen[v]
	end

	local out = {}
	seen[v] = out

	for k, x in pairs(v) do
		out[copy_plain(k, seen)] = copy_plain(x, seen)
	end

	return out
end

local function temporary_verify_login(username, password)
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
		local tnow = now()
		for sid, rec in pairs(by_id) do
			if rec.expires_at <= tnow then
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

local function with_temp_sub(conn, topic, opts, fn)
	local sub = conn:subscribe(topic, opts or { queue_len = 1, full = 'reject_newest' })
	local ok, a, b = safe.pcall(fn, sub)
	pcall(function() sub:unsubscribe() end)
	if not ok then
		return nil, tostring(a)
	end
	return a, b
end

local function recv_one_retained(conn, topic, timeout_s)
	return with_temp_sub(conn, topic, { queue_len = 1, full = 'reject_newest' }, function(sub)
		local which, a, b = perform(named_choice {
			msg   = sub:recv_op(),
			timer = sleep.sleep_op(timeout_s or 2.0):wrap(function() return true end),
		})

		if which == 'timer' then
			return nil, 'timeout'
		end

		local msg, err = a, b
		if not msg then
			return nil, err or 'subscription closed'
		end

		return msg.payload, nil
	end)
end

local function list_snapshot(conn, root_topic, timeout_s, queue_len)
	return with_temp_sub(conn, root_topic, {
		queue_len = queue_len or 128,
		full      = 'drop_oldest',
	}, function(sub)
		local out = {}

		while true do
			local which, a, b = perform(named_choice {
				msg   = sub:recv_op(),
				timer = sleep.sleep_op(timeout_s or 0.25):wrap(function() return true end),
			})

			if which == 'timer' then
				break
			end

			local msg, err = a, b
			if not msg then
				if err ~= nil then
					break
				end
				break
			end

			out[#out + 1] = {
				topic   = copy_plain(msg.topic),
				payload = copy_plain(msg.payload),
				id      = msg.id,
			}
		end

		return out, nil
	end)
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

		conn:publish(t('obs', 'audit', 'ui', 'login'), {
			user = principal.id,
			t    = now(),
		})

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
			conn:publish(t('obs', 'audit', 'ui', 'logout'), {
				user = rec.principal.id,
				t    = now(),
			})
		end

		sessions:delete(session_id)
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

		return with_user_conn(rec.principal, function(user_conn)
			return recv_one_retained(user_conn, t('cfg', service_name), 2.0)
		end)
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
				t('config', service_name, 'set'),
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

		conn:publish(t('obs', 'audit', 'ui', 'config_set'), {
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

		return with_user_conn(rec.principal, function(user_conn)
			return recv_one_retained(user_conn, t('svc', service_name, 'status'), 2.0)
		end)
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
				t('rpc', service_name, method_name),
				copy_plain(payload or {}),
				{ timeout = timeout_s or 5.0 }
			)
		end)

		if out == nil and rerr ~= nil then
			return nil, rerr
		end

		conn:publish(t('obs', 'audit', 'ui', 'rpc_call'), {
			user    = rec.principal.id,
			service = service_name,
			method  = method_name,
			ok      = (out ~= nil),
			t       = now(),
		})

		return out, nil
	end

	function api.fabric_status(session_id)
		local rec, err = require_session(session_id)
		if not rec then
			return nil, err
		end

		return with_user_conn(rec.principal, function(user_conn)
			local main, merr = recv_one_retained(user_conn, t('state', 'fabric', 'main'), 2.0)
			if not main and merr then
				return nil, merr
			end

			local links, lerr = list_snapshot(user_conn, t('state', 'fabric', 'link', '#'), 0.20, 128)
			if not links and lerr then
				return nil, lerr
			end

			return {
				main  = main,
				links = links or {},
			}, nil
		end)
	end

	function api.fabric_link_status(session_id, link_id)
		local rec, err = require_session(session_id)
		if not rec then
			return nil, err
		end
		if type(link_id) ~= 'string' or link_id == '' then
			return nil, 'link_id must be a non-empty string'
		end

		return with_user_conn(rec.principal, function(user_conn)
			return recv_one_retained(user_conn, t('state', 'fabric', 'link', link_id), 2.0)
		end)
	end

	function api.capability_snapshot(session_id)
		local rec, err = require_session(session_id)
		if not rec then
			return nil, err
		end

		return with_user_conn(rec.principal, function(user_conn)
			local dev_meta  = list_snapshot(user_conn, t('dev', '#'), 0.20, 256) or {}
			local cap_meta  = list_snapshot(user_conn, t('cap', '#'), 0.20, 256) or {}
			return {
				dev = dev_meta,
				cap = cap_meta,
			}, nil
		end)
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
			or type(source.sha256hex) ~= 'function' then
			return nil, 'source is not a valid blob source'
		end

		meta = type(meta) == 'table' and copy_plain(meta) or {}
		if meta.kind == nil then meta.kind = 'firmware.rp2350' end
		if meta.name == nil and type(source.name) == 'function' then meta.name = source:name() end
		if meta.format == nil and type(source.format) == 'function' then meta.format = source:format() or 'bin' end
		if meta.format == nil then meta.format = 'bin' end

		local out, ferr = with_user_conn(rec.principal, function(user_conn)
			return user_conn:call(
				t('rpc', 'fabric', 'send_firmware'),
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

		conn:publish(t('obs', 'audit', 'ui', 'firmware_send'), {
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

		local out, terr = with_user_conn(rec.principal, function(user_conn)
			return user_conn:call(
				t('rpc', 'fabric', 'transfer_status'),
				{ transfer_id = transfer_id },
				{ timeout = 5.0 }
			)
		end)

		if out == nil then
			return nil, terr or 'transfer_status failed'
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

		local out, terr = with_user_conn(rec.principal, function(user_conn)
			return user_conn:call(
				t('rpc', 'fabric', 'transfer_abort'),
				{ transfer_id = transfer_id },
				{ timeout = 5.0 }
			)
		end)

		if out == nil then
			return nil, terr or 'transfer_abort failed'
		end

		conn:publish(t('obs', 'audit', 'ui', 'transfer_abort'), {
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
			perform(sleep.sleep_op(30.0))
		end
	end)

	conn:retain(t('svc', svc.name, 'announce'), {
		role = 'ui',
		auth = 'local-session',
	})

	svc:status('running')
	svc:obs_log('info', { what = 'ui_ready' })

	return opts.run_http(svc, api, opts)
end

return M
