-- tests/support/run_fibers.lua

local fibers = require 'fibers'
local sleep  = require 'fibers.sleep'
local pulse  = require 'fibers.pulse'
local op     = require 'fibers.op'

local safe = require 'coxpcall'

local M = {}

function M.run(fn, opts)
	opts = opts or {}
	local timeout = opts.timeout or 2.0

	local ok, err = safe.pcall(function()
		fibers.run(function(root_scope)
			local test_scope, cerr = root_scope:child()
			if not test_scope then
				error(cerr, 0)
			end

			local done = pulse.new()
			local body_err = nil

			local ok_spawn, spawn_err = test_scope:spawn(function(s)
				local ok_body, err_body = safe.pcall(function()
					fn(s)
				end)

				body_err = ok_body and nil or err_body
				done:signal()

				if not ok_body then
					error(err_body, 0)
				end
			end)

			if not ok_spawn then
				error(spawn_err, 0)
			end

			local ok_timer, timer_err = root_scope:spawn(function()
				local completed = fibers.perform(op.boolean_choice(
					done:next_op():wrap(function() return true end),
					sleep.sleep_op(timeout):wrap(function() return false end)
				))

				if completed == false then
					test_scope:cancel('test timeout')
					error(('test timed out after %.3fs'):format(timeout), 0)
				end
			end)

			if not ok_timer then
				error(timer_err, 0)
			end

			done:next()

			test_scope:cancel('test complete')
			fibers.perform(test_scope:join_op())

			if body_err then
				error(body_err, 0)
			end
		end)
	end)

	if not ok then
		error(err, 0)
	end
end

return M
