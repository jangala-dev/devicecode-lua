local fibers      = require 'fibers'
local channel     = require 'fibers.channel'

local runfibers   = require 'tests.support.run_fibers'
local core_types  = require 'services.hal.types.core'
local cap_args    = require 'services.hal.types.capability_args'
local blob_source = require 'devicecode.blob_source'

local provider_mod = require 'services.hal.drivers.artifact_store_provider'

local T = {}

local function mk_tmpdir(tag)
	local path = ('/tmp/dc-lua-%s-%d-%06d'):format(tag, os.time(), math.random(0, 999999))
	local ok = os.execute(('mkdir -p %q'):format(path))
	assert(ok == true or ok == 0, 'failed to create temp dir: ' .. path)
	return path
end

local function rm_rf(path)
	os.execute(('rm -rf %q'):format(path))
end

local function is_dir(path)
	local ok = os.execute(('[ -d %q ]'):format(path))
	return ok == true or ok == 0
end

local function recv_or_fail(ch)
	local v, err = fibers.perform(ch:get_op())
	assert(v, tostring(err))
	return v
end

local function request(driver, verb, opts)
	local reply_ch = channel.new(1)
	local req, err = core_types.new.ControlRequest(verb, opts or {}, reply_ch)
	assert(req, tostring(err))

	local sent, send_err = fibers.perform(driver.control_ch:put_op(req))
	assert(sent ~= false, tostring(send_err))

	local reply, recv_err = fibers.perform(reply_ch:get_op())
	assert(reply, tostring(recv_err))
	return reply
end

