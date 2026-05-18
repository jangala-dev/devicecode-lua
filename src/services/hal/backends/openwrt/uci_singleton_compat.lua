-- services/hal/backends/openwrt/uci_singleton_compat.lua
-- Compatibility surface for old non-Op UCI session callers.
--
-- New code should use the scoped UCI manager directly.  This wrapper preserves
-- the existing wifi-facing surface while avoiding a root-scope singleton.
--
-- Ownership rule:
--   * production code should bind a manager owned by the OpenWrt HAL backend;
--   * unbound current-scope startup is available only when explicitly requested
--     through ensure_started({ allow_local_manager = true }).

local fibers = require 'fibers'
local uci_manager = require 'services.hal.backends.openwrt.uci_manager'

local M = {}

local manager = nil
local manager_owned = 'unbound'

local function ensure_bound_or_local(opts)
	if manager then return manager, nil end
	opts = opts or {}
	if opts.allow_local_manager ~= true then
		return nil, 'UCI compatibility manager is not bound; OpenWrt HAL must bind_manager(manager)'
	end
	local mgr, err = uci_manager.new(opts)
	if not mgr then return nil, err end
	local scope = fibers.current_scope()
	if not scope then return nil, 'no current scope for local UCI compatibility manager' end
	local ok, serr = mgr:start(scope)
	if ok ~= true then return nil, serr end
	manager = mgr
	manager_owned = 'local_current_scope'
	return manager, nil
end

function M.bind_manager(mgr)
	if type(mgr) ~= 'table' or type(mgr.new_session) ~= 'function' then
		return nil, 'invalid UCI manager'
	end
	manager = mgr
	manager_owned = 'bound'
	return true, nil
end

function M.clear_bound_manager()
	manager = nil
	manager_owned = 'unbound'
	return true, nil
end

function M.ensure_started(opts)
	local _, err = ensure_bound_or_local(opts)
	return err == nil, err
end

function M.manager_owner()
	return manager_owned
end

function M.new_session(opts)
	local mgr, err = ensure_bound_or_local(opts)
	if not mgr then error(err or 'uci compatibility manager unavailable', 2) end
	return mgr:new_session()
end

local function read_cursor()
	local ok, uci_or_err = pcall(require, 'uci')
	if not ok or not uci_or_err or type(uci_or_err.cursor) ~= 'function' then return nil end
	return uci_or_err.cursor()
end

function M.get_value(config, section, option)
	local c = read_cursor()
	if not c then return nil end
	return c:get(config, section, option)
end

function M.section_exists(config, section)
	local c = read_cursor()
	if not c then return false end
	return c:get(config, section) ~= nil
end

function M.get_sections(config, stype)
	local c = read_cursor()
	local names = {}
	if not c then return names end
	c:foreach(config, stype, function (s)
		if s['.name'] then names[#names + 1] = s['.name'] end
	end)
	return names
end

return M
