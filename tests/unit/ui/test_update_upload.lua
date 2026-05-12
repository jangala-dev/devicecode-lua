-- tests/unit/ui/test_update_upload.lua

local fibers = require 'fibers'
local sleep = require 'fibers.sleep'
local upload = require 'services.ui.update.upload'

local tests = {}

local function fail(msg) error(msg or 'assertion failed', 2) end
local function assert_eq(a, b, msg) if a ~= b then fail(msg or ('expected '..tostring(b)..', got '..tostring(a))) end end
local function assert_nil(v, msg) if v ~= nil then fail(msg or ('expected nil, got '..tostring(v))) end end
local function assert_not_nil(v, msg) if v == nil then fail(msg or 'expected non-nil') end end

local function body_from_chunks(chunks)
	return {
		_chunks = chunks,
		read_chunk_op = function (self)
			local chunk = table.remove(self._chunks, 1)
			return fibers.always(chunk, nil)
		end,
	}
end

local function ingest_client(handle)
	return {
		open_ingest_op = function ()
			return fibers.always(handle, nil)
		end,
	}
end

function tests.test_upload_abort_finaliser_runs_when_append_fails()
	fibers.run(function ()
		local handle = {
			aborted = nil,
			append_chunk_op = function () return fibers.always(nil, 'append_failed') end,
			commit_op = function () error('commit must not be called') end,
			abort_now = function (self, reason) self.aborted = reason; return true end,
		}

		local st, _, primary = fibers.perform(upload.run_op({
			body_stream = body_from_chunks({ 'abc' }),
		}, {
			ingest = ingest_client(handle),
		}))

		assert_eq(st, 'failed')
		assert_eq(primary, 'append_failed')
		assert_eq(handle.aborted, 'append_failed')
	end)
end

