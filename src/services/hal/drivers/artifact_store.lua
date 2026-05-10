---@module 'services.hal.drivers.artifact_store'

local fibers    = require 'fibers'
local op        = require 'fibers.op'
local file      = require 'fibers.io.file'
local exec      = require 'fibers.io.exec'
local channel   = require 'fibers.channel'
local pulse_mod = require 'fibers.pulse'
local cjson     = require 'cjson.safe'
local uuid      = require 'uuid'

local checksum    = require 'shared.hash.xxhash32'
local blob_source = require 'devicecode.blob_source'
local resource    = require 'devicecode.support.resource'
local tablex      = require 'shared.table'

local M = {}

---@class ArtifactStore
---@field transient_root string
---@field durable_root string
---@field durable_enabled boolean
---@field import_root string
---@field logger table|nil
local Store = {}
Store.__index = Store

---@class ArtifactHandle
---@field _store ArtifactStore
---@field _rec table
---@field _blob_path string
local Artifact = {}
Artifact.__index = Artifact

---@class ArtifactSink
---@field _cmd_ch Channel
---@field _closed Pulse
---@field _artifact_ref string
---@field _phase string
---@field _terminal boolean
---@field _artifact ArtifactHandle|nil
---@field _last_error string|nil
local ArtifactSink = {}
ArtifactSink.__index = ArtifactSink

----------------------------------------------------------------------
-- Plain helpers
----------------------------------------------------------------------


local function join_path(...)
	return table.concat({ ... }, '/')
end

local function dirname(path)
	if path == '/' then
		return '/'
	end

	local d = tostring(path or ''):match('^(.*)/[^/]+$')
	if d == nil or d == '' then
		return '.'
	end
	return d
end

local deep_copy = tablex.deep_copy

local function valid_ref(ref)
	return type(ref) == 'string'
		and ref ~= ''
		and ref:match('^[A-Za-z0-9_.-]+$') ~= nil
end

local function is_not_found_err(err)
	if err == nil then
		return false
	end
	local s = tostring(err):lower()
	return s:find('no such file', 1, true) ~= nil
		or s:find('not found', 1, true) ~= nil
		or s:find('enoent', 1, true) ~= nil
end

local function unwrap_attempt(st, rep, ok, value_or_err)
	if st ~= 'ok' then
		return false, tostring(value_or_err or rep)
	end
	return ok, value_or_err
end

local function attempt_op(fn)
	return fibers.run_scope_op(fn):wrap(unwrap_attempt)
end

----------------------------------------------------------------------
-- Durability and paths
----------------------------------------------------------------------

local function choose_durability(self, policy)
	policy = policy or 'transient_only'

	if policy == 'require_durable' then
		if not self.durable_enabled then
			return nil, 'durable_disabled'
		end
		return 'durable'
	end

	if policy == 'prefer_durable' then
		if self.durable_enabled then
			return 'durable'
		end
		return 'transient'
	end

	if policy == 'transient_only' then
		return 'transient'
	end

	return nil, 'invalid_policy'
end

local function root_for(self, durability)
	if durability == 'durable' then
		return self.durable_root
	end
	return self.transient_root
end

local function staging_root(self, durability)
	return join_path(root_for(self, durability), '.staging')
end

local function staging_dir(self, ref, durability)
	return join_path(staging_root(self, durability), ref)
end

local function object_dir(self, ref, durability)
	return join_path(root_for(self, durability), ref)
end

local function data_path(dir)
	return join_path(dir, 'blob.bin')
end

local function final_meta_path(dir)
	return join_path(dir, 'meta.json')
end

local function partial_meta_path(dir)
	return join_path(dir, 'meta.json.partial')
end

----------------------------------------------------------------------
-- Filesystem / process-backed ops
----------------------------------------------------------------------

-- Keep recursive removal boxed here until the file layer grows an rmdir/remove-tree
-- primitive. This is now used only where directory removal is genuinely required.
local function rm_rf_op(path)
	return exec.command('rm', '-rf', path):run_op():wrap(function (st, code, _sig, err)
		if st == 'exited' and code == 0 then
			return true, nil
		end
		if st == 'signalled' then
			return false, 'rm_signalled'
		end
		return false, tostring(err or ('rm_failed:' .. tostring(code)))
	end)
