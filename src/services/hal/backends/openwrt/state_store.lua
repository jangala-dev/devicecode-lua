-- services/hal/backends/openwrt/state_store.lua
--
-- State store helpers for the OpenWrt HAL backend.

local file   = require 'fibers.io.file'
local common = require 'services.hal.backends.openwrt.common'

local M      = {}

function M.dump(self, req, _msg)
	req = req or {}

	local packages = req.packages
	if type(packages) ~= 'table' or #packages == 0 then
		packages = { 'network', 'dhcp', 'firewall', 'mwan3' }
	end

	local out = {}
	for i = 1, #packages do
		local pkg = tostring(packages[i])
		local ok, txt, err = common.cmd_capture('uci', 'show', pkg)
		out[pkg] = {
			ok   = (ok == true),
			text = ok and txt or nil,
			err  = (ok ~= true) and tostring(err) or nil,
		}
	end

	return {
		ok        = true,
		backend   = 'openwrt',
		state_dir = self._state_dir,
		packages  = out,
	}
end

function M.read_state(self, req, _msg)
	local ns, key = req and req.ns, req and req.key
	if type(ns) ~= 'string' or ns == '' or type(key) ~= 'string' or key == '' then
		return { ok = false, err = 'ns and key must be non-empty strings' }
	end

	local path = common.state_path(self._state_dir, ns, key)
	if not common.file_exists(path) then
		return { ok = true, found = false }
	end

	local s, err = file.open(path, 'r')
	if not s then
		return { ok = false, err = 'open failed: ' .. tostring(err) }
	end

	local data, rerr = s:read_all()
	s:close()
	if rerr ~= nil then
		return { ok = false, err = tostring(rerr) }
	end
	return { ok = true, found = true, data = data or '' }
end

function M.write_state(self, req, _msg)
	local ns, key, data = req and req.ns, req and req.key, req and req.data
	if type(ns) ~= 'string' or ns == '' or type(key) ~= 'string' or key == '' then
		return { ok = false, err = 'ns and key must be non-empty strings' }
	end
	if type(data) ~= 'string' then
		return { ok = false, err = 'data must be a string' }
	end

	local dir = common.ns_dir(self._state_dir, ns)
	local ok, err = common.mkdir_p(dir)
	if not ok then
		return { ok = false, err = 'failed to create state dir: ' .. tostring(err) }
	end

	local tmp, terr = file.tmpfile('rw-r--r--', dir)
	if not tmp then
		return { ok = false, err = 'tmpfile failed: ' .. tostring(terr) }
	end

	local w1, werr = tmp:write(data)
	if not w1 then
		tmp:close()
		return { ok = false, err = 'write failed: ' .. tostring(werr) }
	end
	tmp:flush()

	local final = common.state_path(self._state_dir, ns, key)
	local rok, rerr = tmp:rename(final)
	if not rok then
		tmp:close()
		return { ok = false, err = 'rename failed: ' .. tostring(rerr) }
	end

	local cok, cerr = tmp:close()
	if not cok then
		return { ok = false, err = 'close failed: ' .. tostring(cerr) }
	end

	return { ok = true }
end

return M
