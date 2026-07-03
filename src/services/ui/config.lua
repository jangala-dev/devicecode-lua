-- services/ui/config.lua
--
-- Pure UI configuration normaliser.

local M = {}

M.SCHEMA = 'devicecode.config/ui/1'

local DEFAULTS = {
	enabled = true,
	http = {
		enabled = true,
		cap_id = 'main',
		host = '0.0.0.0',
		port = 8080,
	},
	static = {
		root = 'www',
		index = 'index.html',
		chunk_size = 16384,
	},
	sse = {
		enabled = true,
		queue_len = 32,
		replay = true,
	},
	sessions = {
		prune_interval = 60,
	},
	observability = {
		status_interval_s = 30,
		coalesce_status_s = 0.05,
	},
}

local ROOT_KEYS = {
	schema = true,
	enabled = true,
	http = true,
	static = true,
	sse = true,
	updates = true,
	sessions = true,
	observability = true,
}

local HTTP_KEYS = {
	enabled = true,
	cap_id = true,
	host = true,
	port = true,
	path = true,
	tls = true,
	max_accept_queue = true,
	max_active_requests = true,
}

local STATIC_KEYS = { root = true, index = true, chunk_size = true }
local SSE_KEYS = { enabled = true, queue_len = true, max_replay = true, replay = true, pattern = true }
local UPDATE_KEYS = { upload = true, commit = true }
local UPDATE_UPLOAD_KEYS = { enabled = true, max_bytes = true, require_auth = true, component = true, create_job = true, start_job = true }
local UPDATE_COMMIT_KEYS = { require_auth = true }
local SESSION_KEYS = { prune_interval = true }
local OBSERVABILITY_KEYS = { status_interval_s = true, coalesce_status_s = true }

local function fail(msg) return nil, msg end

local function copy_plain(v)
	if type(v) ~= 'table' then return v end
	local out = {}
	for k, subv in pairs(v) do out[k] = copy_plain(subv) end
	return out
end

local function allowed(t, keys, path)
	for k in pairs(t or {}) do
		if not keys[k] then return nil, path .. ' has unknown field: ' .. tostring(k) end
	end
	return true, nil
end

local function table_or_empty(v, path)
	if v == nil then return {}, nil end
	if type(v) ~= 'table' then return nil, path .. ' must be a table' end
	return v, nil
end

local function table_required(v, path)
	if type(v) ~= 'table' then return nil, path .. ' must be a table' end
	return v, nil
end

local function bool_or_nil(v, path)
	if v == nil then return nil, nil end
	if type(v) ~= 'boolean' then return nil, path .. ' must be boolean' end
	return v, nil
end

local function non_empty_string_or_nil(v, path)
	if v == nil then return nil, nil end
	if type(v) ~= 'string' or v == '' then return nil, path .. ' must be a non-empty string' end
	return v, nil
end

local function non_negative_int_or_nil(v, path)
	if v == nil then return nil, nil end
	if type(v) ~= 'number' or v < 0 or v % 1 ~= 0 then return nil, path .. ' must be a non-negative integer' end
	return v, nil
end

local function positive_number_or_false_or_nil(v, path)
	if v == nil then return nil, nil end
	if v == false then return false, nil end
	if type(v) ~= 'number' or v <= 0 then return nil, path .. ' must be > 0 or false' end
	return v, nil
end

