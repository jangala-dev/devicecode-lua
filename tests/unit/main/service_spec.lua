-- tests/main_spec.lua

local mainmod = require 'devicecode.main'
local runfibers = require 'tests.support.run_fibers'
local busmod = require 'bus'
local fibers = require 'fibers'
local sleep = require 'fibers.sleep'
local pulse = require 'fibers.pulse'

local safe = require 'coxpcall'

local T = {}

function T.main_rejects_duplicate_service_names()
	local ok, err = safe.pcall(function()
		runfibers.run(function(scope)
			mainmod.run(scope, {
				env = 'dev',
				bus = busmod.new(),
				services_csv = 'hal,hal',
				service_loader = function(name)
					return { start = function() end }
				end,
			})
		end)
	end)

	assert(ok == false)
	assert(tostring(err):match('duplicate service name'))
end

function T.main_fails_boot_when_service_load_fails()
	local ok, err = safe.pcall(function()
		runfibers.run(function(scope)
			mainmod.run(scope, {
				env = 'dev',
				bus = busmod.new(),
				services_csv = 'hal',
				service_loader = function(name)
					error('boom')
				end,
			})
		end)
	end)

	assert(ok == false)
	assert(tostring(err):match('boot failed'))
end


function T.main_passes_current_colleague_option_shape_but_not_http_ui_wiring()
	local got_opts
	local started = pulse.new()
	local seen = started:version()
	local run_http = function() end
	local verify_login = function() end
	local services = { 'x' }

	runfibers.run(function(scope)
		local main_scope, cerr = scope:child()
		assert(main_scope ~= nil, tostring(cerr))

		local ok_spawn, serr = scope:spawn(function()
			mainmod.run(main_scope, {
				env = 'dev',
				bus = busmod.new(),
				services_csv = 'ui',
				service_opts = {
					ui = {
						services = services,
						run_http = run_http,
						verify_login = verify_login,
						http = { host = '127.0.0.1' },
						http_listen = { port = 9999 },
						http_cap_id = 'legacy-http',
						static_root = '/legacy/static',
					},
				},
				service_loader = function(name)
					return {
						start = function(_, opts)
							got_opts = opts
							started:signal()
							while true do sleep.sleep(3600) end
						end,
					}
				end,
			})
		end)
		assert(ok_spawn, tostring(serr))

		fibers.perform(started:changed_op(seen))
		assert(got_opts ~= nil)
		assert(got_opts.name == 'ui')
		assert(got_opts.env == 'dev')
		assert(type(got_opts.connect) == 'function')
		assert(got_opts.services == services)
		assert(got_opts.run_http == run_http)
		assert(got_opts.verify_login == verify_login)
		assert(got_opts.http == nil)
		assert(got_opts.http_listen == nil)
		assert(got_opts.http_cap_id == nil)
		assert(got_opts.static_root == nil)

		main_scope:cancel('test complete')
		fibers.perform(main_scope:join_op())
	end, { timeout = 0.5 })
end

return T
