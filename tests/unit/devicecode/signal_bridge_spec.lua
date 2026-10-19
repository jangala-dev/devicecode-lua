local T = {}

local function with_fake_posix(fn)
	local saved_signal = package.loaded['posix.signal']
	local saved_unistd = package.loaded['posix.unistd']
	local saved_nixio = package.loaded['nixio']
	local saved_sleep = package.loaded['fibers.sleep']
	local saved_mod = package.loaded['devicecode.signal_bridge']

	local handlers = {}
	local killed

	package.loaded['posix.signal'] = {
		SIGTERM = 15,
		SIGINT = 2,
		signal = function(signum, handler)
			local old = handlers[signum] or true
			handlers[signum] = handler
			return old
		end,
		kill = function(pid, sig)
			killed = { pid = pid, sig = sig }
			return true
		end,
	}
	package.loaded['posix.unistd'] = {
		getpid = function() return 12345 end,
	}
	package.loaded['nixio'] = nil
	package.loaded['fibers.sleep'] = {
		sleep = function(_seconds)
			error('test watcher slept before cancellation', 0)
		end,
	}
	package.loaded['devicecode.signal_bridge'] = nil

	local ok, a, b = pcall(function()
		return fn(handlers, function() return killed end)
	end)

	package.loaded['posix.signal'] = saved_signal
	package.loaded['posix.unistd'] = saved_unistd
	package.loaded['nixio'] = saved_nixio
	package.loaded['fibers.sleep'] = saved_sleep
	package.loaded['devicecode.signal_bridge'] = saved_mod

	if not ok then error(a, 0) end
	return a, b
end

function T.signal_bridge_cancels_scope_from_watcher_not_handler()
	with_fake_posix(function(handlers)
		local bridge = require 'devicecode.signal_bridge'
		local spawned
		local restored
		local cancelled
		local scope = {
			spawn = function(_self, fn)
				spawned = fn
				return true
			end,
			finally = function(_self, fn)
				restored = fn
				return function() end
			end,
			cancel = function(_self, reason)
				cancelled = reason
			end,
		}

		local ok, backend = bridge.install(scope, { TERM = true })
		assert(ok == true)
		assert(backend == 'posix.signal')
		assert(type(spawned) == 'function')
		assert(type(restored) == 'function')
		assert(type(handlers[15]) == 'function')
		assert(cancelled == nil)

		handlers[15]()
		assert(cancelled == nil, 'handler must not cancel scope directly')

		spawned()
		assert(cancelled == 'signal:TERM')

		restored()
	end)
end

return T