local function normalise_http(raw)
	local err
	raw, err = table_or_empty(raw, 'http')
	if not raw then return nil, err end
	local ok
	ok, err = allowed(raw, HTTP_KEYS, 'http')
	if not ok then return nil, err end

	local out = copy_plain(DEFAULTS.http)
	local v

	v, err = bool_or_nil(raw.enabled, 'http.enabled')
	if err then return nil, err end
	if v ~= nil then out.enabled = v end

	v, err = non_empty_string_or_nil(raw.cap_id, 'http.cap_id')
	if err then return nil, err end
	if v ~= nil then out.cap_id = v end

	v, err = non_empty_string_or_nil(raw.host, 'http.host')
	if err then return nil, err end
	if v ~= nil then out.host = v end

	v, err = non_negative_int_or_nil(raw.port, 'http.port')
	if err then return nil, err end
	if v ~= nil then out.port = v end

	v, err = non_empty_string_or_nil(raw.path, 'http.path')
	if err then return nil, err end
	if v ~= nil then out.path = v end

	v, err = bool_or_nil(raw.tls, 'http.tls')
	if err then return nil, err end
	if v ~= nil then out.tls = v end

	v, err = non_negative_int_or_nil(raw.max_accept_queue, 'http.max_accept_queue')
	if err then return nil, err end
	if v ~= nil then out.max_accept_queue = v end

	v, err = non_negative_int_or_nil(raw.max_active_requests, 'http.max_active_requests')
	if err then return nil, err end
	if v ~= nil then out.max_active_requests = v end

	return out, nil
end

local function normalise_static(raw)
	local err
	raw, err = table_or_empty(raw, 'static')
	if not raw then return nil, err end
	local ok
	ok, err = allowed(raw, STATIC_KEYS, 'static')
	if not ok then return nil, err end

	local out = copy_plain(DEFAULTS.static)
	local v
	v, err = non_empty_string_or_nil(raw.root, 'static.root')
	if err then return nil, err end
	if v ~= nil then out.root = v end
	v, err = non_empty_string_or_nil(raw.index, 'static.index')
	if err then return nil, err end
	if v ~= nil then out.index = v end
	v, err = non_negative_int_or_nil(raw.chunk_size, 'static.chunk_size')
	if err then return nil, err end
	if v ~= nil then out.chunk_size = v end
	return out, nil
end

local function normalise_sse(raw)
	local err
	raw, err = table_or_empty(raw, 'sse')
	if not raw then return nil, err end
	local ok
	ok, err = allowed(raw, SSE_KEYS, 'sse')
	if not ok then return nil, err end

	local out = copy_plain(DEFAULTS.sse)
	local v
	v, err = bool_or_nil(raw.enabled, 'sse.enabled')
	if err then return nil, err end
	if v ~= nil then out.enabled = v end
	v, err = non_negative_int_or_nil(raw.queue_len, 'sse.queue_len')
	if err then return nil, err end
	if v ~= nil then out.queue_len = v end
	v, err = non_negative_int_or_nil(raw.max_replay, 'sse.max_replay')
	if err then return nil, err end
	if v ~= nil then out.max_replay = v end
	v, err = bool_or_nil(raw.replay, 'sse.replay')
	if err then return nil, err end
	if v ~= nil then out.replay = v end
	if raw.pattern ~= nil then
		if type(raw.pattern) ~= 'table' then return nil, 'sse.pattern must be a table' end
		out.pattern = copy_plain(raw.pattern)
	end
	return out, nil
end

local function normalise_update_upload(raw)
	local err
	raw, err = table_required(raw, 'updates.upload')
	if not raw then return nil, err end
	local ok
	ok, err = allowed(raw, UPDATE_UPLOAD_KEYS, 'updates.upload')
	if not ok then return nil, err end
	local out = {}
	local v
	v, err = bool_or_nil(raw.enabled, 'updates.upload.enabled')
	if err then return nil, err end
	if v == nil then return nil, 'updates.upload.enabled is required' end
	out.enabled = v
	v, err = non_negative_int_or_nil(raw.max_bytes, 'updates.upload.max_bytes')
	if err then return nil, err end
	if v == nil then return nil, 'updates.upload.max_bytes is required' end
	out.max_bytes = v
	v, err = bool_or_nil(raw.require_auth, 'updates.upload.require_auth')
	if err then return nil, err end
	if v == nil then return nil, 'updates.upload.require_auth is required' end
	out.require_auth = v
	v, err = non_empty_string_or_nil(raw.component, 'updates.upload.component')
	if err then return nil, err end
	if v == nil then return nil, 'updates.upload.component is required' end
	out.component = v
	v, err = bool_or_nil(raw.create_job, 'updates.upload.create_job')
	if err then return nil, err end
	if v == nil then return nil, 'updates.upload.create_job is required' end
	out.create_job = v
	v, err = bool_or_nil(raw.start_job, 'updates.upload.start_job')
	if err then return nil, err end
	if v == nil then return nil, 'updates.upload.start_job is required' end
	out.start_job = v
	if out.start_job == true and out.create_job ~= true then
		return nil, 'updates.upload.start_job requires updates.upload.create_job'
	end
	return out, nil
