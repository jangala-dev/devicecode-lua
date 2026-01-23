-- services/hal.lua
--
-- HAL service: owns all OS/filesystem interactions for persisted state.
--
-- Env:
--   DEVICECODE_STATE_DIR           required
--   DEVICECODE_STATE_NS_ROOT       optional (default: "state")
--
-- Announce (retained):
--   {'svc', <name>, 'announce'} payload { role="hal", rpc_root={...}, ts=... }
--
-- RPC endpoints (lane B, under rpc_root):
--   <rpc_root + {'read_state'}>  payload { ns=string, key=string } -> { ok=true, found=bool, data=string? } | { ok=false, err=string }
--   <rpc_root + {'write_state'}> payload { ns=string, key=string, data=string } -> { ok=true } | { ok=false, err=string }
--   <rpc_root + {'ping'}>        payload {} -> { ok=true, now=number }

local op      = require 'fibers.op'
local runtime = require 'fibers.runtime'
local perform = require 'fibers.performer'.perform

local mailbox = require 'fibers.mailbox' -- used only for type availability (optional)
local M = {}

local function t(...)
	return { ... }
end

local function now()
	return runtime.now()
end

local function require_env(name)
	local v = os.getenv(name)
	if not v or v == '' then
		error(('missing required environment variable %s'):format(name), 2)
	end
	return v
end

local function shell_quote(s)
	-- Minimal single-quote shell escaping.
	s = tostring(s)
	return "'" .. s:gsub("'", [['"'"']]) .. "'"
end

local function valid_name(s)
	return type(s) == 'string' and s:match('^[A-Za-z0-9][A-Za-z0-9._-]*$') ~= nil
end

local function publish_status(conn, name, state, extra)
	local payload = { state = state, ts = now() }
	if type(extra) == 'table' then
		for k, v in pairs(extra) do payload[k] = v end
	end
	conn:retain(t('svc', name, 'status'), payload)
end

-------------------------------------------------------------------------------
-- FS backend
-------------------------------------------------------------------------------

local function join_path(a, b, c, d)
	if d ~= nil then
		return a .. '/' .. b .. '/' .. c .. '/' .. d
	end
	return a .. '/' .. b .. '/' .. c
end

local function mkdir_p(path)
	-- Busybox-compatible and acceptable within HAL.
	local cmd = 'mkdir -p ' .. shell_quote(path)
	local ok = os.execute(cmd)
	return ok == true or ok == 0
end

local function read_file(p)
	local f, err = io.open(p, 'rb')
	if not f then return nil, err end
	local data = f:read('*a')
	f:close()
	return data or '', nil
end

local function write_atomic(p, data)
	local tmp = p .. '.tmp.' .. tostring(math.random(1, 1e9))
	local f, err = io.open(tmp, 'wb')
	if not f then return nil, err end

	local ok_w, werr = pcall(function () f:write(data) end)
	f:close()

	if not ok_w then
		pcall(function () os.remove(tmp) end)
		return nil, tostring(werr)
	end

	local ok, rerr = os.rename(tmp, p)
	if not ok then
		pcall(function () os.remove(tmp) end)
		return nil, tostring(rerr)
	end
	return true, nil
end

function M.new_fs_backend(state_dir, opts)
	opts = opts or {}
	local ns_root = opts.ns_root or 'state'
	local ext     = opts.ext or '.json'

	local function path_for(ns, key)
		if not valid_name(ns) then return nil, 'invalid ns' end
		if not valid_name(key) then return nil, 'invalid key' end
		local dir = join_path(state_dir, ns_root, ns)
		local p   = join_path(state_dir, ns_root, ns, key .. ext)
		return dir, p
	end

	return {
		read_state = function (_, ns, key)
			local _, p = path_for(ns, key)
			local data, err = read_file(p)
			if not data then
				return nil, 'not_found:' .. tostring(err)
			end
			return data, nil
		end,

		write_state = function (_, ns, key, data)
			local dir, p = path_for(ns, key)
			if not mkdir_p(dir) then
				return nil, 'failed to create state directory'
			end
			local ok, err = write_atomic(p, data)
			if not ok then return nil, err end
			return true, nil
		end,
	}
end

-- In-memory backend for unit tests.
function M.new_mem_backend(initial)
	local store = {}
	if type(initial) == 'table' then
		for k, v in pairs(initial) do store[k] = v end
	end
	local function k(ns, key) return tostring(ns) .. '/' .. tostring(key) end

	return {
		read_state = function (_, ns, key)
			local v = store[k(ns, key)]
			if v == nil then return nil, 'not_found' end
			return v, nil
		end,
		write_state = function (_, ns, key, data)
			store[k(ns, key)] = data
			return true, nil
		end,
		_store = store,
	}
end

-------------------------------------------------------------------------------
-- Service
-------------------------------------------------------------------------------

function M.start(conn, opts)
	opts = opts or {}
	local name = opts.name or 'hal'

	local state_dir = require_env('DEVICECODE_STATE_DIR')
	local ns_root   = os.getenv('DEVICECODE_STATE_NS_ROOT') or 'state'

	local backend = opts.backend or M.new_fs_backend(state_dir, { ns_root = ns_root })

	local rpc_root = t('svc', name, 'rpc')

	conn:retain(t('svc', name, 'announce'), {
		role     = 'hal',
		rpc_root = rpc_root,
		ts       = now(),
	})

	publish_status(conn, name, 'starting')

	local ep_read  = conn:bind({ rpc_root[1], rpc_root[2], rpc_root[3], 'read_state' })
	local ep_write = conn:bind({ rpc_root[1], rpc_root[2], rpc_root[3], 'write_state' })
	local ep_ping  = conn:bind({ rpc_root[1], rpc_root[2], rpc_root[3], 'ping' })

	publish_status(conn, name, 'running')

	while true do
		local which, msg, err = perform(op.named_choice({
			read  = ep_read:recv_op(),
			write = ep_write:recv_op(),
			ping  = ep_ping:recv_op(),
		}))

		if not msg then
			publish_status(conn, name, 'stopped', { reason = err })
			return
		end

		local function reply(payload)
			if msg.reply_to ~= nil then
				conn:publish_one(msg.reply_to, payload, { id = msg.id })
			end
		end

		if which == 'ping' then
			reply({ ok = true, now = now() })

		elseif which == 'read' then
			local p = msg.payload or {}
			local ns, key = p.ns, p.key
			if not valid_name(ns) or not valid_name(key) then
				reply({ ok = false, err = 'invalid ns/key' })
			else
				local data, rerr = backend:read_state(ns, key)
				if data ~= nil then
					reply({ ok = true, found = true, data = data })
				else
					reply({ ok = true, found = false, err = rerr })
				end
			end

		elseif which == 'write' then
			local p = msg.payload or {}
			local ns, key, data = p.ns, p.key, p.data
			if not valid_name(ns) or not valid_name(key) or type(data) ~= 'string' then
				reply({ ok = false, err = 'invalid ns/key/data' })
			else
				local ok_w, werr = backend:write_state(ns, key, data)
				if ok_w then
					reply({ ok = true })
				else
					reply({ ok = false, err = tostring(werr) })
				end
			end
		end
	end
end

return M