end

local function mkdir_p_op(path, perms)
	return attempt_op(function ()
		local ok, err = file.mkdir_p(path, perms)
		if not ok then
			return false, tostring(err)
		end
		return true, nil
	end)
end

local function rename_path_op(src, dst)
	return attempt_op(function ()
		local ok, err = file.rename(src, dst)
		if not ok then
			return false, tostring(err)
		end
		return true, nil
	end)
end

local function unlink_path_op(path, tolerate_missing)
	return attempt_op(function ()
		local ok, err = file.unlink(path)
		if ok then
			return true, nil
		end
		if tolerate_missing and is_not_found_err(err) then
			return true, nil
		end
		return false, tostring(err)
	end)
end

local function unlink_known_artifact_files_op(dir)
	return attempt_op(function ()
		local ok, err

		ok, err = fibers.perform(unlink_path_op(data_path(dir), true))
		if not ok then
			return false, err
		end

		ok, err = fibers.perform(unlink_path_op(partial_meta_path(dir), true))
		if not ok then
			return false, err
		end

		ok, err = fibers.perform(unlink_path_op(final_meta_path(dir), true))
		if not ok then
			return false, err
		end

		return true, nil
	end)
end

local function remove_artifact_dir_op(dir)
	return attempt_op(function ()
		local ok, err = fibers.perform(unlink_known_artifact_files_op(dir))
		if not ok then
			return false, err
		end

		local ok_rm, rm_err = fibers.perform(rm_rf_op(dir))
		if not ok_rm then
			return false, rm_err
		end

		return true, nil
	end)
end

local function terminate_stream(stream, reason)
	if stream == nil then
		return true, nil
	end

	return resource.terminate(stream, reason or 'artifact stream terminated')
end

local function open_stream_now(path, mode)
	local stream, err = file.open(path, mode)
	if not stream then
		return nil, tostring(err)
	end
	return stream, nil
end

local function read_text_op(path)
	return attempt_op(function (scope)
		local stream, err = open_stream_now(path, 'r')
		if not stream then
			return false, err
		end

		scope:finally(function (_, status, primary)
			resource.terminate_checked(stream, primary or status or 'artifact stream closed', 'artifact stream cleanup failed')
		end)

		local body, rerr = fibers.perform(stream:read_all_op())
		if rerr ~= nil then
			return false, tostring(rerr)
		end

		return true, body or ''
	end)
end

local function write_atomic_text_op(path, data)
	return attempt_op(function (scope)
		local dir = dirname(path)
		local ok_dir, dir_err = fibers.perform(mkdir_p_op(dir))
		if not ok_dir then
			return false, dir_err
		end

		local stream, err = file.tmpfile(384, dir)
		if not stream then
			return false, tostring(err)
		end

		scope:finally(function (_, status, primary)
			resource.terminate_checked(stream, primary or status or 'artifact stream closed', 'artifact stream cleanup failed')
		end)

		local n, werr = fibers.perform(stream:write_op(data))
		if n == nil then
			return false, tostring(werr or 'write_failed')
		end

		local okf, ferr = fibers.perform(stream:flush_op())
		if okf == nil then
			return false, tostring(ferr or 'flush_failed')
		end

		local okr, rerr = stream:rename(path)
		if not okr then
			return false, tostring(rerr or 'rename_failed')
		end

		return true, nil
	end)
end

local function read_json_op(path)
	return read_text_op(path):wrap(function (ok, body_or_err)
		if not ok then
			return false, body_or_err
		end

		local obj, derr = cjson.decode(body_or_err)
		if obj == nil then
			return false, tostring(derr or 'decode_failed')
		end

		return true, obj
	end)
end

local function write_json_op(path, obj)
	local raw, err = cjson.encode(obj)
	if not raw then
		return op.always(false, tostring(err or 'encode_failed'))
	end
	return write_atomic_text_op(path, raw)
end

----------------------------------------------------------------------
-- Metadata helpers
----------------------------------------------------------------------

