local sleep = require 'fibers.sleep'

local M = {}

local SIGNAL_NUMBERS = {
	TERM = 15,
	INT = 2,
}

local function normalise_name(name)
	name = tostring(name or ''):upper():gsub('^SIG', '')
	return name
end

local function load_posix_backend()
	local ok_sig, psig = pcall(require, 'posix.signal')
	if not ok_sig or type(psig) ~= 'table' or type(psig.signal) ~= 'function' then
		return nil
	end

	local ok_unistd, unistd = pcall(require, 'posix.unistd')
	if not ok_unistd or type(unistd) ~= 'table' then
		unistd = {}
	end

	local function signum(name)
		return psig['SIG' .. name] or SIGNAL_NUMBERS[name]
	end

	local function set_handler(name, handler)
		local old, err, eno = psig.signal(signum(name), handler)
		if not old and err then
			return nil, tostring(err) .. (eno and (':' .. tostring(eno)) or '')
		end
		return old or true
	end

	local function restore(name, old)
		if old == true then
			old = 'default'
		end
		pcall(psig.signal, signum(name), old)
	end

	local function hard_exit(name)
		local sig = signum(name)
		pcall(psig.signal, sig, 'default')
		if type(psig.kill) == 'function' and type(unistd.getpid) == 'function' then
			pcall(psig.kill, unistd.getpid(), sig)
		end
		os.exit(128 + (sig or 0))
	end

	return {
		name = 'posix.signal',
		set_handler = set_handler,
		restore = restore,
		hard_exit = hard_exit,
	}
end

local function load_nixio_backend()
	local ok, nixio = pcall(require, 'nixio')
	if not ok or type(nixio) ~= 'table' or type(nixio.signal) ~= 'function' then
		return nil
	end

	local function signum(name)
		return nixio['SIG' .. name] or SIGNAL_NUMBERS[name]
	end

	local function set_handler(name, handler)
		-- The documented nixio API only guarantees 'ign' and 'dfl'.  Some
		-- builds may accept Lua callbacks; use that only when it succeeds.
		local ok2, old_or_err, eno = pcall(nixio.signal, signum(name), handler)
		if not ok2 or old_or_err == nil or old_or_err == false then
			return nil, tostring(old_or_err) .. (eno and (':' .. tostring(eno)) or '')
		end
		return old_or_err or true
	end

	local function restore(name, old)
		if old == true then
			old = 'dfl'
		end
		pcall(nixio.signal, signum(name), old)
	end

	local function hard_exit(name)
		local sig = signum(name)
		pcall(nixio.signal, sig, 'dfl')
		if type(nixio.kill) == 'function' and type(nixio.getpid) == 'function' then
			pcall(nixio.kill, nixio.getpid(), sig)
		end
		os.exit(128 + (sig or 0))
	end

	return {
		name = 'nixio.signal',
		set_handler = set_handler,
		restore = restore,
		hard_exit = hard_exit,
	}
end

local function choose_backend()
	return load_posix_backend() or load_nixio_backend()
end

---Install a TERM/INT bridge from process signals to root-scope cancellation.
---The signal callback records intent only; a normal fiber performs cancellation.
---A second signal restores the default disposition and re-signals this process.
---@param scope Scope
---@param signals table<string, boolean>|nil
---@return boolean ok
---@return string? err
function M.install(scope, signals)
	assert(scope and type(scope.spawn) == 'function', 'signal_bridge.install: scope required')

	signals = signals or { TERM = true, INT = true }

	local backend = choose_backend()
	if not backend then
		return false, 'no supported signal backend'
	end

	local pending
	local seen = {}
	local installed = {}

	for name, enabled in pairs(signals) do
		name = normalise_name(name)
		if enabled then
			local function handler()
				if seen[name] then
					backend.hard_exit(name)
					return
				end
				seen[name] = true
				pending = name
			end

			if jit and jit.off then
				pcall(jit.off, handler, true)
			end

			local old, err = backend.set_handler(name, handler)
			if not old then
				for installed_name, old_handler in pairs(installed) do
					backend.restore(installed_name, old_handler)
				end
				return false, 'failed to install signal handler for ' .. name .. ': ' .. tostring(err)
			end
			installed[name] = old
		end
	end

	scope:finally(function()
		for name, old in pairs(installed) do
			backend.restore(name, old)
		end
	end)

	local spawned, spawn_err = scope:spawn(function()
		while true do
			if pending then
				scope:cancel('signal:' .. tostring(pending))
				return
			end
			sleep.sleep(0.1)
		end
	end)

	if not spawned then
		for name, old in pairs(installed) do
			backend.restore(name, old)
		end
		return false, 'failed to start signal watcher: ' .. tostring(spawn_err)
	end

	return true, backend.name
end

return M
