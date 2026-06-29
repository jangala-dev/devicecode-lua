-- services/ui/update/upload.lua
--
-- Update upload scoped operation. It owns ingest before commit, detaches
-- abort cleanup after commit, and may hand off to the update service.
--
-- Upload timeout is an ownership decision: waits inside the upload scope are
-- raced against the deadline. If the deadline wins, the upload scope is
-- cancelled with reason "timeout" and the uncommitted ingest finaliser aborts
-- immediately.

local fibers      = require 'fibers'
local sleep       = require 'fibers.sleep'
local ingest      = require 'services.ui.update.artifact_ingest'
local client      = require 'services.ui.update.client'
local bus_cleanup = require 'devicecode.support.bus_cleanup'
local resource    = require 'devicecode.support.resource'
local scope_mod   = require 'fibers.scope'

local M = {}

local function shallow_copy(t)
	local out = {}
	for k, v in pairs(t or {}) do out[k] = v end
	return out
end

local function header_one(headers, name)
	if type(headers) ~= 'table' then return nil end
	if type(headers.get) == 'function' then
		local ok, v = pcall(function () return headers:get(string.lower(name)) end)
		if ok and v ~= nil then return v end
	end
	return headers[name] or headers[string.lower(name)] or headers[string.upper(name)]
end

local function request_id_of(ctx)
	if type(ctx) ~= 'table' then return nil end
	if type(ctx.id) == 'function' then
		local ok, v = pcall(function () return ctx:id() end)
		if ok and v ~= nil then return v end
	end
	if type(ctx.id) ~= 'function' then return ctx.id or ctx.request_id end
	return ctx.request_id
end

local function content_length_of(ctx)
	local h = type(ctx) == 'table' and ctx.headers or nil
	local v = header_one(h, 'content-length') or header_one(h, 'Content-Length')
	local n = tonumber(v)
	return n or v
end

local function note_phase(opts, phase)
	if type(opts) == 'table' then opts._upload_phase = phase end
	return phase
end

local function emit_upload(opts, ev)
	local port = opts and opts.events_port
	if not (port and type(port) == 'table') then return false end
	ev = shallow_copy(ev)
	ev.kind = ev.kind or 'upload_event'
	ev.what = ev.what or ev.phase or 'upload_event'
	ev.phase = ev.phase or ev.what
	ev.upload_phase = opts and opts._upload_phase or ev.phase
	local ok = pcall(function ()
		if type(port.emit_now) == 'function' then
			port:emit_now(ev)
		elseif type(port.emit_required) == 'function' then
			port:emit_required(ev, 'ui_update_upload_event_report_failed')
		end
	end)
	return ok == true
end

local function connect_update_conn(scope, opts)
	if opts.update_conn then
		opts._upload_conn_source = 'update_conn'
		return opts.update_conn, false, nil
	end
	if opts.conn then
		opts._upload_conn_source = 'service_conn'
		return opts.conn, false, nil
	end
	local conn, err
	if type(opts.connect) == 'function' then
		opts._upload_conn_source = 'connect'
		conn, err = opts.connect(opts.principal, opts)
	elseif opts.bus and type(opts.bus.connect) == 'function' then
		opts._upload_conn_source = 'bus'
		conn, err = opts.bus:connect({ principal = opts.principal })
	end
	if not conn then return nil, false, err or 'update connection unavailable' end
	local conn_owner = resource.owned(conn, {
		label = 'update upload connection cleanup',
		terminate = function (value)
			return bus_cleanup.disconnect(value)
		end,
	})
	scope:finally(function (_, status, primary)
		conn_owner:terminate_checked(primary or status or 'upload_closed', 'update upload connection cleanup')
	end)
	return conn, true, nil
end

local function read_chunk_op(body, max)
	if type(body) == 'table' and type(body.read_chunk_op) == 'function' then
		return body:read_chunk_op(max)
	end
	return fibers.always(nil, 'request body has no read_chunk_op')
end

local function deadline_from_opts(opts)
	if type(opts.deadline) == 'number' then
		return opts.deadline
	end
	local timeout = opts.upload_timeout
	if timeout == nil then timeout = opts.timeout end
	if type(timeout) == 'number' then
		return fibers.now() + timeout
	end
	return nil
end


local function cancel_for_timeout(scope, on_timeout)
	if on_timeout then on_timeout() end
	if scope and type(scope.cancel) == 'function' then
		scope:cancel('timeout')
	end
	error(scope_mod.cancelled('timeout'), 0)
end

local function perform_with_deadline(scope, ev, deadline, on_timeout)
	if deadline == nil then
		return fibers.perform(ev)
	end

	local dt = deadline - fibers.now()
	if dt <= 0 then
		cancel_for_timeout(scope, on_timeout)
	end

	local completed, a, b, c = fibers.perform(fibers.boolean_choice(ev, sleep.sleep_op(dt)))
	if completed then
		return a, b, c
	end

	cancel_for_timeout(scope, on_timeout)
end