local function new_ready_record(ref, durability, size, checksum_hex, meta, created_at)
	local now = os.time()
	return {
		version      = 2,
		artifact_ref = ref,
		state        = 'ready',
		durability   = durability,
		size         = size,
		checksum     = checksum_hex,
		created_at   = created_at or now,
		updated_at   = now,
		meta         = deep_copy(meta or {}),
	}
end


local function locate_artifact_op(self, ref)
	return attempt_op(function ()
		for _, durability in ipairs({ 'transient', 'durable' }) do
			local dir = object_dir(self, ref, durability)
			local mp = final_meta_path(dir)
			local ok, rec_or_err = fibers.perform(read_json_op(mp))
			if ok then
				return true, {
					rec        = rec_or_err,
					durability = durability,
					dir        = dir,
					meta_path  = mp,
					blob_path  = data_path(dir),
				}
			end
			if not is_not_found_err(rec_or_err) then
				return false, rec_or_err
			end
		end
		return false, 'not_found'
	end)
end

----------------------------------------------------------------------
-- Artifact ready handle
----------------------------------------------------------------------

function Artifact:ref()
	return self._rec.artifact_ref
end

function Artifact:describe()
	return deep_copy(self._rec)
end

function Artifact:local_path()
	return self._blob_path
end

function Artifact:open_source_op()
	return attempt_op(function ()
		local stream, err = open_stream_now(self._blob_path, 'r')
		if not stream then
			return false, err
		end
		return true, blob_source.from_stream(stream)
	end)
end

----------------------------------------------------------------------
-- Sink session internals
----------------------------------------------------------------------

local function sink_terminal_err(phase)
	if phase == 'committed' then
		return 'committed'
	end
	if phase == 'aborted' then
		return 'aborted'
	end
	if phase == 'closed' then
		return 'closed'
	end
	if phase == 'sealed' then
		return 'sealed'
	end
	return 'closed'
end

local function make_sink_status_snapshot(session)
	return {
		artifact_ref = session.artifact_ref,
		state        = session.phase,
		terminal     = session.terminal == true,
		bytes        = session.bytes,
		checksum     = checksum.digest_hex_state(session.checksum_state),
		last_error   = session.last_error,
	}
end

local function sink_reply(ch, ok, value, err, terminal, phase)
	return ch:put_op({
		ok       = ok,
		value    = value,
		err      = err,
		terminal = terminal and true or false,
		phase    = phase,
	})
end

local function request_reply_op(ch, req, closed)
	return attempt_op(function ()
		local reply_ch = channel.new(1)
		req.reply_ch = reply_ch

		local which, _, close_reason = fibers.perform(fibers.named_choice{
			sent   = ch:put_op(req),
			closed = closed:next_op(),
		})

		if which == 'closed' then
			return false, tostring(close_reason or 'session_closed')
		end

		local which2, a, b = fibers.perform(fibers.named_choice{
			reply  = reply_ch:get_op(),
			closed = closed:next_op(),
		})

		if which2 == 'closed' then
			return false, tostring(b or 'session_closed')
		end

		local reply = a
		if not reply then
			return false, tostring(b or 'reply_missing')
		end

		if reply.ok then
			return true, reply.value
		end
		return false, tostring(reply.err or 'request_failed')
	end)
end

local function commit_sealed_op(session)
	return attempt_op(function ()
		local object_parent = root_for(session.store, session.durability)
		local object_path = object_dir(session.store, session.artifact_ref, session.durability)
		local meta = new_ready_record(
			session.artifact_ref,
			session.durability,
			session.bytes,
			checksum.digest_hex_state(session.checksum_state),
			session.meta,
			session.created_at
		)

		local ok_parent, perr = fibers.perform(mkdir_p_op(object_parent))
		if not ok_parent then
			return false, perr
		end

		local ok_meta, merr = fibers.perform(write_json_op(final_meta_path(session.staging_dir), meta))
		if not ok_meta then
			return false, merr
		end

		local ok_mv, mverr = fibers.perform(rename_path_op(session.staging_dir, object_path))
		if not ok_mv then
			return false, mverr
		end

		session.artifact = setmetatable({
			_store     = session.store,
			_rec       = meta,
			_blob_path = data_path(object_path),
		}, Artifact)
		session.phase = 'committed'
		session.terminal = true
		return true, session.artifact
	end)
