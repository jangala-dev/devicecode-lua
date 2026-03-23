-- tests/main_spec.lua

local mainmod = require 'devicecode.main'
local runfibers = require 'tests.support.run_fibers'
local busmod = require 'bus'

local T = {}

function T.main_rejects_duplicate_service_names()
	local ok, err = pcall(function()
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
	local ok, err = pcall(function()
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

return T