local function upload_body_op(ctx, opts, deadline)
	return fibers.run_scope_op(function (scope)
		local timed_out = false
		local function mark_timeout() timed_out = true end
		local request_id = request_id_of(ctx)
		local content_length = content_length_of(ctx)
		note_phase(opts, 'begin')
		emit_upload(opts, {
			what = 'upload_begin',
			request_id = request_id,
			component = opts.component,
			create_job = opts.create_job,
			start_job = opts.start_job,
			max_bytes = opts.max_bytes,
			content_length = content_length,
		})

		local ingest_client = opts.ingest
		if ingest_client == nil then
			note_phase(opts, 'connect_ingest')
			local conn, _, conn_err = connect_update_conn(scope, opts)
			if not conn then error(conn_err or 'update connection unavailable', 0) end
			local built, build_err = ingest.bus_client(conn)
			if not built then error(build_err or 'artifact ingest bus client unavailable', 0) end
			ingest_client = built
		end

		note_phase(opts, 'ingest_open')
		local handle, open_err = perform_with_deadline(scope, ingest.open_ingest_op(ingest_client, opts), deadline, mark_timeout)
		if not handle then error(open_err or 'artifact ingest open failed', 0) end
		emit_upload(opts, {
			what = 'upload_ingest_opened',
			request_id = request_id,
			ingest_id = handle.ingest_id,
			conn_source = opts._upload_conn_source,
		})

		local ingest_owner = resource.owned(handle, {
			label = 'upload ingest abort',
			terminate = function (value, reason)
				return ingest.abort_now(value, reason)
			end,
		})
		scope:finally(function (_, status, primary)
			ingest_owner:terminate_checked(
				timed_out and 'timeout' or primary or status or 'upload_closed',
				'upload ingest abort'
			)
		end)

		local body = ctx.body_stream or ctx.body or ctx.stream or ctx
		if body == nil then error('request body has no chunk reader', 0) end
		local uploaded_bytes = 0
		local uploaded_chunks = 0
		while true do
			note_phase(opts, 'body_read')
			local chunk, rerr = perform_with_deadline(scope, read_chunk_op(body, opts.chunk_size or 65536), deadline, mark_timeout)
			if rerr then error(rerr, 0) end
			if chunk == nil or chunk == '' then break end
			note_phase(opts, 'ingest_append')
			local ok, werr = perform_with_deadline(scope, ingest.append_chunk_op(handle, chunk), deadline, mark_timeout)
			if ok == nil or ok == false then error(werr or 'artifact append failed', 0) end
			uploaded_chunks = uploaded_chunks + 1
			uploaded_bytes = uploaded_bytes + #chunk
		end
		emit_upload(opts, {
			what = 'upload_body_read',
			request_id = request_id,
			bytes = uploaded_bytes,
			chunks = uploaded_chunks,
			content_length = content_length,
		})

		note_phase(opts, 'ingest_commit')
		local artifact_id, cerr = perform_with_deadline(scope, ingest.commit_op(handle), deadline, mark_timeout)
		if not artifact_id then error(cerr or 'artifact commit failed', 0) end
		local _committed_handle, detach_err = ingest_owner:detach()
		if detach_err then error(detach_err, 0) end
		emit_upload(opts, {
			what = 'upload_artifact_committed',
			request_id = request_id,
			artifact_id = artifact_id,
			bytes = uploaded_bytes,
			chunks = uploaded_chunks,
		})

		local out = { status = 'ok', artifact_id = artifact_id }
		if opts.create_job then
			local conn, _, conn_err = connect_update_conn(scope, opts)
			if not conn then error(conn_err or 'update connection unavailable', 0) end

			local call_opts = {}
			for k, v in pairs(opts) do call_opts[k] = v end
			call_opts.timeout = false

			emit_upload(opts, { what = 'upload_create_job_begin', request_id = request_id, artifact_id = artifact_id })
			note_phase(opts, 'create_job')
			local job, jerr = perform_with_deadline(scope, client.create_job_op(conn, artifact_id, call_opts), deadline, mark_timeout)
			if not job then error(jerr or 'update job create failed', 0) end
			if type(job) ~= 'table' or type(job.job_id) ~= 'string' or job.job_id == '' then
				error('create_job_reply_missing_job_id', 0)
			end
			out.job_id = job.job_id
			emit_upload(opts, { what = 'upload_create_job_done', request_id = request_id, artifact_id = artifact_id, job_id = job.job_id })
			if opts.start_job then
				call_opts.timeout = false
				emit_upload(opts, { what = 'upload_start_job_begin', request_id = request_id, job_id = job.job_id })
				note_phase(opts, 'start_job')
				local started, serr = perform_with_deadline(scope, client.start_job_op(conn, job.job_id, call_opts), deadline, mark_timeout)
				if not started then error(serr or 'update job start failed', 0) end
				out.started = started
				emit_upload(opts, { what = 'upload_start_job_done', request_id = request_id, job_id = job.job_id })
			end
		end
		emit_upload(opts, {
			what = 'upload_done',
			request_id = request_id,
			artifact_id = artifact_id,
			job_id = out.job_id,
			bytes = uploaded_bytes,
			chunks = uploaded_chunks,
		})
		return out
	end)
end

function M.run(scope, owner, ctx, opts)
	-- Copy per request: upload state such as _upload_phase and update_conn must not
	-- leak back into the long-lived listener configuration table.
	opts = shallow_copy(opts)
	local st, _, result_or_primary = fibers.perform(M.run_op(ctx, opts))
	if st ~= 'ok' then
		emit_upload(opts, {
			what = 'upload_failed',
			request_id = request_id_of(ctx),
			phase = opts._upload_phase,
			err = tostring(result_or_primary or st),
		})
		local ok, werr = fibers.perform(owner:reply_error_op(nil, result_or_primary or st))
		if ok ~= true then error(werr or 'response write failed', 0) end
		return { status = st, err = result_or_primary or st }
	end
	local ok, werr = fibers.perform(owner:reply_json_op(200, result_or_primary))
	if ok ~= true then error(werr or 'response write failed', 0) end
	return result_or_primary
end

function M.run_op(ctx, opts)
	ctx = ctx or {}
	opts = opts or {}

	return fibers.guard(function ()
		local deadline = deadline_from_opts(opts)
		return upload_body_op(ctx, opts, deadline)
	end)
end

return M
