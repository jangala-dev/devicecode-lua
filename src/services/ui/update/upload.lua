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
local cap_sdk     = require 'services.hal.sdk.cap'

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

local function copy_table(t)
	local out = {}
	for k, v in pairs(t or {}) do out[k] = v end
	return out
end

local function artifact_store_id(opts)
	return opts.artifact_store_id
		or opts.artifact_store
		or opts.store_id
		or 'main'
end

local function artifact_store_policy(opts)
	return opts.artifact_store_policy
		or opts.artifact_policy
		or opts.sink_policy
		or 'prefer_durable'
end

local function artifact_sink_meta(opts)
	local meta = opts.metadata or opts.meta
	if type(meta) == 'table' then
		meta = copy_table(meta)
	else
		meta = {}
	end
	meta.component = meta.component
		or opts.component
		or opts.target_component
		or opts.update_component
	return meta
end

local function job_artifact_metadata(opts)
	local meta = opts.metadata or opts.meta
	if type(meta) == 'table' then
		meta = copy_table(meta)
	else
		meta = {}
	end
	if meta.artifact_cleanup == nil then meta.artifact_cleanup = 'delete_on_terminal' end
	if meta.artifact_lifecycle == nil then meta.artifact_lifecycle = 'delete_with_job' end
	return meta
end

local function sink_from_create_reply(reply, err)
	if reply == nil then return nil, err or 'artifact sink create failed' end
	if type(reply) == 'table' and reply.ok == false then
		return nil, reply.reason or reply.err or 'artifact sink create failed'
	end
	if type(reply) == 'table' and type(reply.append_op) == 'function' then
		return reply, nil
	end
	if type(reply) == 'table' then
		local sink = reply.reason or reply.value or reply.sink or reply.artifact_sink
		if type(sink) == 'table' then return sink, nil end
	end
	return nil, 'artifact sink create returned no sink'
end

local function create_artifact_sink_op(conn, opts)
	if type(conn) ~= 'table' then return fibers.always(nil, 'artifact sink connection unavailable') end
	local create_opts, opt_err = cap_sdk.args.new.ArtifactStoreCreateSinkOpts(
		artifact_sink_meta(opts),
		artifact_store_policy(opts)
	)
	if not create_opts then return fibers.always(nil, opt_err or 'artifact sink opts invalid') end
	local cap = cap_sdk.new_curated_cap_ref(conn, 'artifact_store', artifact_store_id(opts))
	return cap:call_control_op('create_sink', create_opts, {
		timeout = opts.sink_timeout or opts.artifact_store_timeout or opts.timeout,
		deadline = opts.deadline,
	})
end

local function normalise_header_name(name)
	return tostring(name or ''):lower()
end

local function header_one(headers, name)
	if type(headers) ~= 'table' then return nil end

	local lname = normalise_header_name(name)
	local get = headers.get
	if type(get) == 'function' then
		local ok, value = pcall(get, headers, lname)
		if ok and value ~= nil then return value end
		ok, value = pcall(get, headers, name)
		if ok and value ~= nil then return value end
	end

	local value = headers[lname] or headers[name]
	if value == nil then
		for k, v in pairs(headers) do
			if normalise_header_name(k) == lname then
				value = v
				break
			end
		end
	end

	if type(value) == 'table' then
		return value[1]
	end

	return value
end

local function string_header(headers, name)
	local raw = header_one(headers, name)
	if raw == nil then return nil end
	raw = tostring(raw)
	if raw == '' then return nil end
	return raw
end

local function apply_upload_headers(ctx, opts)
	local headers = ctx and ctx.headers
	local artifact_name = string_header(headers, 'x-artifact-name')
	local artifact_version = string_header(headers, 'x-artifact-version')
	local artifact_build = string_header(headers, 'x-artifact-build')
	local image_id = string_header(headers, 'x-artifact-image-id')
	local compat_commit_image_id = string_header(headers, 'x-artifact-compat-commit-image-id')
	local checksum = string_header(headers, 'x-artifact-checksum')

	if artifact_name == nil
		and artifact_version == nil
		and artifact_build == nil
		and image_id == nil
		and compat_commit_image_id == nil
		and checksum == nil
	then
		return opts
	end

	opts = copy_table(opts)
	local meta = opts.metadata or opts.meta
	if type(meta) == 'table' then
		meta = copy_table(meta)
	else
		meta = {}
	end
	if artifact_name ~= nil then meta.name = artifact_name end
	if artifact_version ~= nil then meta.version = artifact_version end
	if artifact_build ~= nil then meta.build = artifact_build end
	if image_id ~= nil then
		meta.image_id = image_id
		opts.expected_image_id = opts.expected_image_id or image_id
	end
	if compat_commit_image_id ~= nil then meta.compat_commit_image_id = compat_commit_image_id end
	if checksum ~= nil then meta.checksum = checksum end
	opts.metadata = meta
	return opts
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
		local sink_owner
		if ingest_client == nil then
			local conn, _, conn_err = connect_update_conn(scope, opts)
			if not conn then error(conn_err or 'update connection unavailable', 0) end
			opts.update_conn = opts.update_conn or conn

			if opts.sink == nil and opts.artifact_sink == nil then
				local sink_reply, sink_call_err = perform_with_deadline(
					scope,
					create_artifact_sink_op(conn, opts),
					deadline,
					mark_timeout
				)
				local sink, sink_err = sink_from_create_reply(sink_reply, sink_call_err)
				if not sink then
					error(sink_err or 'artifact sink create failed', 0)
				end
				sink_owner = resource.owned(sink, { label = 'upload artifact sink cleanup' })
				scope:finally(function (_, status, primary)
					sink_owner:terminate_checked(
						primary or status or 'upload_closed',
						'upload artifact sink cleanup'
					)
				end)
				opts.sink = sink
				opts.artifact_sink = sink
			end

			local built, build_err = ingest.bus_client(conn)
			if not built then error(build_err or 'artifact ingest bus client unavailable', 0) end
			ingest_client = built
		end

		local handle, open_err = perform_with_deadline(scope, ingest.open_ingest_op(ingest_client, opts), deadline, mark_timeout)
		if not handle then error(open_err or 'artifact ingest open failed', 0) end
		if sink_owner ~= nil then
			local _, detach_err = sink_owner:detach()
			if detach_err then error(detach_err, 0) end
		end

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
		local _, detach_err = ingest_owner:detach()
		if detach_err then error(detach_err, 0) end

		local out = { status = 'ok', artifact_id = artifact_id }
		if opts.create_job then
			local conn, _, conn_err = connect_update_conn(scope, opts)
			if not conn then error(conn_err or 'update connection unavailable', 0) end

			local call_opts = {}
			for k, v in pairs(opts) do call_opts[k] = v end
			call_opts.timeout = remaining_timeout(opts, deadline)
			call_opts.metadata = job_artifact_metadata(call_opts)

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

function M.run(_scope, owner, ctx, opts)
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
	opts = apply_upload_headers(ctx, opts or {})

	return fibers.guard(function ()
		local deadline = deadline_from_opts(opts)
		return upload_body_op(ctx, opts, deadline)
	end)
end

return M
