-- devicecode/mcu_update_wiring.lua
--
-- Composition-only MCU update wiring for the CM5 dev runtime. It connects the
-- existing UI upload, update job runner, artifact store, and Fabric transfer
-- manager without changing those services' core behaviour.

local fibers = require 'fibers'
local sleep  = require 'fibers.sleep'

local authz = require 'devicecode.authz'
local resource = require 'devicecode.support.resource'
local cap_sdk = require 'services.hal.sdk.cap'
local artifact_ingest = require 'services.ui.update.artifact_ingest'
local fabric_topics = require 'services.fabric.topics'

local M = {}

local DEFAULT_LINK_ID = 'mcu0'
local DEFAULT_PREPARE_TARGET = 'mcu'
local DEFAULT_TRANSFER_TARGET = 'updater/main'
local DEFAULT_TIMEOUT_S = 900.0
local DEFAULT_CHUNK_SIZE = 1024
local DEFAULT_SESSION_RETRY_TIMEOUT_S = 30.0

local new_store_backed_ingest

local function copy(t)
	local out = {}
	for k, v in pairs(t or {}) do
		out[k] = v
	end
	return out
end

local function unwrap_scope(scope_op)
	return scope_op:wrap(function (st, _rep, result_or_primary, err)
		if st == 'ok' then
			if result_or_primary == nil and err ~= nil then
				return nil, err
			end
			return result_or_primary, err
		end
		return nil, result_or_primary or st
	end)
end

local function env_bool(name)
	local v = os.getenv(name)
	if v == nil then return nil end
	v = tostring(v):lower()
	if v == '' or v == '0' or v == 'false' or v == 'no' or v == 'off' then
		return false
	end
	return true
end

local function cfg_from(params)
	local cfg = params and params.mcu_update or nil
	if type(cfg) == 'table' then return cfg end
	return {}
end

function M.enabled(params)
	local cfg = params and params.mcu_update or nil
	if type(cfg) == 'table' and cfg.enabled ~= nil then
		return cfg.enabled == true
	end
	if type(cfg) == 'boolean' then
		return cfg
	end

	local env_enabled = env_bool('DEVICECODE_MCU_UPDATE')
	if env_enabled ~= nil then return env_enabled end

	local target = os.getenv('CONFIG_TARGET') or os.getenv('DEVICECODE_CONFIG')
	return target == 'mcu-dev'
end

local function opt(cfg, key, default)
	if cfg[key] ~= nil then return cfg[key] end
	return default
end

local function update_upload_opts(opts, connect_as, conn, cfg)
	local out = copy(opts)
	local update = copy(out.update)

	update.component = update.component or 'mcu'
	update.create_job = update.create_job ~= false
	update.start_job = update.start_job ~= false
	update.timeout = update.timeout or DEFAULT_TIMEOUT_S
	update.upload_timeout = update.upload_timeout or DEFAULT_TIMEOUT_S
	update.connect = update.connect or connect_as
	update.principal = update.principal or authz.service_principal('ui')
	update.ingest = update.ingest or new_store_backed_ingest(conn, cfg or {})

	out.update = update
	return out
end

local function expected_image_id(job)
	local meta = type(job) == 'table' and type(job.metadata) == 'table' and job.metadata or {}
	return meta.expected_image_id
		or meta.compat_commit_image_id
		or meta.image_id
		or meta['x-artifact-image-id']
end

local function artifact_ref(job)
	if type(job) ~= 'table' then return nil end
	if type(job.artifact_ref) == 'string' and job.artifact_ref ~= '' then
		return job.artifact_ref
	end
	if type(job.artifact) == 'string' and job.artifact ~= '' then
		return job.artifact
	end
	if type(job.artifact) == 'table' then
		return job.artifact.artifact_ref or job.artifact.ref or job.artifact.id
	end
	return nil
end

