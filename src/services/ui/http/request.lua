-- services/ui/http/request.lua
--
-- One HTTP request lifetime.

local fibers        = require 'fibers'
local response_mod  = require 'services.ui.http.response'
local routes        = require 'services.ui.http.routes'
local static        = require 'services.ui.http.static'
local sse           = require 'services.ui.http.sse'
local queries       = require 'services.ui.queries'
local auth          = require 'services.ui.auth'
local user_operation = require 'services.ui.user_operation'
local upload        = require 'services.ui.update.upload'
local resource      = require 'devicecode.support.resource'

local cjson = require 'cjson.safe'

local ok_http_headers, http_headers = pcall(require, 'services.http.headers')
if not ok_http_headers then http_headers = nil end

local M = {}

local function header_one(headers, name)
	if not headers then return nil end
	if http_headers and type(http_headers.get_one) == 'function' then
		local v = http_headers.get_one(headers, name)
		if v ~= nil then return v end
	end
	if type(headers.get) == 'function' then
		local ok, v = pcall(function () return headers:get(string.lower(name)) end)
		if ok and v ~= nil then return v end
	end
	if type(headers) == 'table' then
		return headers[name] or headers[string.lower(name)] or headers[string.upper(name)]
	end
	return nil
end

local function ensure_request_metadata(ctx)
	if type(ctx) ~= 'table' then return ctx end
	if ctx.method ~= nil and (ctx.path ~= nil or ctx.uri ~= nil) then return ctx end
	if type(ctx.method) == 'function' and type(ctx.path) == 'function' then return ctx end
	if type(ctx.get_headers_op) ~= 'function' then return ctx end

	local h, err = fibers.perform(ctx:get_headers_op())
	if not h then error(err or 'request headers unavailable', 0) end
	ctx.headers = ctx.headers or h
	ctx.method = ctx.method or header_one(h, ':method') or header_one(h, 'method') or 'GET'
	ctx.path = ctx.path or ctx.uri or header_one(h, ':path') or '/'
	return ctx
end


local function ctx_header(ctx, name)
	return ctx and header_one(ctx.headers, name)
end


local function perform_response(ev)
	-- HTTP response writes may yield through the transport bridge.  They are
	-- performed only inside the HTTP request scope, where that wait is visible.
	local ok, err = fibers.perform(ev)
	if ok ~= true then
		error(err or 'response write failed', 0)
	end
	return true
end

local function body_table(ctx)
	if type(ctx.body) == 'table' then return ctx.body end
	if type(ctx.json) == 'table' then return ctx.json end
	if type(ctx.read_body_as_string_op) == 'function' then
		local raw, read_err = fibers.perform(ctx:read_body_as_string_op())
		if raw == nil then return {}, read_err or 'body_read_failed' end
		if raw == '' then
			ctx.json = {}
			return ctx.json
		end

		local decoded, decode_err = cjson.decode(raw)
		if type(decoded) ~= 'table' then
			return {}, decode_err or 'json_body_must_be_object'
		end
		ctx.json = decoded
		return decoded
	end
	return {}
end

local function copy_table(t)
	local out = {}
	for k, v in pairs(t or {}) do out[k] = v end
	return out
end

local function session_id_from(ctx)
	return ctx.session_id
		or (ctx.cookies and (ctx.cookies.sid or ctx.cookies.session or ctx.cookies.ui_session))
		or ctx_header(ctx, 'x-session-id')
end

local function principal_from(ctx, deps)
	local sid = session_id_from(ctx)
	if sid and deps.sessions then
		local sess = deps.sessions:get(sid)
		if sess then return sess.principal, sess end
	end
	return nil, nil
end

local function handle_read(owner, route, deps)
	local model = assert(deps.model, 'HTTP read requires model')
	local snap = model:snapshot()
	local result
	if route.query == 'all' then
		result = queries.all(snap)
	elseif route.query == 'services' then
		result = queries.services_snapshot(snap)
	elseif route.query == 'fabric' then
		result = queries.fabric_status(snap)
	elseif route.query == 'fabric_link' then
		result = queries.fabric_link_status(snap, route.link_id)
	elseif route.query == 'update_job' then
		result = queries.update_job_status(snap, route.job_id)
	elseif route.query == 'topic' then
		result = queries.topic(snap, route.topic)
	else
		result = queries.all(snap)
	end
	if result == nil then
		perform_response(owner:reply_error_op(404, 'not_found'))
		return { status = 'not_found', route = 'read' }
	end
	perform_response(owner:reply_json_op(200, result))
	return { status = 'ok', route = 'read' }
end

local function handle_login(owner, ctx, deps)
	local body, body_err = body_table(ctx)
	if body_err ~= nil then
		perform_response(owner:reply_error_op(400, body_err))
		return { status = 'bad_request', err = body_err }
	end
	local principal, err = auth.verify(deps.auth, body)
	if not principal then
		perform_response(owner:reply_error_op(401, err or 'unauthenticated'))
		return { status = 'unauthenticated' }
	end
	local sess = assert(deps.sessions, 'login requires sessions'):create(principal, {
		data = { user_agent = ctx_header(ctx, 'user-agent') },
	})
	perform_response(owner:reply_json_op(200, { session = sess, session_id = sess.id }))
	return { status = 'ok', session_id = sess.id }
end

