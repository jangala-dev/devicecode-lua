-- services/hal/backends/openwrt.lua
--
-- OpenWrt 21+ HAL backend using libuci-lua for structural writes, and
-- fibers.io.{file,exec} for I/O and process execution.

local common      = require 'services.hal.backends.openwrt.common'
local state_store = require 'services.hal.backends.openwrt.state_store'
local uci_apply   = require 'services.hal.backends.openwrt.uci_apply'
local links       = require 'services.hal.backends.openwrt.links'
local serial      = require 'services.hal.backends.openwrt.serial'

local M           = {}

local function mixin(dst, src)
	for k, v in pairs(src) do
		dst[k] = v
	end
end

function M.new(host)
	host = host or {}

	local state_dir = host.state_dir or os.getenv('DEVICECODE_STATE_DIR') or '/tmp/devicecode-state'
	do
		local ok, err = common.mkdir_p(state_dir)
		if not ok and host.log then
			host.log('warn', { what = 'state_dir_mkdir_failed', dir = state_dir, err = err })
		end
	end

	if host.uci_confdir then
		local ok, err = common.mkdir_p(host.uci_confdir)
		if not ok then error('uci_confdir mkdir failed: ' .. tostring(err), 2) end
	end
	if host.uci_savedir then
		local ok, err = common.mkdir_p(host.uci_savedir)
		if not ok then error('uci_savedir mkdir failed: ' .. tostring(err), 2) end
	end

	do
		local ok, err = common.ensure_pkg_file(host, 'network');  if not ok then error(err, 2) end
		ok, err = common.ensure_pkg_file(host, 'dhcp');           if not ok then error(err, 2) end
		ok, err = common.ensure_pkg_file(host, 'firewall');       if not ok then error(err, 2) end
		ok, err = common.ensure_pkg_file(host, 'mwan3');          if not ok then error(err, 2) end
	end

	local uci = require('uci')
	local cur = uci.cursor(host.uci_confdir, host.uci_savedir)

	local self = {
		_host      = host,
		_state_dir = state_dir,
		_cur       = cur,
		_serial_streams = {}, -- ref -> { stream = Stream, opened_at = number }
	}

	function self:name() return 'openwrt' end

	function self:capabilities()
		return {
			state_store             = true,
			open_serial_stream      = true,
			apply_net               = true,
			apply_wifi              = false,
			list_links              = true,
			probe_links             = true,
			read_link_counters      = true,
			apply_link_shaping_live = false,
			apply_multipath_live    = false,
			persist_multipath_state = true,
		}
	end

	mixin(self, state_store)
	mixin(self, uci_apply)
	mixin(self, links)
	mixin(self, serial)

	return self
end

return M
