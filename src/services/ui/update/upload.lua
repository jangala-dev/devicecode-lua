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

local function connect_update_conn(scope, opts)
	if opts.update_conn then
		return opts.update_conn, false, nil
	end
	if opts.conn then
		return opts.conn, false, nil
	end
	local conn, err
	if type(opts.connect) == 'function' then
		conn, err = opts.connect(opts.principal, opts)
	elseif opts.bus and type(opts.bus.connect) == 'function' then
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

local function remaining_timeout(opts, deadline)
	if deadline == nil then return opts.timeout end
	local remaining = deadline - fibers.now()
	if remaining < 0 then remaining = 0 end
	return remaining
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

		local ingest_client = opts.ingest or opts.artifact_ingest
		if ingest_client == nil then
			local conn, _, conn_err = connect_update_conn(scope, opts)
			if not conn then error(conn_err or 'update connection unavailable', 0) end
			opts.update_conn = opts.update_conn or conn
			local built, build_err = ingest.bus_client(conn)
			if not built then error(build_err or 'artifact ingest bus client unavailable', 0) end
			ingest_client = built
		end

		local handle, open_err = perform_with_deadline(scope, ingest.open_ingest_op(ingest_client, opts), deadline, mark_timeout)
		if not handle then error(open_err or 'artifact ingest open failed', 0) end

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
		while true do
			local chunk, rerr = perform_with_deadline(scope, read_chunk_op(body, opts.chunk_size or 65536), deadline, mark_timeout)
			if rerr then error(rerr, 0) end
			if chunk == nil or chunk == '' then break end
			local ok, werr = perform_with_deadline(scope, ingest.append_chunk_op(handle, chunk), deadline, mark_timeout)
			if ok == nil or ok == false then error(werr or 'artifact append failed', 0) end
		end

		local artifact_id, cerr = perform_with_deadline(scope, ingest.commit_op(handle), deadline, mark_timeout)
		if not artifact_id then error(cerr or 'artifact commit failed', 0) end
		local _committed_handle, detach_err = ingest_owner:detach()
		if detach_err then error(detach_err, 0) end

		local out = { status = 'ok', artifact_id = artifact_id }
		if opts.create_job then
			local conn, _, conn_err = connect_update_conn(scope, opts)
			if not conn then error(conn_err or 'update connection unavailable', 0) end

			local call_opts = {}
			for k, v in pairs(opts) do call_opts[k] = v end
			call_opts.timeout = remaining_timeout(opts, deadline)

			local job, jerr = perform_with_deadline(scope, client.create_job_op(conn, artifact_id, call_opts), deadline, mark_timeout)
			if not job then error(jerr or 'update job create failed', 0) end
			out.job = job
			if opts.start_job then
				call_opts.timeout = remaining_timeout(opts, deadline)
				local started, serr = perform_with_deadline(scope, client.start_job_op(conn, job.job_id or job.id, call_opts), deadline, mark_timeout)
				if not started then error(serr or 'update job start failed', 0) end
				out.started = started
			end
		end
		return out
	end)
end

function M.run(scope, owner, ctx, opts)
	opts = opts or {}
	local st, _, result_or_primary = fibers.perform(M.run_op(ctx, opts))
	if st ~= 'ok' then
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