end

local function normalise_update_commit(raw)
	local err
	raw, err = table_required(raw, 'updates.commit')
	if not raw then return nil, err end
	local ok
	ok, err = allowed(raw, UPDATE_COMMIT_KEYS, 'updates.commit')
	if not ok then return nil, err end
	local out = {}
	local v
	v, err = bool_or_nil(raw.require_auth, 'updates.commit.require_auth')
	if err then return nil, err end
	if v == nil then return nil, 'updates.commit.require_auth is required' end
	out.require_auth = v
	return out, nil
end

local function normalise_updates(raw)
	local err
	raw, err = table_required(raw, 'updates')
	if not raw then return nil, err end
	local ok
	ok, err = allowed(raw, UPDATE_KEYS, 'updates')
	if not ok then return nil, err end
	local upload; upload, err = normalise_update_upload(raw.upload); if not upload then return nil, err end
	local commit; commit, err = normalise_update_commit(raw.commit); if not commit then return nil, err end
	return { upload = upload, commit = commit }, nil
end

local function normalise_sessions(raw)
	local err
	raw, err = table_or_empty(raw, 'sessions')
	if not raw then return nil, err end
	local ok
	ok, err = allowed(raw, SESSION_KEYS, 'sessions')
	if not ok then return nil, err end
	local out = copy_plain(DEFAULTS.sessions)
	local v
	v, err = positive_number_or_false_or_nil(raw.prune_interval, 'sessions.prune_interval')
	if err then return nil, err end
	if v ~= nil then out.prune_interval = v end
	return out, nil
end


local function normalise_observability(raw)
	local err
	raw, err = table_or_empty(raw, 'observability')
	if not raw then return nil, err end
	local ok
	ok, err = allowed(raw, OBSERVABILITY_KEYS, 'observability')
	if not ok then return nil, err end
	local out = copy_plain(DEFAULTS.observability)
	local v
	v, err = positive_number_or_false_or_nil(raw.status_interval_s, 'observability.status_interval_s')
	if err then return nil, err end
	if v ~= nil then out.status_interval_s = v end
	v, err = positive_number_or_false_or_nil(raw.coalesce_status_s, 'observability.coalesce_status_s')
	if err then return nil, err end
	if v ~= nil then out.coalesce_status_s = v end
	return out, nil
end

function M.normalise(raw)
	if raw == nil then raw = {} end
	if type(raw) ~= 'table' then return fail('ui config must be a table') end
	local ok, err = allowed(raw, ROOT_KEYS, 'ui config')
	if not ok then return nil, err end
	if raw.schema ~= nil and raw.schema ~= M.SCHEMA then
		return nil, 'ui config schema must be ' .. M.SCHEMA
	end

	local enabled
	enabled, err = bool_or_nil(raw.enabled, 'enabled')
	if err then return nil, err end

	local http; http, err = normalise_http(raw.http); if not http then return nil, err end
	local static; static, err = normalise_static(raw.static); if not static then return nil, err end
	local sse; sse, err = normalise_sse(raw.sse); if not sse then return nil, err end
	local updates; updates, err = normalise_updates(raw.updates); if not updates then return nil, err end
	local sessions; sessions, err = normalise_sessions(raw.sessions); if not sessions then return nil, err end
	local observability; observability, err = normalise_observability(raw.observability); if not observability then return nil, err end

	return {
		schema = M.SCHEMA,
		enabled = enabled ~= false,
		http = http,
		static = static,
		sse = sse,
		updates = updates,
		sessions = sessions,
		observability = observability,
	}, nil
end


M.DEFAULTS = DEFAULTS
return M
