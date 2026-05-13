local fibers      = require 'fibers'
local runfibers   = require 'tests.support.run_fibers'
local blob_source = require 'devicecode.blob_source'

local store_mod   = require 'services.hal.drivers.artifact_store'

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

function T.artifact_store_imports_source_opens_and_deletes_transient_artifact()
	local base = mk_tmpdir('as-driver-roundtrip')
	local transient_root = base .. '/transient'
	local durable_root = base .. '/durable'

	runfibers.run(function()
		local store = store_mod.new({
			transient_root = transient_root,
			durable_root = durable_root,
			durable_enabled = false,
		}, nil)

		local ok_import, artifact = fibers.perform(store:import_source_op(
			blob_source.from_string('hello'),
			{ kind = 'update', target = 'mcu' },
			{ policy = 'transient_only' }
		))
		assert(ok_import == true, tostring(artifact))

		local rec = artifact:describe()
		assert(rec.durability == 'transient')
		assert(rec.state == 'ready')
		assert(rec.size == 5)
		assert(type(rec.checksum) == 'string')
		assert(#rec.checksum == 8)

		local ok_open_src, src = fibers.perform(artifact:open_source_op())
		assert(ok_open_src == true, tostring(src))

		local chunk, err = fibers.perform(src:read_chunk_op(99))
		assert(err == nil)
		assert(chunk == 'hello')

		local eof, eof_err = fibers.perform(src:read_chunk_op(99))
		assert(eof == nil)
		assert(eof_err == nil)

		local ok_resolve, resolved = fibers.perform(store:resolve_local_op(artifact:ref()))
		assert(ok_resolve == true, tostring(resolved))
		assert(type(resolved.path) == 'string')

		local ok_delete, err_delete = fibers.perform(store:delete_op(artifact:ref()))
		assert(ok_delete == true, tostring(err_delete))

		local ok_open, open_err = fibers.perform(store:open_op(artifact:ref()))
		assert(ok_open == false)
		assert(open_err == 'not_found')
	end)

	rm_rf(base)
end

function T.artifact_store_honours_durability_policy()
	local base = mk_tmpdir('as-driver-policy')
	local transient_root = base .. '/transient'
	local durable_root = base .. '/durable'

	runfibers.run(function()
		local store = store_mod.new({
			transient_root = transient_root,
			durable_root = durable_root,
			durable_enabled = false,
		}, nil)

		local ok_art, art_or_err = fibers.perform(store:import_source_op(
			blob_source.from_string('a'),
			{ kind = 'update' },
			{ policy = 'prefer_durable' }
		))
		assert(ok_art == true, tostring(art_or_err))
		assert(art_or_err:describe().durability == 'transient')

		local ok_sink, sink_or_err = fibers.perform(store:create_sink_op(
			{ kind = 'update' },
			{ policy = 'require_durable' }
		))
		assert(ok_sink == false)
		assert(sink_or_err == 'durable_disabled')

		local store2 = store_mod.new({
			transient_root = transient_root,
			durable_root = durable_root,
			durable_enabled = true,
		}, nil)

		local ok_art2, art2_or_err = fibers.perform(store2:import_source_op(
			blob_source.from_string('b'),
			{ kind = 'update' },
			{ policy = 'require_durable' }
		))
		assert(ok_art2 == true, tostring(art2_or_err))
		assert(art2_or_err:describe().durability == 'durable')
	end)

	rm_rf(base)
end

function T.artifact_store_imports_path_and_reports_status()
	local base = mk_tmpdir('as-driver-path')
	local transient_root = base .. '/transient'
	local durable_root = base .. '/durable'
	local import_root = base .. '/incoming'

	os.execute(('mkdir -p %q'):format(import_root))

	local f = assert(io.open(import_root .. '/fw.bin', 'wb'))
	assert(f:write('firmware-bytes'))
	assert(f:close())

	runfibers.run(function()
		local store = store_mod.new({
			transient_root = transient_root,
			durable_root = durable_root,
			import_root = import_root,
			durable_enabled = false,
		}, nil)

		local ok_import, artifact = fibers.perform(store:import_path_op('fw.bin', {
			kind = 'firmware',
			target = 'cm5',
		}, {
			policy = 'prefer_durable',
		}))
		assert(ok_import == true, tostring(artifact))

		local rec = artifact:describe()
		assert(rec.durability == 'transient')
		assert(rec.state == 'ready')

		local ok_status, status = fibers.perform(store:status_op())
		assert(ok_status == true, tostring(status))
		assert(status.kind == 'artifact_store')
		assert(status.transient_root == transient_root)
		assert(status.durable_root == durable_root)
		assert(status.durable_enabled == false)
		assert(status.import_root == import_root)
	end)

	rm_rf(base)
end

function T.artifact_sink_close_aborts_open_session_and_cleans_up_partial_artifact()
	local base = mk_tmpdir('as-driver-close-abort')
	local transient_root = base .. '/transient'
	local durable_root = base .. '/durable'

	runfibers.run(function()
		local store = store_mod.new({
			transient_root = transient_root,
			durable_root = durable_root,
			durable_enabled = false,
		}, nil)

		local ok_sink, sink_or_err = fibers.perform(store:create_sink_op(
			{ kind = 'update', target = 'mcu' },
			{ policy = 'transient_only' }
		))
		assert(ok_sink == true, tostring(sink_or_err))
		local sink = sink_or_err

		local ref = sink:status().artifact_ref

		local ok_write, write_err = fibers.perform(sink:write_chunk_op('partial-data'))
		assert(ok_write == true, tostring(write_err))

		local ok_close, close_err = fibers.perform(sink:close_op())
		assert(ok_close == true, tostring(close_err))

		local snapshot = sink:status()
		assert(snapshot.terminal == true)
		assert(snapshot.state == 'aborted')

		local ok_open, open_err = fibers.perform(store:open_op(ref))
		assert(ok_open == false)
		assert(open_err == 'not_found')

		local ok_resolve, resolve_err = fibers.perform(store:resolve_local_op(ref))
		assert(ok_resolve == false)
		assert(resolve_err == 'not_found')
	end)

	rm_rf(base)
end

function T.artifact_sink_commit_is_idempotent_for_same_session()
	local base = mk_tmpdir('as-driver-idempotent-commit')
	local transient_root = base .. '/transient'
	local durable_root = base .. '/durable'

	runfibers.run(function()
		local store = store_mod.new({
			transient_root = transient_root,
			durable_root = durable_root,
			durable_enabled = false,
		}, nil)

		local ok_sink, sink_or_err = fibers.perform(store:create_sink_op(
			{ kind = 'update', target = 'mcu' },
			{ policy = 'transient_only' }
		))
		assert(ok_sink == true, tostring(sink_or_err))
		local sink = sink_or_err

		local ok_write, write_err = fibers.perform(sink:write_chunk_op('payload'))
		assert(ok_write == true, tostring(write_err))

		local ok_commit1, art1_or_err = fibers.perform(sink:commit_op())
		assert(ok_commit1 == true, tostring(art1_or_err))
		local art1 = art1_or_err

		local ok_commit2, art2_or_err = fibers.perform(sink:commit_op())
		assert(ok_commit2 == true, tostring(art2_or_err))
		local art2 = art2_or_err

		assert(art1:ref() == art2:ref())
		assert(art1:describe().checksum == art2:describe().checksum)

		local ok_open, art_or_err = fibers.perform(store:open_op(art1:ref()))
		assert(ok_open == true, tostring(art_or_err))
	end)

	rm_rf(base)
end

return T
