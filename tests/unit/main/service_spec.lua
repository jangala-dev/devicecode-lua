-- tests/main_spec.lua

local mainmod = require 'devicecode.main'
local runfibers = require 'tests.support.run_fibers'
local busmod = require 'bus'

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

function T.main_builds_ui_admin_auth_from_env()
	local opts = mainmod._test.build_service_opts({}, function(name)
		if name == 'DEVICECODE_UI_ADMIN_PASSWORD' then return 'e2e' end
		return nil
	end)

	local admin = assert(opts.ui.auth_opts.users.admin)
	assert(admin.password == 'e2e')
	assert(admin.principal.kind == 'user')
	assert(admin.principal.id == 'admin')
	assert(admin.principal.roles[1] == 'admin')
end

function T.main_preserves_explicit_ui_auth_opts()
	local explicit = { users = { tester = { password = 'test-password' } } }
	local opts = mainmod._test.build_service_opts({
		ui = { auth_opts = explicit },
	}, function(name)
		if name == 'DEVICECODE_UI_ADMIN_PASSWORD' then return 'e2e' end
		return nil
	end)

	assert(opts.ui.auth_opts == explicit)
	assert(opts.ui.auth_opts.users.admin == nil)
end

function T.main_forwards_service_opts_to_service_start()
	local auth_opts = { users = { admin = { password = 'e2e' } } }
	local started = mainmod._test.service_start_opts('ui', 'dev', function() end, {
		auth_opts = auth_opts,
		run_http = true,
	})

	assert(started.name == 'ui')
	assert(started.env == 'dev')
	assert(started.auth_opts == auth_opts)
	assert(started.run_http == true)
	assert(type(started.connect) == 'function')
end

function T.main_summarises_ui_auth_without_passwords()
	local count, first = mainmod._test.auth_user_summary({
		auth_opts = {
			users = {
				admin = { password = 'e2e' },
			},
		},
	})

	assert(count == 1)
	assert(first == 'admin')
end

function T.main_bootstrap_prefers_local_source_in_dev()
	local f = assert(io.open('../src/main.lua', 'r'))
	local src = f:read('*a')
	f:close()

	local dev_branch = src:match("else(.*)end")
	assert(dev_branch and dev_branch:find("add_path%('%./'%)"), 'dev bootstrap should prepend local source path')
end

return T
