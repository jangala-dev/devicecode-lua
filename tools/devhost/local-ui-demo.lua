#!/usr/bin/env lua
-- tools/devhost/local-ui-demo.lua
--
-- Run the real HTTP, UI and GSM services on devhost with a fake HAL
-- control-store.  This is intended for manual UI work:
--
--   lua tools/devhost/local-ui-demo.lua --port 18089
--   open http://127.0.0.1:18089/
--
-- APNs are persisted for this process in the in-memory fake control-store.

package.path = 'src/?.lua;src/?/init.lua;' .. package.path
package.path = 'vendor/lua-fibers/src/?.lua;vendor/lua-fibers/src/?/init.lua;' .. package.path
package.path = 'vendor/lua-bus/src/?.lua;vendor/lua-bus/src/?/init.lua;' .. package.path
package.path = 'vendor/lua-trie/src/?.lua;vendor/lua-trie/src/?/init.lua;' .. package.path
package.path = './?.lua;./?/init.lua;tests/?.lua;tests/?/init.lua;' .. package.path

local fibers = require 'fibers'
local sleep  = require 'fibers.sleep'
local op     = require 'fibers.op'
local harness = require 'tests.support.local_ui_devhost'

local function arg_value(name, default)
	for i = 1, #arg do
		if arg[i] == name then return arg[i + 1] or default end
		local v = tostring(arg[i]):match('^' .. name:gsub('%-', '%%-') .. '=(.+)$')
		if v then return v end
	end
	return default
end

local function has_flag(name)
	for i = 1, #arg do if arg[i] == name then return true end end
	return false
end

if has_flag('--help') or has_flag('-h') then
	io.write([[Big Box local UI devhost demo

Usage:
  lua tools/devhost/local-ui-demo.lua [--port 18089] [--static-root www]

Starts:
  - real services.http
  - real services.ui
  - real services.gsm
  - fake HAL control-store capability for GSM APNs

Then open:
  http://127.0.0.1:<port>/

Useful curl checks:
  curl -fsS http://127.0.0.1:<port>/api/local-ui/bootstrap | jq .schema
  curl -fsS http://127.0.0.1:<port>/api/gsm/apns/custom
]])
	os.exit(0)
end

local port = tonumber(arg_value('--port', os.getenv('LOCAL_UI_DEVHOST_PORT') or '18089')) or 18089
local static_root = arg_value('--static-root', 'www')

fibers.run(function (scope)
	local inst = harness.start(scope, {
		port = port,
		static_root = static_root,
		demo_state = true,
	})
	harness.wait_http_ready(inst.base_url, { timeout = 6 })

	io.write(('Big Box local UI demo running at %s/\n'):format(inst.base_url))
	io.write('Using real HTTP/UI/GSM services and fake HAL control-store for APNs.\n')
	io.write('Press Ctrl-C to stop.\n')
	io.flush()

	fibers.perform(op.choice(
		sleep.sleep_op(365 * 24 * 60 * 60),
		scope:fault_op()
	))
end)
