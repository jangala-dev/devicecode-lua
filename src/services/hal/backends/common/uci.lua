-- services/hal/backends/common/uci.lua
--
-- Compatibility UCI surface used by the current Wi-Fi backend.
--
-- The previous implementation kept a module-level commit queue and spawned its
-- reactor into the root scope.  This wrapper keeps the colleague-facing surface
-- stable, but delegates to the scoped OpenWrt UCI manager introduced for the
-- new HAL work.
--
-- New strict code should use services.hal.backends.openwrt.uci_manager
-- directly.  This module exists for non-Op compatibility callers.

local compat = require 'services.hal.backends.openwrt.uci_singleton_compat'

local M = {}

local function with_default_local_manager(opts)
	opts = opts or {}
	if opts.allow_local_manager == nil then
		opts.allow_local_manager = true
	end
	return opts
end

function M.bind_manager(mgr)
	return compat.bind_manager(mgr)
end

function M.clear_bound_manager()
	return compat.clear_bound_manager()
end

function M.manager_owner()
	return compat.manager_owner()
end

function M.ensure_started(opts)
	return compat.ensure_started(with_default_local_manager(opts))
end

function M.new_session(opts)
	return compat.new_session(with_default_local_manager(opts))
end

function M.get_value(config, section, option)
	return compat.get_value(config, section, option)
end

function M.section_exists(config, section)
	return compat.section_exists(config, section)
end

function M.get_sections(config, stype)
	return compat.get_sections(config, stype)
end

return M