local function transfer_chunk_size(job, prepared, fallback)
	local n = type(job) == 'table'
		and type(job.metadata) == 'table'
		and tonumber(job.metadata.transfer_chunk_raw)
		or nil
	if type(n) ~= 'number' or n <= 0 or n % 1 ~= 0 then
		n = fallback
	end
	local max = type(prepared) == 'table' and tonumber(prepared.max_chunk_size) or nil
	if type(max) == 'number' and max > 0 and max % 1 == 0 and n > max then
		n = max
	end
	return n
end

local function rpc_reply_value(reply, err, label)
	if reply == nil then return nil, err or label end
	if type(reply) == 'table' then
		if reply.ok == false or reply.OK == false then
			return nil, reply.error or reply.err or reply.reason or label
		end
	end
	return reply, nil
end

local function cap_reply_value(reply, err, label)
	if reply == nil then return nil, err or label end
	if type(reply) ~= 'table' then return nil, label end
	if reply.ok ~= true then return nil, reply.reason or reply.err or reply.error or label end
	return reply.reason, nil
end

local function cap_reply_ok(reply, err, label)
	if reply == nil then return nil, err or label end
	if type(reply) ~= 'table' then return nil, label end
	if reply.ok ~= true then return nil, reply.reason or reply.err or reply.error or label end
	return true, nil
end

local function retained_payload(conn, topic)
	if type(conn) ~= 'table' or type(conn.retained_view) ~= 'function' then
		return nil, 'retained_view_unavailable'
	end

	local ok, view_or_err = pcall(function ()
		return conn:retained_view(topic, {})
	end)
	if not ok or view_or_err == nil then
		return nil, tostring(view_or_err or 'retained_view_failed')
	end

	local view = view_or_err
	local got_ok, msg_or_err = pcall(function ()
		return view:get(topic)
	end)
	local close_ok, close_err = pcall(function ()
		if type(view.close) == 'function' then return view:close() end
	end)
	if not close_ok then
		return nil, tostring(close_err or 'retained_view_close_failed')
	end
	if not got_ok then
		return nil, tostring(msg_or_err or 'retained_view_get_failed')
	end
	if msg_or_err == nil then return nil, nil end
	return msg_or_err.payload, nil
end

local function session_snapshot(payload)
	if type(payload) ~= 'table' then return nil end
	if type(payload.snapshot) == 'table' then return payload.snapshot end
	if type(payload.status) == 'table' then return payload.status end
	return payload
end

local function session_token_from_snapshot(snapshot)
	if type(snapshot) ~= 'table' then return nil end
	if snapshot.established ~= true and snapshot.phase ~= 'established' then return nil end
	if type(snapshot.session_generation) ~= 'number' then return nil end
	if type(snapshot.peer_sid) ~= 'string' or snapshot.peer_sid == '' then return nil end
	return {
		session_generation = snapshot.session_generation,
		peer_sid = snapshot.peer_sid,
		peer_node = snapshot.peer_node,
	}
end

local function same_session_token(a, b)
	return type(a) == 'table'
		and type(b) == 'table'
		and a.session_generation == b.session_generation
		and a.peer_sid == b.peer_sid
end

local function current_session_token(conn, link_id)
	local payload = retained_payload(conn, fabric_topics.state_link_component(link_id, 'session'))
	return session_token_from_snapshot(session_snapshot(payload))
end

local function retryable_prepare_error(err)
	local s = tostring(err or '')
	return s == 'liveness_timeout'
		or s == 'timeout'
		or s == 'no_session'
		or s:match('session_dropped') ~= nil
		or s:match('stale_session') ~= nil
		or s:match('outbound_call_closed') ~= nil
end

