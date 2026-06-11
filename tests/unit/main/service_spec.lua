-- tests/main_spec.lua

local mainmod = require 'devicecode.main'
local runfibers = require 'tests.support.run_fibers'
local busmod = require 'bus'
local ui_auth = require 'services.ui.auth'

local safe = require 'coxpcall'
local stdlib = require 'posix.stdlib'

local T = {}

local function setenv(name, value)
	assert(stdlib.setenv(name, value or '', true))
end

local function with_env(values, fn)
	local names = {}
	local old = {}
	for name, _ in pairs(values) do
		names[#names + 1] = name
		old[name] = os.getenv(name)
	end

	for name, value in pairs(values) do
		setenv(name, value)
	end

	local ok, err = xpcall(fn, debug.traceback)

	for i = 1, #names do
		local name = names[i]
		setenv(name, old[name] or '')
	end

	if not ok then error(err, 0) end
end

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

function T.main_builds_ui_admin_auth_opts_from_env()
	with_env({
		DEVICECODE_UI_ADMIN_PASSWORD = 'e2e',
		DEVICECODE_UI_ADMIN_USERNAME = '',
		DEVICECODE_UI_ADMIN_USER = '',
	}, function()
		local opts = mainmod._test.service_opts_for('ui', nil)
		assert(opts.auth_opts.users.admin.password == 'e2e')
		assert(opts.auth_opts.users.admin.principal.kind == 'user')
		assert(opts.auth_opts.users.admin.principal.id == 'admin')

		local verifier = ui_auth.new(opts.auth_opts)
		local principal, err = verifier:verify({ username = 'admin', password = 'e2e' })
		assert(principal, tostring(err))
		assert(principal.kind == 'user')
		assert(principal.id == 'admin')
	end)
end

function T.main_uses_custom_ui_admin_username_from_env()
	with_env({
		DEVICECODE_UI_ADMIN_PASSWORD = 'secret',
		DEVICECODE_UI_ADMIN_USERNAME = 'tester',
		DEVICECODE_UI_ADMIN_USER = '',
	}, function()
		local opts = mainmod._test.service_opts_for('ui', nil)
		assert(opts.auth_opts.users.tester.password == 'secret')

		local verifier = ui_auth.new(opts.auth_opts)
		local principal, err = verifier:verify({ username = 'tester', password = 'secret' })
		assert(principal, tostring(err))
		assert(principal.id == 'tester')
	end)
end

function T.main_does_not_override_explicit_ui_auth_opts()
	local explicit = {
		auth_opts = {
			users = {
				tester = { password = 'test-password', principal = { kind = 'user', id = 'tester' } },
			},
		},
	}

	with_env({
		DEVICECODE_UI_ADMIN_PASSWORD = 'e2e',
		DEVICECODE_UI_ADMIN_USERNAME = '',
		DEVICECODE_UI_ADMIN_USER = '',
	}, function()
		local opts = mainmod._test.service_opts_for('ui', explicit)
		assert(opts == explicit)
		assert(opts.auth_opts.users.tester.password == 'test-password')
		assert(opts.auth_opts.users.admin == nil)
	end)
end

return T
