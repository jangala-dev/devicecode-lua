-- tests/integration/devhost/update_public_seams_spec.lua
--
-- Public Update control-plane seam tests.  These exercise the canonical
-- cap/... manager interfaces and retained state/workflow publication, rather
-- than service-private command trees.

local busmod = require 'bus'
local fibers = require 'fibers'

local runfibers = require 'tests.support.run_fibers'
local probe     = require 'tests.support.bus_probe'

local service = require 'services.update.service'
local topics  = require 'services.update.topics'
local upload  = require 'services.ui.update.upload'

local T = {}

local function fail(msg) error(msg or 'assertion failed', 2) end
local function assert_eq(a, b, msg) if a ~= b then fail(msg or ('expected ' .. tostring(b) .. ', got ' .. tostring(a))) end end
local function assert_true(v, msg) if v ~= true then fail(msg or ('expected true, got ' .. tostring(v))) end end
local function assert_not_nil(v, msg) if v == nil then fail(msg or 'expected non-nil') end end


local function wait_retained_payload_where(conn, topic, label, pred, opts)
	opts = opts or {}
	local view = conn:retained_view(topic)
	local value = probe.wait_versioned_until(label, function ()
		return view:version()
	end, function (seen)
		return view:changed_op(seen)
	end, function ()
		local msg = view:get(topic)
		local payload = msg and msg.payload or nil
		if pred(payload) then return payload end
		return nil
	end, opts)
	view:close()
	return value
end

local function has_value(list, value)
	for _, item in ipairs(list or {}) do
		if item == value then return true end
	end
	return false
end

local function update_config()
	return {
		schema = 'devicecode.update/1',
		components = {
			{ component = 'cm5' },
			{ component = 'mcu' },
		},
	}
end

local function start_update(scope, params)
	params = params or {}
	local bus = params.bus or busmod.new()
	local svc_conn = bus:connect()
	local caller = bus:connect()
	local child = assert(scope:child())

	local ok, err = child:spawn(function (service_scope)
		service.run(service_scope, {
			conn = svc_conn,
			service_id = 'update',
			watch_config = false,
			config = params.config or update_config(),
			backend = params.backend,
			job_store = params.job_store,
			initial_jobs = params.initial_jobs,
		})
	end)
	assert_true(ok, err)

	wait_retained_payload_where(caller, topics.update_manager_status(), 'update manager available', function (p)
		return p and p.available == true
	end, { timeout = 1.0 })
	return {
		bus = bus,
		child = child,
		caller = caller,
		svc_conn = svc_conn,
	}
end

