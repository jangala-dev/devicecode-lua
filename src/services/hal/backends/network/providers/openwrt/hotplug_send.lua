#!/usr/bin/env lua
-- Forward one OpenWrt hotplug/MWAN3 event to the devicecode network observer.
-- Intended for tiny scripts in /etc/hotplug.d/* and /etc/mwan3.user.

local function dirname(path)
	path = tostring(path or '')
	local dir = path:match('^(.*)/[^/]*$')
	if dir == nil or dir == '' then return '.' end
	return dir
end


local function prepend_package_paths(paths, cpaths)
	if #paths > 0 then package.path = table.concat(paths, ';') .. ';' .. package.path end
	if #cpaths > 0 then package.cpath = table.concat(cpaths, ';') .. ';' .. package.cpath end
end

local function split_sender_path(path)
	path = tostring(path or '')
	local prefix = path:match('^(.*)/src/services/hal/backends/network/providers/openwrt/hotplug_send%.lua$')
	if prefix then return prefix, prefix .. '/src' end
	prefix = path:match('^(.*)/services/hal/backends/network/providers/openwrt/hotplug_send%.lua$')
	if prefix then return prefix, prefix end
	return nil, nil
end

local function bootstrap_package_path()
	local src = arg and arg[0] or debug.getinfo(1, 'S').source or ''
	if src:sub(1, 1) == '@' then src = src:sub(2) end
	local project_root, lua_root = split_sender_path(src)
	if not project_root then
		local dir = dirname(src)
		-- Fall back from .../openwrt to the package root if this file was copied
		-- without its original tree.  This remains harmless when paths do not exist.
		lua_root = dir .. '/../../../../../../'
		project_root = lua_root
	end

	local paths = {
		-- Installed/check-out deployments flatten third-party modules into lib/.
		-- This is the layout on production targets, for example lib/fibers.lua
		-- and lib/fibers/*.lua.  Keep these before vendor paths so the hook
		-- uses the same module set as the running checkout.
		project_root .. '/lib/?.lua',
		project_root .. '/lib/?/init.lua',
		lua_root .. '/lib/?.lua',
		lua_root .. '/lib/?/init.lua',

		lua_root .. '/?.lua',
		lua_root .. '/?/init.lua',
		project_root .. '/src/?.lua',
		project_root .. '/src/?/init.lua',

		-- Development and test checkouts may still carry the original vendor tree.
		project_root .. '/vendor/lua-fibers/src/?.lua',
		project_root .. '/vendor/lua-fibers/src/?/init.lua',
		project_root .. '/vendor/lua-bus/src/?.lua',
		project_root .. '/vendor/lua-bus/src/?/init.lua',
		project_root .. '/vendor/lua-trie/src/?.lua',
		project_root .. '/vendor/lua-trie/src/?/init.lua',
		project_root .. '/vendor/lua-trie/?.lua',
		project_root .. '/vendor/lua-trie/?/init.lua',
	}
	local cpaths = {
		project_root .. '/lib/?.so',
		lua_root .. '/lib/?.so',
		project_root .. '/vendor/?.so',
		project_root .. '/vendor/?/?.so',
		project_root .. '/vendor/?/lib/?.so',
	}
	prepend_package_paths(paths, cpaths)
end

bootstrap_package_path()

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