local function wait_for_fresh_session(self, previous)
	local topic = fabric_topics.state_link_component(self.link_id, 'session')
	local ok, view_or_err = pcall(function ()
		return self.conn:retained_view(topic, {})
	end)
	if not ok or view_or_err == nil then
		return nil, tostring(view_or_err or 'retained_view_failed')
	end

	local view = view_or_err
	local deadline = fibers.now() + self.session_retry_timeout_s
	local version = view:version()

	local function close_view()
		pcall(function ()
			if type(view.close) == 'function' then view:close() end
		end)
	end

	local function inspect()
		local msg = view:get(topic)
		local token = session_token_from_snapshot(session_snapshot(msg and msg.payload))
		if token ~= nil and not same_session_token(token, previous) then
			return token
		end
		return nil
	end

	local token = inspect()
	if token ~= nil then
		close_view()
		return token, nil
	end

	while true do
		local remaining = deadline - fibers.now()
		if remaining <= 0 then
			close_view()
			return nil, 'fabric_session_retry_timeout'
		end

		local which, changed_version, changed_err = fibers.perform(fibers.named_choice {
			changed = view:changed_op(version),
			timeout = sleep.sleep_op(remaining),
		})
		if which == 'timeout' then
			close_view()
			return nil, 'fabric_session_retry_timeout'
		end
		if changed_version == nil then
			close_view()
			return nil, changed_err or 'fabric_session_view_closed'
		end
		version = changed_version

		token = inspect()
		if token ~= nil then
			close_view()
			return token, nil
		end
	end
end

local StoreBackedIngest = {}
StoreBackedIngest.__index = StoreBackedIngest

local SinkAdapter = {}
SinkAdapter.__index = SinkAdapter

function SinkAdapter:append_op(chunk)
	return self.sink:append_op(chunk):wrap(function (ok, err)
		if ok == true then return true, nil end
		return nil, err or 'artifact_sink_append_failed'
	end)
end

local function artifact_ref_from_handle(artifact)
	if type(artifact) == 'table' and type(artifact.ref) == 'function' then
		local ok, ref = pcall(function () return artifact:ref() end)
		if ok and type(ref) == 'string' and ref ~= '' then return ref end
	end
	if type(artifact) == 'table' and type(artifact.describe) == 'function' then
		local ok, desc = pcall(function () return artifact:describe() end)
		if ok and type(desc) == 'table' and type(desc.artifact_ref) == 'string' then
			return desc.artifact_ref
		end
	end
	return artifact
end

function SinkAdapter:commit_op(...)
	return self.sink:commit_op(...):wrap(function (ok, artifact_or_err)
		if ok == true then return artifact_ref_from_handle(artifact_or_err), nil end
		return nil, artifact_or_err or 'artifact_sink_commit_failed'
	end)
end

function SinkAdapter:terminate(reason)
	return self.sink:terminate(reason)
end

local function sink_meta(opts)
	local meta = copy(type(opts.metadata) == 'table' and opts.metadata or {})
	meta.component = meta.component or opts.component
	meta.ingest_id = meta.ingest_id or opts.ingest_id
	return meta
end

function StoreBackedIngest:open_ingest_op(opts)
	opts = copy(opts or {})

	return unwrap_scope(fibers.run_scope_op(function (scope)
		local create_opts, create_err = cap_sdk.args.new.ArtifactStoreCreateSinkOpts(
			sink_meta(opts),
			self.policy
		)
		if not create_opts then return nil, create_err or 'artifact_sink_opts_failed' end

		local store = cap_sdk.new_curated_cap_ref(self.conn, 'artifact_store', self.artifact_store)
		local reply, call_err = fibers.perform(store:call_control_op('create_sink', create_opts, {
			timeout = self.artifact_timeout_s,
		}))
		local sink, sink_err = cap_reply_value(reply, call_err, 'artifact_sink_create_failed')
		if not sink then return nil, sink_err end
		sink = setmetatable({ sink = sink }, SinkAdapter)

		local sink_owner = resource.owned(sink, {
			label = 'mcu upload artifact sink cleanup failed',
		})
		scope:finally(function (_, status, primary)
			sink_owner:terminate_checked(
				primary or status or 'mcu upload ingest open failed',
				'mcu upload artifact sink cleanup failed'
			)
		end)

		opts.sink = sink
		local handle, open_err = fibers.perform(self.ingest:open_ingest_op(opts))
		if not handle then return nil, open_err or 'artifact_ingest_open_failed' end

		local _, detach_err = sink_owner:detach()
		if detach_err then return nil, detach_err end
		return handle, nil
	end))
