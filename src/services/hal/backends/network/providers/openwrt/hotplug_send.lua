#!/usr/bin/env lua
-- Forward one OpenWrt hotplug/MWAN3 event to the devicecode network observer.
-- Intended for tiny scripts in /etc/hotplug.d/* and /etc/mwan3.user.

local fibers = require 'fibers'
local client = require 'services.hal.backends.network.providers.openwrt.hotplug_client'

local ok, err
fibers.run(function ()
	ok, err = client.main(arg)
end)

if ok ~= true then
	-- Hotplug paths must not block or retry.  Exit non-zero for diagnostics only.
	io.stderr:write('devicecode hotplug forward failed: ', tostring(err), '\n')
	os.exit(1)
end
os.exit(0)