function T.capabilities_op_returns_artifact_store_capability()
	local base = mk_tmpdir('as-provider-cap')
	local transient_root = base .. '/transient'
	local durable_root = base .. '/durable'
	local emit_ch = channel.new(8)

	runfibers.run(function()
		local driver = provider_mod.new('main', {
			transient_root = transient_root,
			durable_root = durable_root,
			durable_enabled = false,
		}, nil)

		local ok, caps_or_err = fibers.perform(driver:capabilities_op(emit_ch))
		assert(ok == true, tostring(caps_or_err))
		assert(type(caps_or_err) == 'table')
		assert(#caps_or_err == 1)

		local cap = caps_or_err[1]
		assert(cap.class == 'artifact-store')
		assert(cap.id == 'main')
		assert(cap.offerings['create-sink'] == true)
		assert(cap.offerings['import-path'] == true)
		assert(cap.offerings['import-source'] == true)
		assert(cap.offerings.open == true)
		assert(cap.offerings.delete == true)
		assert(cap.offerings.status == true)
	end)

	rm_rf(base)
end

function T.start_op_emits_initial_meta_and_available_state()
	local base = mk_tmpdir('as-provider-start')
	local transient_root = base .. '/transient'
	local durable_root = base .. '/durable'
	local emit_ch = channel.new(8)

	runfibers.run(function(scope)
		local driver = provider_mod.new('main', {
			transient_root = transient_root,
			durable_root = durable_root,
			durable_enabled = false,
		}, nil)

		local ok_caps, caps_err = fibers.perform(driver:capabilities_op(emit_ch))
		assert(ok_caps == true, tostring(caps_err))

		local ok_start, start_err = fibers.perform(driver:start_op(scope))
		assert(ok_start == true, tostring(start_err))

		local e1 = recv_or_fail(emit_ch)
		local e2 = recv_or_fail(emit_ch)

		local by_mode = {
			[e1.mode] = e1,
			[e2.mode] = e2,
		}

		assert(by_mode.meta ~= nil)
		assert(by_mode.state ~= nil)

		assert(by_mode.meta.class == 'artifact-store')
		assert(by_mode.meta.id == 'main')
		assert(by_mode.meta.key == 'info')
		assert(by_mode.meta.data.transient_root == transient_root)
		assert(by_mode.meta.data.durable_root == durable_root)
		assert(by_mode.meta.data.durable_enabled == false)

		assert(by_mode.state.key == 'status')
		assert(by_mode.state.data.state == 'available')

		local ok_stop, stop_err = fibers.perform(driver:shutdown_op())
		assert(ok_stop == true, tostring(stop_err))
	end)

	rm_rf(base)
end

function T.start_op_creates_missing_artifact_roots_before_advertising_available()
	local base = mk_tmpdir('as-provider-missing-roots')
	local transient_root = base .. '/transient'
	local durable_root = base .. '/durable'
	local import_root = base .. '/imports'
	local emit_ch = channel.new(8)
	rm_rf(transient_root)
	rm_rf(durable_root)
	rm_rf(import_root)

	runfibers.run(function(scope)
		local driver = provider_mod.new('main', {
			transient_root = transient_root,
			durable_root = durable_root,
			import_root = import_root,
			durable_enabled = true,
		}, nil)

		local ok_caps, caps_err = fibers.perform(driver:capabilities_op(emit_ch))
		assert(ok_caps == true, tostring(caps_err))

		local ok_start, start_err = fibers.perform(driver:start_op(scope))
		assert(ok_start == true, tostring(start_err))

		recv_or_fail(emit_ch)
		recv_or_fail(emit_ch)

		local ok_stop, stop_err = fibers.perform(driver:shutdown_op())
		assert(ok_stop == true, tostring(stop_err))
	end)

	assert(is_dir(transient_root) == true, 'transient artifact root should be created')
	assert(is_dir(durable_root) == true, 'durable artifact root should be created')
	assert(is_dir(import_root) == true, 'artifact import root should be created')
	rm_rf(base)
end

function T.create_sink_commit_open_and_delete_round_trip()
	local base = mk_tmpdir('as-provider-roundtrip')
	local transient_root = base .. '/transient'
	local durable_root = base .. '/durable'
	local emit_ch = channel.new(8)

	runfibers.run(function(scope)
		local driver = provider_mod.new('main', {
			transient_root = transient_root,
			durable_root = durable_root,
			durable_enabled = false,
		}, nil)

		local ok_caps, caps_err = fibers.perform(driver:capabilities_op(emit_ch))
		assert(ok_caps == true, tostring(caps_err))

		local ok_start, start_err = fibers.perform(driver:start_op(scope))
		assert(ok_start == true, tostring(start_err))

		local create_opts = assert(cap_args.new.ArtifactStoreCreateSinkOpts(
			{ kind = 'update', target = 'mcu' },
			'transient_only'
		))
		local create_reply = request(driver, 'create-sink', create_opts)
		assert(create_reply.ok == true)

		local sink = create_reply.reason
		local ok_write, write_err = fibers.perform(sink:write_chunk_op('hello'))
		assert(ok_write == true, tostring(write_err))

		local artifact, commit_err = fibers.perform(sink:commit_op())
		assert(artifact ~= nil, tostring(commit_err))

		local open_opts = assert(cap_args.new.ArtifactStoreOpenOpts(artifact:ref()))
		local open_reply = request(driver, 'open', open_opts)
		assert(open_reply.ok == true)

		local opened = open_reply.reason
		local ok_src, src_or_err = fibers.perform(opened:open_source_op())
		assert(ok_src == true, tostring(src_or_err))

		local chunk, err = fibers.perform(src_or_err:read_chunk_op(99))
		assert(err == nil)
		assert(chunk == 'hello')

		local del_opts = assert(cap_args.new.ArtifactStoreDeleteOpts(artifact:ref()))
		local del_reply = request(driver, 'delete', del_opts)
		assert(del_reply.ok == true)

		local status_reply = request(driver, 'status', assert(cap_args.new.ArtifactStoreStatusOpts()))
		assert(status_reply.ok == true)
		assert(status_reply.reason.kind == 'artifact-store')

		local ok_stop, stop_err = fibers.perform(driver:shutdown_op())
		assert(ok_stop == true, tostring(stop_err))
	end)

	rm_rf(base)
end

function T.import_source_request_round_trips_success()
	local base = mk_tmpdir('as-provider-import-source')
	local transient_root = base .. '/transient'
	local durable_root = base .. '/durable'
	local emit_ch = channel.new(8)

	runfibers.run(function(scope)
		local driver = provider_mod.new('main', {
			transient_root = transient_root,
			durable_root = durable_root,
			durable_enabled = false,
		}, nil)

		local ok_caps, caps_err = fibers.perform(driver:capabilities_op(emit_ch))
		assert(ok_caps == true, tostring(caps_err))

		local ok_start, start_err = fibers.perform(driver:start_op(scope))
		assert(ok_start == true, tostring(start_err))

		local import_opts = assert(cap_args.new.ArtifactStoreImportSourceOpts(
			blob_source.from_string('firmware'),
			{ kind = 'firmware', target = 'cm5' },
			'transient_only'
		))

		local reply = request(driver, 'import-source', import_opts)
		assert(reply.ok == true)

		local artifact = reply.reason
		local rec = artifact:describe()
		assert(rec.state == 'ready')
		assert(rec.size == 8)

		local ok_stop, stop_err = fibers.perform(driver:shutdown_op())
		assert(ok_stop == true, tostring(stop_err))
	end)

	rm_rf(base)
end

function T.shutdown_op_before_start_is_ok_and_fault_op_is_inert()
	local base = mk_tmpdir('as-provider-stop')
	local transient_root = base .. '/transient'
	local durable_root = base .. '/durable'

	runfibers.run(function()
		local driver = provider_mod.new('main', {
			transient_root = transient_root,
			durable_root = durable_root,
			durable_enabled = false,
		}, nil)

		local ok_stop, stop_err = fibers.perform(driver:shutdown_op())
		assert(ok_stop == true, tostring(stop_err))

		local which = fibers.perform(require('fibers').named_choice{
			fault = driver:fault_op():wrap(function(...) return 'fault', ... end),
			timeout = require('fibers.sleep').sleep_op(0.05):wrap(function() return 'timeout' end),
		})
		assert(which == 'timeout')
	end)

	rm_rf(base)
end

function T.create_sink_close_aborts_partial_artifact()
	local base = mk_tmpdir('as-provider-close')
	local transient_root = base .. '/transient'
	local durable_root = base .. '/durable'
	local emit_ch = channel.new(8)

	runfibers.run(function(scope)
		local driver = provider_mod.new('main', {
			transient_root = transient_root,
			durable_root = durable_root,
			durable_enabled = false,
		}, nil)

		local ok_caps, caps_err = fibers.perform(driver:capabilities_op(emit_ch))
		assert(ok_caps == true, tostring(caps_err))

		local ok_start, start_err = fibers.perform(driver:start_op(scope))
		assert(ok_start == true, tostring(start_err))

		local create_opts = assert(cap_args.new.ArtifactStoreCreateSinkOpts(
			{ kind = 'update', target = 'mcu' },
			'transient_only'
		))

		local create_reply = request(driver, 'create-sink', create_opts)
		assert(create_reply.ok == true)
		local sink = create_reply.reason

		local ref = sink:status().artifact_ref

		local ok_write, write_err = fibers.perform(sink:write_chunk_op('partial'))
		assert(ok_write == true, tostring(write_err))

		local ok_close, close_err = fibers.perform(sink:close_op())
		assert(ok_close == true, tostring(close_err))

		local open_opts = assert(cap_args.new.ArtifactStoreOpenOpts(ref))
		local open_reply = request(driver, 'open', open_opts)
		assert(open_reply.ok == false)
		assert(open_reply.reason == 'not_found')

		local ok_stop, stop_err = fibers.perform(driver:shutdown_op())
		assert(ok_stop == true, tostring(stop_err))
	end)

	rm_rf(base)
end

function T.commit_is_idempotent_for_same_provider_sink_session()
	local base = mk_tmpdir('as-provider-idempotent')
	local transient_root = base .. '/transient'
	local durable_root = base .. '/durable'
	local emit_ch = channel.new(8)

	runfibers.run(function(scope)
		local driver = provider_mod.new('main', {
			transient_root = transient_root,
			durable_root = durable_root,
			durable_enabled = false,
		}, nil)

		local ok_caps, caps_err = fibers.perform(driver:capabilities_op(emit_ch))
		assert(ok_caps == true, tostring(caps_err))

		local ok_start, start_err = fibers.perform(driver:start_op(scope))
		assert(ok_start == true, tostring(start_err))

		local create_opts = assert(cap_args.new.ArtifactStoreCreateSinkOpts({ kind = 'update' }, 'transient_only'))
		local create_reply = request(driver, 'create-sink', create_opts)
		assert(create_reply.ok == true)
		local sink = create_reply.reason

		local ok_write, write_err = fibers.perform(sink:write_chunk_op('abc'))
		assert(ok_write == true, tostring(write_err))

		local art1, err1 = fibers.perform(sink:commit_op())
		assert(art1 ~= nil, tostring(err1))
		local art2, err2 = fibers.perform(sink:commit_op())
		assert(art2 ~= nil, tostring(err2))
		assert(art1:ref() == art2:ref())

		local ok_stop, stop_err = fibers.perform(driver:shutdown_op())
		assert(ok_stop == true, tostring(stop_err))
	end)

	rm_rf(base)
end

return T
