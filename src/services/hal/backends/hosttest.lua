-- services/hal/backends/hosttest.lua
--
-- Host-test HAL backend:
--   * state store (read_state/write_state)
--   * apply_net/apply_wifi record the last applied desired state
--   * dump provides introspection for tests

local M = {}

local function key(ns, k)
	return tostring(ns) .. '\0' .. tostring(k)
end

local function read_file(path)
	local f = io.open(path, 'rb')
	if not f then return nil, 'open failed' end
	local s = f:read('*a')
	f:close()
	return s, nil
end

local function default_seed_path()
	return './services/hal/backends/hosttest/services.json'
end

local function shallow_copy(t)
	local out = {}
	for k, v in pairs(t) do out[k] = v end
	return out
end

function M.new(host)
	host                  = host or {}
	local log             = host.log or function() end
	local event           = host.event or function() end

	-- Simple in-memory blob store.
	local st              = {}

	-- Apply record.
	local applied         = {
		net     = nil,
		wifi    = nil,
		history = {}, -- append-only; bounded by caller if desired
	}

	-- Seed config/services.
	local seed_path       = os.getenv('DEVICECODE_HOSTTEST_SERVICES_JSON') or default_seed_path()
	local seed_json, rerr = read_file(seed_path)
	if not seed_json or seed_json == '' then
		log('warn', { what = 'seed_config_missing', path = seed_path, err = tostring(rerr) })
		seed_json = [[
{
  "monitor": {
    "rev": 1,
    "data": {
      "schema": "devicecode.pre_monitor/1.0",
      "pretty": true
    }
  },
  "net": {
    "rev": 1,
    "data": {
      "schema": "devicecode.pre_net/1.0"
    }
  },
  "wifi": {
    "rev": 1,
    "data": {
      "schema": "devicecode.pre_wifi/1.0",
      "country": "GB"
    }
  }
}
]]
	else
		log('info', { what = 'seed_config_loaded', path = seed_path, bytes = #seed_json })
	end
	st[key('config', 'services')] = seed_json

	local self = {}

	function self:name()
		return 'hosttest'
	end

	function self:capabilities()
		return {
			state_store = true,
			apply_net   = true,
			apply_wifi  = true,
		}
	end

	function self:read_state(req, _)
		local ns = req and req.ns
		local k  = req and req.key
		if type(ns) ~= 'string' or type(k) ~= 'string' then
			return { ok = false, err = 'ns and key must be strings' }
		end

		local v = st[key(ns, k)]
		if v == nil then
			return { ok = true, found = false }
		end
		return { ok = true, found = true, data = v }
	end

	function self:write_state(req, _)
		local ns   = req and req.ns
		local k    = req and req.key
		local data = req and req.data
		if type(ns) ~= 'string' or type(k) ~= 'string' then
			return { ok = false, err = 'ns and key must be strings' }
		end
		if type(data) ~= 'string' then
			return { ok = false, err = 'data must be a string' }
		end

		st[key(ns, k)] = data
		return { ok = true }
	end

	-- desired is the (already compiled) bundle from net/wifi services.
	function self:apply_net(desired, msg)
		applied.net = desired
		applied.history[#applied.history + 1] = {
			domain = 'net',
			at     = host.now and host.now() or 0,
			id     = msg and msg.id or nil,
		}
		return { ok = true, applied = true, changed = true }
	end

	function self:apply_wifi(desired, msg)
		applied.wifi = desired
		applied.history[#applied.history + 1] = {
			domain = 'wifi',
			at     = host.now and host.now() or 0,
			id     = msg and msg.id or nil,
		}
		return { ok = true, applied = true, changed = true }
	end

	function self:dump(req, _)
		local what = req and req.what or 'all'
		local out = { ok = true, backend = 'hosttest' }

		if what == 'state' or what == 'all' then
			local s = {}
			for kk, vv in pairs(st) do s[kk] = vv end
			out.state = s
		end
		if what == 'applied' or what == 'all' then
			out.applied = shallow_copy(applied)
		end
		return out
	end

	return self
end

return M
