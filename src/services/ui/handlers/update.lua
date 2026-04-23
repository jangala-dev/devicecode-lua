-- services/ui/handlers/update.lua
--
-- UI façade over the update command surface.

local errors = require 'services.ui.errors'
local update_client = require 'services.ui.update_client'

local M = {}

local function nonempty_string(value, name)
	if type(value) ~= 'string' or value == '' then
		return nil, errors.bad_request((name or 'value') .. ' must be a non-empty string')
	end
	return value, nil
end


function M.create(ctx, session_id, payload)
	local rec, err = ctx.require_session(session_id)
	if not rec then return nil, err end

	payload = type(payload) == 'table' and payload or {}

	local out, cerr = ctx.run_user_call(
		rec,
		{ ui = { op = 'update_create' } },
		nil,
		function(user_conn)
			return update_client.create(user_conn, payload)
		end
	)

	if out == nil then
		return nil, cerr or errors.upstream('update_create failed')
	end
	return out, nil
end

function M.get(ctx, session_id, job_id)
	local rec, err = ctx.require_session(session_id)
	if not rec then return nil, err end

	local id, jerr = nonempty_string(job_id, 'job_id')
	if not id then return nil, jerr end

	local out, cerr = ctx.run_user_call(
		rec,
		{ ui = { op = 'update_get', job_id = id } },
		nil,
		function(user_conn)
			return update_client.get(user_conn, id)
		end
	)

	if out == nil then
		return nil, cerr or errors.upstream('update_get failed')
	end
	return out, nil
end

function M.list(ctx, session_id)
	local rec, err = ctx.require_session(session_id)
	if not rec then return nil, err end

	local out, cerr = ctx.run_user_call(
		rec,
		{ ui = { op = 'update_list' } },
		nil,
		function(user_conn)
			return update_client.list(user_conn)
		end
	)

	if out == nil then
		return nil, cerr or errors.upstream('update_list failed')
	end
	return out, nil
end

function M.do_job(ctx, session_id, job_id, payload)
	local rec, err = ctx.require_session(session_id)
	if not rec then return nil, err end

	local id, jerr = nonempty_string(job_id, 'job_id')
	if not id then return nil, jerr end
	if type(payload) ~= 'table' then
		return nil, errors.bad_request('payload must be a table')
	end

	local req = {}
	for k, v in pairs(payload) do
		req[k] = v
	end
	req.job_id = id

	local out, cerr = ctx.run_user_call(
		rec,
		{ ui = { op = 'update_do', job_id = id, action = req.op } },
		nil,
		function(user_conn)
			return update_client.do_job(user_conn, req)
		end
	)

	if out == nil then
		return nil, cerr or errors.upstream('update_do failed')
	end
	return out, nil
end

function M.upload_artifact(ctx, session_id, stream, req_headers)
	if not ctx.uploads then
		return nil, errors.unavailable('upload manager unavailable')
	end
	return ctx.uploads:upload_update(session_id, stream, req_headers)
end

return M