end

new_store_backed_ingest = function (conn, cfg)
	local built, err = artifact_ingest.bus_client(conn)
	if not built then error(err or 'artifact ingest bus client unavailable', 0) end
	return setmetatable({
		conn = conn,
		ingest = built,
		artifact_store = opt(cfg, 'artifact_store', 'main'),
		policy = opt(cfg, 'artifact_policy', 'transient_only'),
		artifact_timeout_s = opt(cfg, 'artifact_timeout_s', 10.0),
	}, StoreBackedIngest)
end

local function make_update_payload(self, job)
	return {
		job_id = job.job_id,
		target = self.prepare_target,
		expected_image_id = expected_image_id(job),
		metadata = job.metadata,
	}
end

local Backend = {}
Backend.__index = Backend

function Backend:prepare_op(job, _ctx)
	return unwrap_scope(fibers.run_scope_op(function ()
		local before = current_session_token(self.conn, self.link_id)
		local reply, err = fibers.perform(self.conn:call_op(self.prepare_topic, make_update_payload(self, job), {
			timeout = self.rpc_timeout_s,
		}))
		local prepared, perr = rpc_reply_value(reply, err, 'prepare_failed')
		if perr and retryable_prepare_error(perr) then
			local token, wait_err = wait_for_fresh_session(self, before)
			if token ~= nil then
				reply, err = fibers.perform(self.conn:call_op(self.prepare_topic, make_update_payload(self, job), {
					timeout = self.rpc_timeout_s,
				}))
				prepared, perr = rpc_reply_value(reply, err, 'prepare_failed')
			else
				perr = wait_err or perr
			end
		end
		return prepared, perr
	end))
end

function Backend:stage_op(job, ctx)
	return unwrap_scope(fibers.run_scope_op(function (scope)
		local ref = artifact_ref(job)
		if type(ref) ~= 'string' or ref == '' then
			return nil, 'artifact_ref_required'
		end

		local store = cap_sdk.new_curated_cap_ref(self.conn, 'artifact_store', self.artifact_store)
		local open_opts, open_err = cap_sdk.args.new.ArtifactStoreOpenOpts(ref)
		if not open_opts then return nil, open_err or 'artifact_open_opts_failed' end

		local open_reply, open_call_err = fibers.perform(store:call_control_op('open', open_opts, {
			timeout = self.artifact_timeout_s,
		}))
		local artifact, artifact_err = cap_reply_value(open_reply, open_call_err, 'artifact_open_failed')
		if not artifact then return nil, artifact_err end

		local ok_source, source_or_err = fibers.perform(artifact:open_source_op())
		if ok_source ~= true then return nil, source_or_err or 'artifact_source_open_failed' end

		local source_owner = resource.owned(source_or_err, {
			label = 'mcu update transfer source cleanup failed',
		})
		scope:finally(function (_, status, primary)
			source_owner:terminate_checked(
				primary or status or 'mcu update stage closed',
				'mcu update transfer source cleanup failed'
			)
		end)

		local desc = artifact:describe()
		local prepared = type(ctx) == 'table' and type(ctx.prepared) == 'table' and ctx.prepared or {}
		local timeout_s = self.transfer_timeout_s
		local request = {
			source_owner = source_owner,
			link_id = self.link_id,
			request_id = job.job_id,
			xfer_id = job.job_id,
			target = prepared.target or self.transfer_target,
			size = desc.size,
			digest_alg = desc.digest_alg or 'xxhash32',
			digest = desc.checksum,
			timeout_s = timeout_s,
			chunk_size = transfer_chunk_size(job, prepared, self.chunk_size),
			meta = {
				job_id = job.job_id,
				component = job.component,
				artifact_ref = ref,
				metadata = job.metadata,
			},
		}

		local transfer_reply, transfer_err = fibers.perform(self.conn:call_op(
			fabric_topics.transfer_manager_rpc('send-blob'),
			request,
			{ timeout = timeout_s + 5.0 }
		))
		local transfer, xerr = rpc_reply_value(transfer_reply, transfer_err, 'transfer_failed')
		if not transfer then return nil, xerr end

		local delete_opts, delete_err = cap_sdk.args.new.ArtifactStoreDeleteOpts(ref)
		local cleanup = { attempted = delete_opts ~= nil }
		if delete_opts then
			local delete_reply, derr = fibers.perform(store:call_control_op('delete', delete_opts, {
				timeout = self.artifact_timeout_s,
			}))
			local deleted, cleanup_err = cap_reply_ok(delete_reply, derr, 'artifact_delete_failed')
			cleanup.ok = deleted == true
			cleanup.err = cleanup_err
		else
			cleanup.err = delete_err
		end

		return {
			tag = 'mcu_staged',
			artifact_ref = ref,
			transfer = transfer,
			cleanup = cleanup,
		}
	end))