local function new_sink(artifact)
	artifact = artifact or { artifact_id = 'artifact-1', ref = 'artifact-1' }
	return {
		chunks = {},
		terminated = 0,
		append_op = function (self, chunk)
			self.chunks[#self.chunks + 1] = chunk
			return fibers.always(true, nil)
		end,
		commit_op = function ()
			return fibers.always(artifact, nil)
		end,
		terminate = function (self, reason)
			self.terminated = self.terminated + 1
			self.termination_reason = reason
			return true, nil
		end,
	}
end

local function body_from_chunks(chunks)
	return {
		_chunks = chunks,
		read_chunk_op = function (self)
			local chunk = table.remove(self._chunks, 1)
			return fibers.always(chunk, nil)
		end,
	}
end

function T.update_public_manager_retains_capabilities_and_workflow_records()
	runfibers.run(function(scope)
		local h = start_update(scope)
		local conn = h.caller

		local meta = probe.wait_retained_payload(conn, topics.update_manager_meta(), { timeout = 1.0 })
		assert_eq(meta.owner, 'update')
		assert_eq(meta.class, 'update-manager')
		assert_true(has_value(meta.methods, 'create-job'), 'manager meta should list create-job')
		assert_true(has_value(meta.methods, 'start-job'), 'manager meta should list start-job')
		assert_eq(meta.workflow_family[1], 'state')
		assert_eq(meta.workflow_family[2], 'workflow')
		assert_eq(meta.workflow_family[3], 'update-job')

		local status = wait_retained_payload_where(conn, topics.update_manager_status(), 'update manager status', function (p)
			return p and p.available == true
		end, { timeout = 1.0 })
		assert_eq(status.available, true)

		local summary = wait_retained_payload_where(conn, topics.update_summary(), 'update summary ready', function (p)
			return p and p.ready == true
		end, { timeout = 1.0 })
		assert_eq(summary.service, 'update')
		assert_eq(summary.ready, true)

		local reply, err = conn:call(topics.update_manager_rpc('create-job'), {
			job_id = 'j-cap-1',
			component = 'cm5',
			artifact_ref = 'artifact-cap-1',
		}, { timeout = 1.0 })
		assert_not_nil(reply, err)
		assert_eq(reply.ok, true)
		assert_eq(reply.job.job_id, 'j-cap-1')

		local job = probe.wait_retained_payload(conn, topics.workflow_update_job('j-cap-1'), { timeout = 1.0 })
		assert_eq(job.job_id, 'j-cap-1')
		assert_eq(job.component, 'cm5')
		assert_eq(job.artifact_ref, 'artifact-cap-1')

		local component = probe.wait_retained_payload(conn, topics.update_component('cm5'), { timeout = 1.0 })
		assert_eq(component.kind, 'update.component')
		assert_not_nil(component.jobs.by_id['j-cap-1'])

		h.child:cancel('test complete')
	end, { timeout = 5.0 })
end

function T.update_artifact_ingest_uses_public_cap_and_workflow_record()
	runfibers.run(function(scope)
		local h = start_update(scope)
		local conn = h.caller
		local sink = new_sink({ artifact_id = 'artifact-ingest-1', ref = 'artifact-ingest-1' })

		local meta = probe.wait_retained_payload(conn, topics.artifact_ingest_meta(), { timeout = 1.0 })
		assert_eq(meta.owner, 'update')
		assert_eq(meta.class, 'artifact-ingest')
		assert_true(has_value(meta.methods, 'create'), 'ingest meta should list create')
		assert_true(has_value(meta.methods, 'commit'), 'ingest meta should list commit')

		local created, create_err = conn:call(topics.artifact_ingest_rpc('create'), {
			ingest_id = 'ing-public-1',
			component = 'cm5',
			sink = sink,
		}, { timeout = 1.0 })
		assert_not_nil(created, create_err)
		assert_eq(created.ok, true)

		local appended, append_err = conn:call(topics.artifact_ingest_rpc('append'), {
			ingest_id = 'ing-public-1',
			chunk = 'abc',
		}, { timeout = 1.0 })
		assert_not_nil(appended, append_err)
		assert_eq(appended.ok, true)
		assert_eq(sink.chunks[1], 'abc')

		local committed, commit_err = conn:call(topics.artifact_ingest_rpc('commit'), {
			ingest_id = 'ing-public-1',
		}, { timeout = 1.0 })
		assert_not_nil(committed, commit_err)
		assert_eq(committed.ok, true)
		assert_eq(committed.commit.artifact.artifact_id, 'artifact-ingest-1')

		local rec = wait_retained_payload_where(conn, topics.workflow_artifact_ingest('ing-public-1'), 'ingest committed', function (p)
			return p and p.state == 'committed'
		end, { timeout = 1.0 })
		assert_eq(rec.ingest_id, 'ing-public-1')
		assert_eq(rec.state, 'committed')
		assert_eq(rec.bytes, 3)
		assert_eq(rec.artifact.artifact_id, 'artifact-ingest-1')

		h.child:cancel('test complete')
	end, { timeout = 5.0 })
end

function T.ui_upload_drives_update_public_ingest_and_manager_caps()
	runfibers.run(function(scope)
		local bus = busmod.new()
		local h = start_update(scope, { bus = bus })
		local conn = h.caller
		local sink = new_sink({ artifact_id = 'artifact-upload-1', ref = 'artifact-upload-1' })

		local st, _, result = fibers.perform(upload.run_op({
			body_stream = body_from_chunks({ 'hello', 'world' }),
		}, {
			bus = bus,
			sink = sink,
			component = 'cm5',
			ingest_id = 'ing-upload-1',
			job_id = 'j-upload-1',
			create_job = true,
			timeout = 1.0,
		}))
		assert_eq(st, 'ok')
		assert_not_nil(result)
		assert_not_nil(result.job)
		assert_eq(result.job.job_id, 'j-upload-1')
		assert_eq(sink.chunks[1], 'hello')
		assert_eq(sink.chunks[2], 'world')

		local job = probe.wait_retained_payload(conn, topics.workflow_update_job('j-upload-1'), { timeout = 1.0 })
		assert_eq(job.job_id, 'j-upload-1')
		assert_eq(job.component, 'cm5')

		local rec = wait_retained_payload_where(conn, topics.workflow_artifact_ingest('ing-upload-1'), 'upload ingest committed', function (p)
			return p and p.state == 'committed'
		end, { timeout = 1.0 })
		assert_eq(rec.state, 'committed')
		assert_eq(rec.bytes, 10)
		assert_eq(rec.artifact.artifact_id, 'artifact-upload-1')

		h.child:cancel('test complete')
	end, { timeout = 5.0 })
end

return T