end

local function session_append_op(session, chunk)
	if session.phase ~= 'open' then
		return op.always(false, sink_terminal_err(session.phase))
	end
	if type(chunk) ~= 'string' then
		return op.always(false, 'chunk must be a string')
	end
	if session.stream == nil then
		session.phase = 'aborted'
		session.terminal = true
		return op.always(false, 'closed')
	end

	return session.stream:write_op(chunk):wrap(function (n, err)
		if n == nil then
			session.phase = 'aborted'
			session.terminal = true
			session.last_error = tostring(err or 'write_failed')
			return false, session.last_error
		end
		checksum.update(session.checksum_state, chunk)
		session.bytes = session.bytes + #chunk
		return true, nil
	end)
end

local function session_abort_op(session, reason)
	if session.phase == 'committed' then
		return op.always(false, 'committed')
	end
	if session.phase == 'aborted' or session.phase == 'closed' then
		session.terminal = true
		return op.always(true, nil)
	end

	return attempt_op(function ()
		if session.stream ~= nil then
			local ok_term, term_err = terminate_stream(session.stream, reason or 'artifact sink aborted')
			session.stream = nil
			if ok_term ~= true then
				return false, term_err or 'artifact stream termination failed'
			end
		end

		local ok_rm, rm_err = fibers.perform(remove_artifact_dir_op(session.staging_dir))
		if not ok_rm then
			return false, rm_err
		end

		session.last_error = reason and tostring(reason) or session.last_error
		session.phase = 'aborted'
		session.terminal = true
		return true, nil
	end)
end

local function session_commit_op(session)
	if session.phase == 'committed' then
		return op.always(true, session.artifact)
	end
	if session.phase == 'aborted' or session.phase == 'closed' then
		return op.always(false, sink_terminal_err(session.phase))
	end

	return fibers.run_scope_op(function (scope)
		local committed = false
		scope:finally(function (_, status, primary)
			if session.stream ~= nil then
				resource.terminate_checked(session.stream, primary or status or 'artifact sink session closed', 'artifact sink session stream cleanup failed')
				session.stream = nil
			end
			if not committed and session.phase ~= 'committed' and session.phase ~= 'aborted' and session.phase ~= 'closed' then
				session.phase = 'sealed'
				if status ~= 'ok' then
					session.last_error = session.last_error or tostring(primary or status)
				end
			end
		end)

		if session.phase == 'open' or (session.phase == 'sealed' and session.stream ~= nil) then
			local okf, ferr = fibers.perform(session.stream:flush_op())
			if okf == nil then
				session.last_error = tostring(ferr or 'flush_failed')
				session.phase = 'sealed'
				return false, session.last_error
			end

			local okc, cerr = fibers.perform(session.stream:close_op())
			if okc == nil then
				session.last_error = tostring(cerr or 'close_failed')
				session.phase = 'sealed'
				return false, session.last_error
			end

			session.stream = nil
			session.phase = 'sealed'
		end

		local ok_commit, art_or_err = fibers.perform(commit_sealed_op(session))
		if not ok_commit then
			session.last_error = tostring(art_or_err)
			return false, session.last_error
		end

		committed = true
		return true, art_or_err
	end):wrap(unwrap_attempt)
end

local function handle_session_request_op(session, req)
	return op.guard(function ()
		if req.verb == 'append' then
			return session_append_op(session, req.chunk)
		elseif req.verb == 'commit' then
			return session_commit_op(session)
		elseif req.verb == 'abort' then
			return session_abort_op(session, req.reason)
		elseif req.verb == 'close' then
			if session.phase == 'committed' then
				session.terminal = true
				return op.always(true, nil)
			end
			return session_abort_op(session, req.reason or 'closed without commit')
		elseif req.verb == 'status' then
			return op.always(true, make_sink_status_snapshot(session))
		end
		return op.always(false, 'unsupported_sink_verb:' .. tostring(req.verb))
	end)
end

