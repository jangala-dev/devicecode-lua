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
	uploads = {
		enabled = true,
		max_bytes = 64 * 1024 * 1024,
		require_auth = false,
	},
	sessions = {
		prune_interval = 60,
	},
}

local ROOT_KEYS = {
	schema = true,
	enabled = true,
	http = true,
	static = true,
	sse = true,
	uploads = true,
	sessions = true,
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
local UPLOAD_KEYS = { enabled = true, max_bytes = true, require_auth = true }
local SESSION_KEYS = { prune_interval = true }

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

local function normalise_uploads(raw)
	local err
	raw, err = table_or_empty(raw, 'uploads')
	if not raw then return nil, err end
	local ok
	ok, err = allowed(raw, UPLOAD_KEYS, 'uploads')
	if not ok then return nil, err end
	local out = copy_plain(DEFAULTS.uploads)
	local v
	v, err = bool_or_nil(raw.enabled, 'uploads.enabled')
	if err then return nil, err end
	if v ~= nil then out.enabled = v end
	v, err = non_negative_int_or_nil(raw.max_bytes, 'uploads.max_bytes')
	if err then return nil, err end
	if v ~= nil then out.max_bytes = v end
	v, err = bool_or_nil(raw.require_auth, 'uploads.require_auth')
	if err then return nil, err end
	if v ~= nil then out.require_auth = v end
	return out, nil
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
	local uploads; uploads, err = normalise_uploads(raw.uploads); if not uploads then return nil, err end
	local sessions; sessions, err = normalise_sessions(raw.sessions); if not sessions then return nil, err end

	return {
		schema = M.SCHEMA,
		enabled = enabled ~= false,
		http = http,
		static = static,
		sse = sse,
		uploads = uploads,
		sessions = sessions,
	}, nil
end


M.DEFAULTS = DEFAULTS
return M
