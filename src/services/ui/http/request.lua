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

local ok_cjson, cjson = pcall(require, 'cjson.safe')
if not ok_cjson then cjson = require 'cjson' end

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

local function content_type_is_json(v)
	v = tostring(v or ''):lower()
	if v == '' then return false end
	local mime = v:match('^%s*([^;%s]+)') or v
	return mime == 'application/json' or mime:match('%+json$') ~= nil
end

local function body_table(ctx)
	-- Compatibility path for unit tests and internal harnesses which hand a
	-- pre-parsed request body to the UI request boundary.  Real HTTP contexts
	-- must use json_body_table below so parsing and validation remain explicit.
	if type(ctx.body) == 'table' then return ctx.body end
	if type(ctx.json) == 'table' then return ctx.json end
	return {}
end

local function json_body_table(ctx, deps, opts)
	opts = opts or {}
	if type(ctx.body) == 'table' then return ctx.body, nil end
	if type(ctx.json) == 'table' then return ctx.json, nil end
	if type(ctx._ui_json_body) == 'table' then return ctx._ui_json_body, nil end

	local ct = ctx_header(ctx, 'content-type') or ctx_header(ctx, 'Content-Type')
	if opts.require_json_content_type ~= false and not content_type_is_json(ct) then
		return nil, 'unsupported_media_type'
	end

	local raw
	if type(ctx.body_string) == 'string' then
		raw = ctx.body_string
	elseif type(ctx.read_body_as_string_op) == 'function' then
		raw = fibers.perform(ctx:read_body_as_string_op())
	elseif type(ctx.read_chars_op) == 'function' then
		-- Fallback for older HTTP contexts.  This is still one visible wait at the
		-- request boundary; command handlers must not hide further body reads.
		raw = fibers.perform(ctx:read_chars_op((deps and deps.max_json_body_bytes) or 1024 * 1024))
	else
		return nil, 'invalid_body'
	end

	if raw == nil then return nil, 'invalid_body' end
	raw = tostring(raw or '')
	local limit = opts.max_bytes or (deps and deps.max_json_body_bytes) or 1024 * 1024
	if #raw > limit then return nil, 'request_body_too_large' end
	if raw == '' then return {}, nil end

	local obj, derr = cjson.decode(raw)
	if obj == nil then return nil, 'invalid_json' end
	if obj == cjson.null or type(obj) ~= 'table' then return nil, 'invalid_body' end
	ctx._ui_json_body = obj
	return obj, nil
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
	elseif route.query == 'topic' then
		result = queries.topic(snap, route.topic)
	else
		result = queries.all(snap)
	end
	perform_response(owner:reply_json_op(200, result))
	return { status = 'ok', route = 'read' }
end

local function handle_login(owner, ctx, deps)
	local body, berr = json_body_table(ctx, deps, { require_json_content_type = false })
	if not body then
		perform_response(owner:reply_error_op(nil, berr))
		return { status = 'bad_request', err = berr }
	end
	local principal, err = auth.verify(deps.auth, body)
	if not principal then
		perform_response(owner:reply_error_op(401, err or 'unauthenticated'))
		return { status = 'unauthenticated' }
	end
	local sess = assert(deps.sessions, 'login requires sessions'):create(principal, {
		data = { user_agent = ctx_header(ctx, 'user-agent') },
	})
	perform_response(owner:reply_json_op(200, { session = sess }))
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
	if type(route.topic) ~= 'table' or #route.topic == 0 then
		perform_response(owner:reply_error_op(400, 'bad_request'))
		return { status = 'bad_request', err = 'missing_command_topic' }
	end
	local principal = principal_from(ctx, deps)
	if principal == nil then
		perform_response(owner:reply_error_op(401, 'unauthenticated'))
		return { status = 'unauthenticated' }
	end
	local payload, perr = json_body_table(ctx, deps, { require_json_content_type = true })
	if not payload then
		perform_response(owner:reply_error_op(nil, perr))
		return { status = 'bad_request', err = perr }
	end
	local st, _rep, result_or_primary = fibers.perform(user_operation.run_op {
		principal = principal,
		connect = deps.connect,
		bus = deps.bus,
		timeout = deps.command_timeout or 5.0,
		run_op = function (_, conn)
			return conn:call_op(route.topic, payload, { timeout = false })
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
	elseif route.kind == 'upload' then
		local update_deps = deps.update or deps
		if update_deps.require_auth == true then
			local principal = principal_from(ctx, deps)
			if principal == nil then
				perform_response(owner:reply_error_op(401, 'unauthenticated'))
				return { status = 'unauthenticated' }
			end
		end
		return upload.run(scope, owner, ctx, update_deps)
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