local function sink_session_main(session)
	local scope = assert(session.scope, 'artifact sink session missing scope')

	scope:finally(function (_, status, primary)
		if session.stream ~= nil then
			resource.terminate_checked(session.stream, primary or status or 'artifact sink closed', 'artifact sink stream cleanup failed')
			session.stream = nil
		end
		-- Staging directory removal may require process/filesystem work and must
		-- not be performed from a finaliser. Orderly abort/close paths remove it;
		-- cancellation may leave a staging directory for later scavenging.
		if session.phase ~= 'committed' then
			session.phase = 'aborted'
			session.terminal = true
			session.last_error = session.last_error or ((status ~= 'ok') and tostring(primary or status) or 'abandoned_staging_dir')
		end
		session.closed:close(session.phase)
	end)

	while true do
		local req = fibers.perform(session.cmd_ch:get_op())
		if not req then
			if session.phase ~= 'committed' then
				session.phase = 'aborted'
				session.terminal = true
			end
			return
		end

		local ok, value_or_err = fibers.perform(handle_session_request_op(session, req))
		local terminal = session.terminal == true
		local err = ok and nil or value_or_err
		local value = ok and value_or_err or nil
		local _ = fibers.perform(sink_reply(req.reply_ch, ok, value, err, terminal, session.phase))

		if terminal then
			return
		end
	end
end

----------------------------------------------------------------------
-- Artifact sink client handle
----------------------------------------------------------------------

local function sink_status_snapshot_from_handle(self)
	return {
		artifact_ref = self._artifact_ref,
		state        = self._phase,
		terminal     = self._terminal,
		last_error   = self._last_error,
	}
end

local function sink_request_op(self, verb, payload)
	return op.guard(function ()
		if self._terminal then
			if verb == 'status' then
				return op.always(true, sink_status_snapshot_from_handle(self))
			end
			if verb == 'commit' then
				if self._phase == 'committed' then
					return op.always(true, self._artifact)
				end
				return op.always(false, sink_terminal_err(self._phase))
			end
			if verb == 'close' then
				return op.always(true, nil)
			end
			if verb == 'abort' then
				if self._phase == 'aborted' or self._phase == 'closed' then
					return op.always(true, nil)
				end
				return op.always(false, sink_terminal_err(self._phase))
			end
			return op.always(false, sink_terminal_err(self._phase))
		end

		return request_reply_op(self._cmd_ch, payload, self._closed):wrap(function (ok, value_or_err)
			if ok then
				if verb == 'commit' and type(value_or_err) == 'table' and getmetatable(value_or_err) == Artifact then
					self._artifact = value_or_err
					self._phase = 'committed'
					self._terminal = true
				elseif verb == 'close' or verb == 'abort' then
					self._phase = 'aborted'
					self._terminal = true
				elseif verb == 'status' and type(value_or_err) == 'table' then
					self._phase = value_or_err.state or self._phase
					self._last_error = value_or_err.last_error or self._last_error
				end
				return true, value_or_err
			end

			if verb == 'commit' then
				self._phase = 'sealed'
				self._last_error = value_or_err
			elseif verb == 'abort' or verb == 'close' then
				self._phase = 'aborted'
				self._terminal = true
				self._last_error = value_or_err
			end
			return false, value_or_err
		end)
	end)
end

function ArtifactSink:append_op(chunk)
	return sink_request_op(self, 'append', {
		verb  = 'append',
		chunk = chunk,
	})
end

function ArtifactSink:write_chunk_op(chunk)
	return self:append_op(chunk)
end

function ArtifactSink:commit_op(opts)
	return sink_request_op(self, 'commit', {
		verb = 'commit',
		opts = opts,
	})
end

function ArtifactSink:abort_op(reason)
	return sink_request_op(self, 'abort', {
		verb   = 'abort',
		reason = reason,
	})
end

function ArtifactSink:close_op()
	return sink_request_op(self, 'close', {
		verb = 'close',
	})
end

function ArtifactSink:terminate(reason)
	if self._terminal == true then
		return true, nil
	end
	self._terminal = true
	if self._cmd_ch and type(self._cmd_ch.close) == 'function' then
		self._cmd_ch:close(reason or 'terminated')
	end
	return true, nil
end

function ArtifactSink:status_op()
	return sink_request_op(self, 'status', {
		verb = 'status',
	})
end

function ArtifactSink:status()
	return sink_status_snapshot_from_handle(self)