function tests.test_committed_artifact_is_not_aborted_when_update_job_create_fails()
	fibers.run(function ()
		local handle = {
			aborted = nil,
			chunks = {},
			append_chunk_op = function (self, chunk) self.chunks[#self.chunks + 1] = chunk; return fibers.always(true, nil) end,
			commit_op = function () return fibers.always('artifact-1', nil) end,
			abort_now = function (self, reason) self.aborted = reason; return true end,
		}
		local conn = {
			call_op = function () return fibers.always(nil, 'create_failed') end,
		}

		local st, _, primary = fibers.perform(upload.run_op({
			body_stream = body_from_chunks({ 'abc' }),
		}, {
			ingest = ingest_client(handle),
			create_job = true,
			conn = conn,
		}))

		assert_eq(st, 'failed')
		assert_eq(primary, 'create_failed')
		assert_nil(handle.aborted)
		assert_eq(handle.chunks[1], 'abc')
	end)
end

function tests.test_upload_disconnects_owned_update_connection_after_success()
	fibers.run(function ()
		local handle = {
			append_chunk_op = function () return fibers.always(true, nil) end,
			commit_op = function () return fibers.always('artifact-2', nil) end,
			abort_now = function () error('abort must not be called after commit') end,
		}
		local disconnected = false
		local conn = {
			call_op = function (_, topic)
				if topic[4] == 'create' then return fibers.always({ job_id = 'job-1' }, nil) end
				return fibers.always({ started = true }, nil)
			end,
			disconnect = function () disconnected = true; return true end,
		}

		local st, _, result = fibers.perform(upload.run_op({
			body_stream = body_from_chunks({ 'abc' }),
		}, {
			ingest = ingest_client(handle),
			create_job = true,
			start_job = true,
			connect = function () return conn, nil end,
		}))

		assert_eq(st, 'ok')
		assert_eq(result.artifact_id, 'artifact-2')
		assert_not_nil(result.job)
		assert_not_nil(result.started)
		assert_eq(disconnected, true)
	end)
end

function tests.test_upload_promotes_transfer_chunk_header_to_job_metadata()
	fibers.run(function ()
		local handle = {
			append_chunk_op = function () return fibers.always(true, nil) end,
			commit_op = function () return fibers.always('artifact-header', nil) end,
			abort_now = function () error('abort must not be called after commit') end,
		}
		local captured
		local conn = {
			call_op = function (_, _topic, payload)
				captured = payload
				return fibers.always({ job_id = 'job-header' }, nil)
			end,
		}

		local st, _, result = fibers.perform(upload.run_op({
			headers = {
				['X-Transfer-Chunk-Raw'] = '4096',
				['X-Artifact-Name'] = 'mcu.bin',
				['X-Artifact-Version'] = 'mcu-v1',
				['X-Artifact-Build'] = 'build-1',
				['X-Artifact-Image-Id'] = 'mcu-image-1',
				['X-Artifact-Compat-Commit-Image-Id'] = 'img-dev',
			},
			body_stream = body_from_chunks({ 'abc' }),
		}, {
			ingest = ingest_client(handle),
			create_job = true,
			conn = conn,
			metadata = { user = 'kept' },
		}))

		assert_eq(st, 'ok')
		assert_eq(result.artifact_id, 'artifact-header')
		assert_not_nil(captured)
		assert_eq(captured.expected_image_id, 'mcu-image-1')
		assert_eq(captured.metadata.user, 'kept')
		assert_eq(captured.metadata.name, 'mcu.bin')
		assert_eq(captured.metadata.version, 'mcu-v1')
		assert_eq(captured.metadata.build, 'build-1')
		assert_eq(captured.metadata.image_id, 'mcu-image-1')
		assert_eq(captured.metadata.compat_commit_image_id, 'img-dev')
		assert_eq(captured.metadata.transfer_chunk_raw, 4096)
	end)
end


function tests.test_upload_timeout_cancels_scope_and_aborts_uncommitted_ingest()
	fibers.run(function ()
		local handle = {
			aborted = nil,
			append_chunk_op = function () return fibers.always(true, nil) end,
			commit_op = function () return fibers.always('artifact-timeout', nil) end,
			abort_now = function (self, reason) self.aborted = reason; return true end,
		}
		local body = {
			read_chunk_op = function ()
				return sleep.sleep_op(1):wrap(function () return 'late', nil end)
			end,
		}

		local st, _, primary = fibers.perform(upload.run_op({
			body_stream = body,
		}, {
			ingest = ingest_client(handle),
			upload_timeout = 0.01,
		}))

		assert_eq(st, 'cancelled')
		assert_eq(primary, 'timeout')
		assert_eq(handle.aborted, 'timeout')
	end)
end


function tests.test_upload_requires_read_chunk_op_body_contract()
	fibers.run(function ()
		local handle = {
			append_chunk_op = function () error('append must not be called') end,
			commit_op = function () error('commit must not be called') end,
			abort_now = function (self, reason) self.aborted = reason; return true end,
		}

		local st, _, primary = fibers.perform(upload.run_op({
			body_stream = { read_op = function () error('compat path must not be used') end },
		}, {
			ingest = ingest_client(handle),
		}))

		assert_eq(st, 'failed')
		assert_eq(primary, 'request body has no read_chunk_op')
		assert_eq(handle.aborted, 'request body has no read_chunk_op')
	end)
end

function tests.test_artifact_ingest_boundary_requires_op_methods_and_abort_now()
	local ingest = require 'services.ui.update.artifact_ingest'
	fibers.run(function ()
		local handle, err = fibers.perform(ingest.open_ingest_op({ open_ingest = function () return {} end }, {}))
		assert_nil(handle)
		assert_eq(err, 'artifact ingest client must expose open_ingest_op')

		local ok, aerr = fibers.perform(ingest.append_chunk_op({ append = function () return true end }, 'abc'))
		assert_nil(ok)
		assert_eq(aerr, 'artifact ingest handle must expose append_chunk_op')

		local artifact, cerr = fibers.perform(ingest.commit_op({ commit = function () return 'artifact' end }))
		assert_nil(artifact)
		assert_eq(cerr, 'artifact ingest handle must expose commit_op')
	end)

	local ok, err = ingest.abort_now({ abort = function () return true end }, 'closed')
	assert_nil(ok)
	assert_eq(err, 'artifact ingest handle must expose immediate abort_now')

	ok, err = ingest.abort_now({ abort_now = function () return fibers.always(true, nil) end }, 'closed')
	assert_nil(ok)
	assert_eq(err, 'artifact ingest abort_now must be immediate and must not return an Op')
end

function tests.test_bus_artifact_ingest_commit_extracts_nested_artifact_ref()
	local ingest = require 'services.ui.update.artifact_ingest'
	fibers.run(function ()
		local artifact = {
			ref = function ()
				return 'artifact-nested-ref'
			end,
		}
		local conn = {
			call_op = function (_, topic)
				local method = topic[#topic]
				if method == 'create' then
					return fibers.always({ ingest = { ingest_id = 'ingest-nested' } })
				elseif method == 'commit' then
					return fibers.always({
						commit = {
							tag = 'ingest_committed',
							ingest_id = 'ingest-nested',
							artifact = artifact,
							bytes = 427872,
						},
					})
				end
				return fibers.always(nil, 'unexpected method')
			end,
		}

		local client = ingest.bus_client(conn)
		local handle = assert(fibers.perform(ingest.open_ingest_op(client, {})))
		local ref, err = fibers.perform(ingest.commit_op(handle))

		assert_nil(err)
		assert_eq(ref, 'artifact-nested-ref')
	end)
end

function tests.test_upload_timeout_while_append_pending_aborts_uncommitted_ingest()
	fibers.run(function ()
		local handle = {
			aborted = nil,
			append_chunk_op = function ()
				return sleep.sleep_op(1):wrap(function () return true, nil end)
			end,
			commit_op = function () error('commit must not be called') end,
			abort_now = function (self, reason) self.aborted = reason; return true end,
		}

		local st, _, primary = fibers.perform(upload.run_op({
			body_stream = body_from_chunks({ 'abc' }),
		}, {
			ingest = ingest_client(handle),
			upload_timeout = 0.01,
		}))

		assert_eq(st, 'cancelled')
		assert_eq(primary, 'timeout')
		assert_eq(handle.aborted, 'timeout')
	end)
end

return tests
