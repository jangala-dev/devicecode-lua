-- services/ui/uploads.lua
--
-- UI upload manager for update artefacts.
--
-- Current scope:
--   * receive one uploaded artefact body from the HTTP transport
--   * stream it into the public artifact-ingest manager
--   * create and stage an update job that references the stored artefact
--   * leave uploaded MCU jobs awaiting an explicit commit action before the
--     power-cycling cutover occurs
--
-- This module is intentionally stateless for now. If upload progress becomes a
-- first-class UI feature later, state/pulse/watch machinery can be added then.

local fibers  = require 'fibers'
local cap_sdk = require 'services.hal.sdk.cap'
local errors  = require 'services.ui.errors'
local update_client = require 'services.ui.update_client'
local uuid    = require 'uuid'

local M = {}
local Uploads = {}
Uploads.__index = Uploads

local function normalise_update_err(err, fallback)
	if err == nil then
		return errors.upstream(fallback)
	end
	if type(err) == 'table' then
		return err
	end
	if err == 'timeout' then
		return errors.timeout()
	end
	return err
end

function M.new(opts)
	opts = opts or {}
	assert(type(opts.require_session) == 'function', 'uploads: require_session is required')
	assert(type(opts.with_user_conn) == 'function', 'uploads: with_user_conn is required')

	return setmetatable({
		_require_session = opts.require_session,
		_with_user_conn = opts.with_user_conn,
		_max_bytes = opts.max_bytes or (512 * 1024),
		_upload_timeout_s = opts.upload_timeout_s or 30.0,
		_allowed_components = opts.allowed_components or { mcu = true },
	}, Uploads)
end

function Uploads:_artifact_cap(user_conn)
	return cap_sdk.new_curated_cap_ref(user_conn, 'artifact-ingest', 'main')
end

function Uploads:_upload_deadline()
	local timeout_s = tonumber(self._upload_timeout_s) or 30.0
	return fibers.now() + timeout_s
end

function Uploads:_remaining_timeout(deadline)
	local remaining = deadline - fibers.now()
	if remaining <= 0 then
		return nil, errors.timeout('update_upload timed out')
	end
	return remaining, nil
end

function Uploads:_receive_artifact(artifact_cap, upload_id, stream, meta, deadline)
	local create_remaining, terr = self:_remaining_timeout(deadline)
	if not create_remaining then
		return nil, terr
	end

	local create_payload = {
		meta = {
			kind = 'update_upload',
			component = meta.component,
			name = meta.name,
			version = meta.version,
			build = meta.build,
			checksum = meta.checksum,
			upload_id = upload_id,
		},
		policy = 'transient_only',
	}

	local reply, aerr = artifact_cap:call_control('create', create_payload)
	if not reply then
		return nil, errors.from(aerr, 502)
	end
	if reply.ok ~= true then
		return nil, errors.from(reply.reason, 502)
	end

	local ingest_id = reply.ingest_id
	if type(ingest_id) ~= 'string' or ingest_id == '' then
		return nil, errors.from('ingest_id_missing', 502)
	end

	local offset = 0
	local function abort_ingest()
		artifact_cap:call_control('abort', { ingest_id = ingest_id })
	end

	while true do
		local remaining, terr = self:_remaining_timeout(deadline)
		if not remaining then
			abort_ingest()
			return nil, terr
		end

		local chunk, rerr = stream:get_body_chars(64 * 1024)
		if chunk == nil then
			abort_ingest()
			return nil, errors.bad_request('body_read_failed: ' .. tostring(rerr or 'body_read_failed'))
		end
		if chunk == '' then
			break
		end

		local ok, werr = artifact_cap:call_control('append', {
			ingest_id = ingest_id,
			offset = offset,
			data = chunk,
		})
		if not ok then
			abort_ingest()
			return nil, errors.from(werr or 'ingest_append_failed', 502)
		end
		if ok.ok ~= true then
			abort_ingest()
			return nil, errors.from(ok.reason or 'ingest_append_failed', 502)
		end

		offset = offset + #chunk
		if self._max_bytes and offset > self._max_bytes then
			abort_ingest()
			return nil, errors.bad_request('upload_too_large')
		end
	end

	local committed, commit_err = artifact_cap:call_control('commit', { ingest_id = ingest_id })
	if not committed then
		abort_ingest()
		return nil, errors.from(commit_err or 'ingest_commit_failed', 502)
	end
	if committed.ok ~= true then
		abort_ingest()
		return nil, errors.from(committed.reason or 'ingest_commit_failed', 502)
	end

	local artefact = committed.artifact
	if artefact == nil then
		return nil, errors.from('artifact_missing', 502)
	end

	return artefact, nil
end

function Uploads:_create_update_job(user_conn, artefact, meta, deadline)
	local timeout_s, terr = self:_remaining_timeout(deadline)
	if not timeout_s then
		return nil, terr
	end

	local created, uerr = update_client.create(user_conn, {
		component = meta.component,
		artifact = { kind = 'ref', ref = artefact:ref() },
		metadata = {
			source = 'ui_upload',
			name = meta.name,
			build = meta.build,
			checksum = meta.checksum,
			uploaded = true,
			commit_policy = 'manual',
			require_explicit_commit = true,
		},
	}, timeout_s)

	if created == nil then
		return nil, normalise_update_err(uerr, 'update_create failed')
	end
	return created, nil
end

function Uploads:_start_update_job(user_conn, job_id, deadline)
	local timeout_s, terr = self:_remaining_timeout(deadline)
	if not timeout_s then
		return nil, terr
	end

	local started, serr = update_client.do_job(user_conn, {
		op = 'start',
		job_id = job_id,
	}, timeout_s)

	if started == nil then
		return nil, normalise_update_err(serr, 'update_start failed')
	end
	return started, nil
end

function Uploads:upload_update(session_id, stream, req_headers)
	local rec, err = self._require_session(session_id)
	if not rec then return nil, err end

	local deadline = self:_upload_deadline()
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

			local artefact, rerr = self:_receive_artifact(artifact_cap, upload_id, stream, meta, deadline)
			if not artefact then
				return nil, rerr
			end

			local created, uerr = self:_create_update_job(user_conn, artefact, meta, deadline)
			if created == nil then
				return nil, uerr
			end

			local started, serr = self:_start_update_job(user_conn, created.job.job_id, deadline)
			if started == nil then
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
				update_flow = {
					staged = true,
					requires_commit = true,
					next_action = 'commit',
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