end

----------------------------------------------------------------------
-- Store API
----------------------------------------------------------------------

function Store:status_op()
	return op.always(true, {
		kind            = 'artifact_store',
		transient_root  = self.transient_root,
		durable_root    = self.durable_root,
		durable_enabled = self.durable_enabled,
		import_root     = self.import_root,
	})
end

function Store:create_sink_op(meta, opts)
	opts = opts or {}
	return op.guard(function ()
		local owner_scope = fibers.current_scope()
		if owner_scope == nil then
			return op.always(false, 'create_sink_op must be called from inside a fiber')
		end

		local durability, derr = choose_durability(self, opts.policy)
		if not durability then
			return op.always(false, derr)
		end

		return attempt_op(function (scope)
			local ref = tostring(uuid.new())
			local sroot = staging_root(self, durability)
			local sdir = staging_dir(self, ref, durability)
			local dpath = data_path(sdir)
			local pmeta = partial_meta_path(sdir)
			local created_at = os.time()
			local handed_off = false
			local stream = nil
			local session_scope = nil
			local serr = nil

			scope:finally(function (_, status, primary)
				if not handed_off then
					if stream ~= nil then
						resource.terminate_checked(stream, primary or status or 'sink admission failed', 'artifact sink admission stream cleanup failed')
					end
					if session_scope ~= nil then
						session_scope:cancel(tostring(primary or status or 'sink_admission_failed'))
					end
					-- Do not remove directories from a finaliser; this may need a subprocess.
					-- The abandoned staging directory is safe to scavenge later.
				end
			end)

			local ok_root, root_err = fibers.perform(mkdir_p_op(sroot))
			if not ok_root then
				return false, root_err
			end

			local ok_dir, dir_err = fibers.perform(mkdir_p_op(sdir))
			if not ok_dir then
				return false, dir_err
			end

			stream, dir_err = open_stream_now(dpath, 'w')
			if not stream then
				return false, dir_err
			end

			session_scope, serr = owner_scope:child()
			if not session_scope then
				return false, tostring(serr)
			end

			local session = {
				store             = self,
				scope             = session_scope,
				cmd_ch            = channel.new(8),
				closed            = pulse_mod.new(),
				artifact_ref      = ref,
				durability        = durability,
				staging_dir       = sdir,
				data_path         = dpath,
				partial_meta_path = pmeta,
				stream            = stream,
				phase             = 'open',
				terminal          = false,
				bytes             = 0,
				checksum_state    = checksum.new(),
				meta              = deep_copy(meta or {}),
				created_at        = created_at,
				artifact          = nil,
				last_error        = nil,
			}

			local ok_spawn, spawn_err = session_scope:spawn(function ()
				return sink_session_main(session)
			end)
			if not ok_spawn then
				session_scope:cancel(tostring(spawn_err or 'sink_session_spawn_failed'))
				return false, tostring(spawn_err)
			end

			handed_off = true
			stream = nil

			return true, setmetatable({
				_cmd_ch       = session.cmd_ch,
				_closed       = session.closed,
				_artifact_ref = ref,
				_phase        = 'open',
				_terminal     = false,
				_artifact     = nil,
				_last_error   = nil,
			}, ArtifactSink)
		end)
	end)
end

function Store:open_op(ref)
	return op.guard(function ()
		if not valid_ref(ref) then
			return op.always(false, 'invalid_artifact_ref')
		end
		return locate_artifact_op(self, ref):wrap(function (ok, located_or_err)
			if not ok then
				return false, located_or_err
			end
			local rec = located_or_err.rec
			if rec.state ~= 'ready' then
				return false, 'artifact_not_ready'
			end
			return true, setmetatable({
				_store     = self,
				_rec       = rec,
				_blob_path = located_or_err.blob_path,
			}, Artifact)
		end)
	end)
end