end

function Backend:commit_policy()
	return 'idempotent_by_token'
end

function Backend:commit_op(job, _ctx)
	return unwrap_scope(fibers.run_scope_op(function ()
		local reply, err = fibers.perform(self.conn:call_op(self.commit_topic, make_update_payload(self, job), {
			timeout = self.rpc_timeout_s,
		}))
		local value, rerr = rpc_reply_value(reply, err, 'commit_failed')
		if not value then return nil, rerr end
		if type(value) == 'table' and value.accepted == false then
			return nil, value.error or value.err or 'commit_rejected'
		end
		return value
	end))
end

function Backend:evaluate_reconcile(job, _snapshot, _ctx)
	return {
		done = true,
		tag = 'reconciled_success',
		job_id = job.job_id,
	}
end

local function new_backend(conn, cfg)
	cfg = cfg or {}
	return setmetatable({
		conn = conn,
		link_id = opt(cfg, 'link_id', DEFAULT_LINK_ID),
		artifact_store = opt(cfg, 'artifact_store', 'main'),
		prepare_target = opt(cfg, 'prepare_target', DEFAULT_PREPARE_TARGET),
		transfer_target = opt(cfg, 'transfer_target', DEFAULT_TRANSFER_TARGET),
		chunk_size = opt(cfg, 'chunk_size', DEFAULT_CHUNK_SIZE),
		rpc_timeout_s = opt(cfg, 'rpc_timeout_s', 15.0),
		artifact_timeout_s = opt(cfg, 'artifact_timeout_s', 10.0),
		transfer_timeout_s = opt(cfg, 'transfer_timeout_s', DEFAULT_TIMEOUT_S),
		session_retry_timeout_s = opt(cfg, 'session_retry_timeout_s', DEFAULT_SESSION_RETRY_TIMEOUT_S),
		prepare_topic = opt(cfg, 'prepare_topic', { 'raw', 'member', 'mcu', 'cmd', 'self', 'updater', 'prepare' }),
		commit_topic = opt(cfg, 'commit_topic', { 'raw', 'member', 'mcu', 'cmd', 'self', 'updater', 'commit' }),
	}, Backend)
end

function M.apply_service_opts(name, conn, connect_as, opts, params)
	opts = copy(opts)
	if not M.enabled(params) then return opts end

	if name == 'ui' then
		return update_upload_opts(opts, connect_as, conn, cfg_from(params))
	end

	if name == 'update' then
		opts.backend = new_backend(conn, cfg_from(params))
	end

	return opts
end

M._test = {
	enabled = M.enabled,
	new_backend = new_backend,
}

return M