local function handle_logout(owner, ctx, deps)
	local sid = session_id_from(ctx)
	if sid and deps.sessions then deps.sessions:delete(sid) end
	perform_response(owner:reply_json_op(200, { ok = true }))
	return { status = 'ok' }
end

local function handle_session_get(owner, ctx, deps)
	local sid = session_id_from(ctx)
	local sess = sid and deps.sessions and deps.sessions:get(sid) or nil
	if not sess then
		perform_response(owner:reply_error_op(401, 'unauthenticated'))
		return { status = 'unauthenticated' }
	end
	perform_response(owner:reply_json_op(200, { session = sess }))
	return { status = 'ok' }
end

local function handle_command(scope, owner, ctx, route, deps)
	local principal = principal_from(ctx, deps)
	if principal == nil then
		perform_response(owner:reply_error_op(401, 'unauthenticated'))
		return { status = 'unauthenticated' }
	end
	local body, body_err = body_table(ctx)
	if body_err ~= nil then
		perform_response(owner:reply_error_op(400, body_err))
		return { status = 'bad_request', err = body_err }
	end
	local st, _rep, result_or_primary = fibers.perform(user_operation.run_op {
		principal = principal,
		connect = deps.connect,
		bus = deps.bus,
		timeout = deps.command_timeout or 5.0,
		run_op = function (_, conn)
			return conn:call_op(route.topic, body, { timeout = deps.command_timeout or 5.0 })
				:wrap(function (value, call_err)
					if value == nil then return nil, call_err or 'upstream_failed' end
					return { value = value }, nil
				end)
		end,
	})
	if st ~= 'ok' then
		perform_response(owner:reply_error_op(nil, result_or_primary))
		return { status = 'failed', err = result_or_primary }
	end
	local result = result_or_primary
	perform_response(owner:reply_json_op(200, result))
	return { status = 'ok' }
end

local function update_job_method(op_name)
	op_name = tostring(op_name or '')
	if op_name == 'commit' then return 'commit-job' end
	return nil
end

local function handle_update_job_action(scope, owner, ctx, route, deps)
	local principal = principal_from(ctx, deps)
	if principal == nil then
		perform_response(owner:reply_error_op(401, 'unauthenticated'))
		return { status = 'unauthenticated' }
	end
	local body, body_err = body_table(ctx)
	if body_err ~= nil then
		perform_response(owner:reply_error_op(400, body_err))
		return { status = 'bad_request', err = body_err }
	end
	local method = update_job_method(body.op or body.action)
	if method == nil then
		perform_response(owner:reply_error_op(400, 'unsupported_update_job_action'))
		return { status = 'bad_request', err = 'unsupported_update_job_action' }
	end
	local payload = {
		job_id = route.job_id,
		id = route.job_id,
	}
	local st, _rep, result_or_primary = fibers.perform(user_operation.run_op {
		principal = principal,
		connect = deps.connect,
		bus = deps.bus,
		timeout = deps.command_timeout or 5.0,
		run_op = function (_, conn)
			return conn:call_op({ 'cap', 'update-manager', 'main', 'rpc', method }, payload, {
				timeout = deps.command_timeout or 5.0,
			}):wrap(function (value, call_err)
				if value == nil then return nil, call_err or 'upstream_failed' end
				return value, nil
			end)
		end,
	})
	if st ~= 'ok' then
		perform_response(owner:reply_error_op(nil, result_or_primary))
		return { status = 'failed', err = result_or_primary }
	end
	perform_response(owner:reply_json_op(200, result_or_primary))
	return { status = 'ok' }
end

local function handle_upload(scope, owner, ctx, deps)
	local principal = principal_from(ctx, deps)
	if principal == nil then
		perform_response(owner:reply_error_op(401, 'unauthenticated'))
		return { status = 'unauthenticated' }
	end

	local opts = copy_table(deps.update or deps)
	opts.principal = principal
	opts.connect = opts.connect or deps.connect
	opts.bus = opts.bus or deps.bus

	return upload.run(scope, owner, ctx, opts)
end

function M.run(scope, ctx, deps)
	deps = deps or {}
	local owner = response_mod.new(ctx, { encode = deps.encode_json })

	scope:finally(function (_, status, primary)
		resource.terminate_checked(owner, primary or status or 'request_closed', 'HTTP response termination')
	end)

	ensure_request_metadata(ctx)
	local route = routes.decode(ctx)

	if route.kind == 'read' then
		return handle_read(owner, route, deps)
	elseif route.kind == 'login' then
		return handle_login(owner, ctx, deps)
	elseif route.kind == 'logout' then
		return handle_logout(owner, ctx, deps)
	elseif route.kind == 'session_get' then
		return handle_session_get(owner, ctx, deps)
	elseif route.kind == 'command' then
		return handle_command(scope, owner, ctx, route, deps)
	elseif route.kind == 'update_job_action' then
		return handle_update_job_action(scope, owner, ctx, route, deps)
	elseif route.kind == 'upload' then
		return handle_upload(scope, owner, ctx, deps)
	elseif route.kind == 'sse' then
		return sse.run(scope, owner, route, deps)
	elseif route.kind == 'static' then
		return static.run(scope, owner, route, deps)
	else
		perform_response(owner:reply_error_op(404, 'not_found'))
		return { status = 'not_found' }
	end
end

return M