function Store:resolve_local_op(ref)
	return op.guard(function ()
		if not valid_ref(ref) then
			return op.always(false, 'invalid_artifact_ref')
		end
		return locate_artifact_op(self, ref):wrap(function (ok, located_or_err)
			if not ok then
				return false, located_or_err
			end
			local rec = located_or_err.rec
			if rec.state ~= 'ready' then
				return false, 'artifact_not_ready'
			end
			return true, {
				artifact_ref = rec.artifact_ref,
				durability   = rec.durability,
				path         = located_or_err.blob_path,
				meta         = deep_copy(rec.meta),
				size         = rec.size,
				checksum     = rec.checksum,
				state        = rec.state,
			}
		end)
	end)
end

local function import_source_attempt_op(self, source, meta, opts)
	opts = opts or {}
	return attempt_op(function (scope)
		local ok_sink, sink_or_err = fibers.perform(self:create_sink_op(meta, opts))
		if not ok_sink then
			return false, sink_or_err
		end
		local sink = sink_or_err

		scope:finally(function (_, status, primary)
			local reason = primary or status or 'artifact import closed'
			resource.terminate_checked(source, reason, 'artifact import source cleanup failed')
			resource.terminate_checked(sink, reason, 'artifact import sink cleanup failed')
		end)

		local st, rep, bytes_or_primary = fibers.perform(blob_source.copy_op(source, sink, {
			close_source = false,
			close_sink   = false,
		}))
		if st ~= 'ok' then
			return false, tostring(bytes_or_primary or rep)
		end

		local ok_commit, art_or_err = fibers.perform(sink:commit_op())
		if not ok_commit then
			return false, tostring(art_or_err)
		end

		return true, art_or_err
	end)
end

function Store:import_source_op(source, meta, opts)
	return op.guard(function ()
		if type(source) ~= 'table' or type(source.read_chunk_op) ~= 'function' then
			return op.always(false, 'invalid_source')
		end
		return import_source_attempt_op(self, source, meta, opts)
	end)
end

function Store:import_path_op(path, meta, opts)
	return op.guard(function ()
		if type(path) ~= 'string' or path == '' then
			return op.always(false, 'invalid_path')
		end

		local resolved = path
		if resolved:sub(1, 1) ~= '/' then
			if resolved:find('..', 1, true) or resolved:find('\\', 1, true) then
				return op.always(false, 'invalid_path')
			end
			resolved = join_path(self.import_root, resolved)
		end

		return attempt_op(function ()
			local stream, err = open_stream_now(resolved, 'r')
			if not stream then
				return false, err
			end
			local source = blob_source.from_stream(stream)
			return fibers.perform(import_source_attempt_op(self, source, meta, opts))
		end)
	end)
end

function Store:delete_op(ref)
	return op.guard(function ()
		if not valid_ref(ref) then
			return op.always(false, 'invalid_artifact_ref')
		end
		return attempt_op(function ()
			local ok, located_or_err = fibers.perform(locate_artifact_op(self, ref))
			if not ok then
				if located_or_err == 'not_found' then
					return true, nil
				end
				return false, located_or_err
			end
			return fibers.perform(remove_artifact_dir_op(located_or_err.dir))
		end)
	end)
end

----------------------------------------------------------------------
-- Constructor
----------------------------------------------------------------------

function M.new(opts, logger)
	opts = opts or {}

	local transient_root = opts.transient_root
		or os.getenv('DEVICECODE_ARTIFACT_TRANSIENT_ROOT')
		or '/run/devicecode/artifacts'

	local durable_root = opts.durable_root
		or os.getenv('DEVICECODE_ARTIFACT_DURABLE_ROOT')
		or '/data/devicecode/artifacts'

	local import_root = opts.import_root
		or os.getenv('DEVICECODE_IMPORT_ARTIFACT_ROOT')
		or os.getenv('DEVICECODE_ARTIFACT_DIR')
		or durable_root
		or transient_root

	local durable_enabled = opts.durable_enabled
	if durable_enabled == nil then
		local env = os.getenv('DEVICECODE_DURABLE_ARTIFACTS')
		durable_enabled = not (env == '0' or env == 'false' or env == 'FALSE')
	end

	return setmetatable({
		transient_root  = transient_root,
		durable_root    = durable_root,
		durable_enabled = durable_enabled and true or false,
		import_root     = import_root,
		logger          = logger,
	}, Store)
end

M.Store = Store
M.Artifact = Artifact
M.ArtifactSink = ArtifactSink

return M
