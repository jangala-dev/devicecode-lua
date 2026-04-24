-- services/ui/uploads.lua
--
-- UI upload manager for update artefacts.
--
-- Current scope:
--   * receive one uploaded artefact body from the HTTP transport
--   * stream it into the artifact_store capability
--   * create and start an update job that references the stored artefact
--
-- This module is intentionally stateless for now. If upload progress becomes a
-- first-class UI feature later, state/pulse/watch machinery can be added then.

local cap_sdk = require 'services.hal.sdk.cap'
local errors  = require 'services.ui.errors'
local update_client = require 'services.ui.update_client'
local uuid    = require 'uuid'

local M = {}
local Uploads = {}
Uploads.__index = Uploads


function M.new(opts)
	opts = opts or {}
	assert(type(opts.require_session) == 'function', 'uploads: require_session is required')
	assert(type(opts.with_user_conn) == 'function', 'uploads: with_user_conn is required')

	return setmetatable({
		_require_session = opts.require_session,
		_with_user_conn = opts.with_user_conn,
		_max_bytes = opts.max_bytes or (512 * 1024),
		_allowed_components = opts.allowed_components or { mcu = true },
	}, Uploads)
end

function Uploads:_artifact_cap(user_conn)
	return cap_sdk.new_cap_ref(user_conn, 'artifact_store', 'main')
end

function Uploads:_delete_artifact(artifact_cap, artifact_ref)
	if type(artifact_ref) ~= 'string' or artifact_ref == '' then
		return
	end

	local delete_opts = assert(cap_sdk.args.new.ArtifactStoreDeleteOpts(artifact_ref))
	artifact_cap:call_control('delete', delete_opts)
end

function Uploads:_receive_artifact(artifact_cap, upload_id, stream, meta)
	local create_opts = assert(cap_sdk.args.new.ArtifactStoreCreateSinkOpts({
		kind = 'update_upload',
		component = meta.component,
		name = meta.name,
		version = meta.version,
		build = meta.build,
		checksum = meta.checksum,
		upload_id = upload_id,
	}, 'transient_only'))

	local reply, aerr = artifact_cap:call_control('create_sink', create_opts)
	if not reply then
		return nil, errors.from(aerr, 502)
	end
	if reply.ok ~= true then
		return nil, errors.from(reply.reason, 502)
	end

	local sink = reply.reason
	local offset = 0

	while true do
		local chunk, rerr = stream:get_body_chars(64 * 1024)
		if chunk == nil then
			sink:abort()
			return nil, errors.bad_request('body_read_failed: ' .. tostring(rerr or 'body_read_failed'))
		end
		if chunk == '' then
			break
		end

		local ok, werr = sink:write_chunk(offset, chunk)
		if not ok then
			sink:abort()
			return nil, errors.from(werr or 'sink_write_failed', 502)
		end

		offset = offset + #chunk
		if self._max_bytes and offset > self._max_bytes then
			sink:abort()
			return nil, errors.bad_request('upload_too_large')
		end
	end

	local artefact, commit_err = sink:commit()
	if not artefact then
		return nil, errors.from(commit_err or 'sink_commit_failed', 502)
	end

	return artefact, nil
end

function Uploads:_create_update_job(user_conn, artefact, meta)
	local created, uerr = update_client.create(user_conn, {
		component = meta.component,
		artifact = { kind = 'ref', ref = artefact:ref() },
		expected_version = meta.version,
		metadata = {
			source = 'ui_upload',
			name = meta.name,
			build = meta.build,
			checksum = meta.checksum,
			uploaded = true,
		},
	}, 10.0)

	if created == nil then
		return nil, uerr or errors.upstream('update_create failed')
	end
	return created, nil
end

function Uploads:_start_update_job(user_conn, job_id)
	local started, serr = update_client.do_job(user_conn, {
		op = 'start',
		job_id = job_id,
	}, 10.0)

	if started == nil then
		return nil, serr or errors.upstream('update_start failed')
	end
	return started, nil
end

function Uploads:upload_update(session_id, stream, req_headers)
	local rec, err = self._require_session(session_id)
	if not rec then return nil, err end

	local upload_id = tostring(uuid.new())
	local meta = {
		component = req_headers:get('x-artifact-component') or 'mcu',
		name = req_headers:get('x-artifact-name'),
		version = req_headers:get('x-artifact-version'),
		build = req_headers:get('x-artifact-build'),
		checksum = req_headers:get('x-artifact-checksum'),
	}
	if self._allowed_components and self._allowed_components[meta.component] ~= true then
		return nil, errors.bad_request('component_not_allowed')
	end

	local out, cerr = self._with_user_conn(
		rec.principal,
		{ ui = { op = 'update_upload', component = meta.component } },
		function(user_conn)
			local artifact_cap = self:_artifact_cap(user_conn)

			local artefact, rerr = self:_receive_artifact(artifact_cap, upload_id, stream, meta)
			if not artefact then
				return nil, rerr
			end

			local created, uerr = self:_create_update_job(user_conn, artefact, meta)
			if created == nil then
				self:_delete_artifact(artifact_cap, artefact:ref())
				return nil, uerr
			end

			local started, serr = self:_start_update_job(user_conn, created.job.job_id)
			if started == nil then
				self:_delete_artifact(artifact_cap, artefact:ref())
				return nil, serr
			end

			local desc = artefact:describe()
			return {
				ok = true,
				job = started.job,
				artifact = {
					ref = artefact:ref(),
					size = desc.size,
					checksum = desc.checksum,
				},
			}, nil
		end
	)

	if out == nil then
		return nil, cerr or errors.upstream('update_upload failed')
	end
	return out, nil
end

return M
