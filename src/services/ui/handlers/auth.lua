local uuid   = require 'uuid'
local errors = require 'services.ui.errors'

local M = {}

function M.login(ctx, username, password)
	local principal, err = ctx.verify_login(username, password)
	if not principal then
		ctx.svc:obs_log('warn', { what = 'login_failed', user = tostring(username), err = errors.message(err) })
		return nil, errors.from(err, 401)
	end

	local rec = ctx.sessions:create(tostring(uuid.new()), principal, ctx.session_ttl_s)
	ctx.note_session_count()
	ctx.audit('login', { user = rec.user.id })
	ctx.svc:obs_log('info', { what = 'login_ok', user = rec.user.id })
	return ctx.sessions:public(rec), nil
end

function M.logout(ctx, session_id)
	local rec, err = ctx.require_session(session_id)
	if not rec then return nil, err end
	ctx.sessions:delete(rec.id)
	ctx.note_session_count()
	ctx.audit('logout', { user = rec.user.id })
	return { ok = true }, nil
end

function M.get_session(ctx, session_id)
	local rec, err = ctx.require_session(session_id)
	if not rec then return nil, err end
	return ctx.sessions:public(rec), nil
end

return M
