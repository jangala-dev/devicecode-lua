-- coxpcall.lua
--
-- Coroutine-safe pcall/xpcall for Lua 5.1-style environments.
-- If the host already provides yield-safe pcall/xpcall (e.g. LuaJIT), this
-- module returns the native functions unchanged.
--
-- This version aims to make Lua 5.1 tracebacks look closer to LuaJIT by:
--   * using debug.traceback(co, ...) for the failing coroutine, and
--   * splicing in “outer” call-site frames by walking the coroutine parent chain,
--     inserting a synthetic “[C]: in function 'xpcall'” boundary each hop.

local M = {}

-------------------------------------------------------------------------------
-- Checks if (x)pcall function is coroutine safe
-------------------------------------------------------------------------------
local function isCoroutineSafe(func)
	local co = coroutine.create(function ()
		return func(coroutine.yield, function () end)
	end)

	coroutine.resume(co)
	return coroutine.resume(co)
end

-- Fast path: environment already has coroutine-safe pcall/xpcall
if isCoroutineSafe(pcall) and isCoroutineSafe(xpcall) then
	M.pcall   = pcall
	M.xpcall  = xpcall
	M.running = coroutine.running
	return M
end

-------------------------------------------------------------------------------
-- Implements xpcall with coroutines
-------------------------------------------------------------------------------

local performResume, handleReturnValue
local oldpcall, oldxpcall = pcall, xpcall
local unpack              = rawget(table, 'unpack') or _G.unpack
local pack                = rawget(table, 'pack') or function (...)
	return { n = select('#', ...), ... }
end
local running             = coroutine.running
local coromap             = setmetatable({}, { __mode = 'k' })

local function id(trace)
	return trace
end

local function filter_outer_tb(tb)
	if type(tb) ~= 'string' or tb == '' then
		return nil
	end

	local kept = {}
	for line in tb:gmatch('[^\n]+') do
		if line ~= 'stack traceback:'
			and not line:match('^%s*$')
			and not line:match('%(tail call%)')
			and not line:find('coxpcall.lua', 1, true)
			and not line:find("in function 'coroutine.resume'", 1, true)
			and not line:find('handleReturnValue', 1, true)
			and not line:find('performResume', 1, true)
		then
			kept[#kept + 1] = line
		end
	end

	if #kept == 0 then
		return nil
	end
	return table.concat(kept, '\n')
end

local function splice_chain(tb_inner, co, marker)
	if type(tb_inner) ~= 'string' or tb_inner == '' then
		return tb_inner
	end
	if not (debug and debug.traceback) then
		return tb_inner
	end

	marker = marker or "\t[C]: in function 'xpcall'"

	local out = tb_inner
	local parent = coromap[co]

	while parent do
		-- Level 3: drop the debug.traceback frame and the splice helper.
		local tb_outer = debug.traceback(parent, '', 3)
		tb_outer = filter_outer_tb(tb_outer) or ''

		if tb_outer and tb_outer ~= '' then
			out = out .. '\n' .. marker .. '\n' .. tb_outer
		end

		parent = coromap[parent]
	end

	return out
end

function handleReturnValue(err, co, status, ...)
	if not status then
		-- Error path from coroutine.resume(co, ...)
		if err == id then
			-- pcall semantics: propagate the original error object unchanged
			return false, ...
		end

		local e = ...

		-- Compute the failing coroutine traceback and splice in outer call-site frames.
		local tb
		if debug and debug.traceback then
			tb = debug.traceback(co, tostring(e))
			tb = splice_chain(tb, co)
		else
			tb = tostring(e)
		end

		-- Preserve idiom: xpcall(f, debug.traceback)
		if err == debug.traceback then
			return false, tb
		end

		-- Call handler with (error_object, traceback_string). A 1-arg handler
		-- will ignore the second argument.
		local ok_h, handled = oldpcall(err, e, tb)
		if not ok_h then
			-- If the handler itself faults, xpcall reports that fault.
			return false, handled
		end
		return false, handled
	end

	if coroutine.status(co) == 'suspended' then
		return performResume(err, co, coroutine.yield(...))
	else
		return true, ...
	end
end

function performResume(err, co, ...)
	return handleReturnValue(err, co, coroutine.resume(co, ...))
end

local function coxpcall(f, err, ...)
	local current = running()
	if not current then
		-- Not in a coroutine: fall back to normal pcall/xpcall
		if err == id then
			return oldpcall(f, ...)
		else
			if select('#', ...) > 0 then
				local oldf, params = f, pack(...)
				f = function () return oldf(unpack(params, 1, params.n)) end
			end
			return oldxpcall(f, err)
		end
	else
		local res, co = oldpcall(coroutine.create, f)
		if not res then
			local newf = function (...) return f(...) end
			co = coroutine.create(newf)
		end
		coromap[co] = current
		return performResume(err, co, ...)
	end
end

local function corunning(coro)
	if coro ~= nil then
		assert(type(coro) == 'thread',
			'Bad argument; expected thread, got: ' .. type(coro))
	else
		coro = running()
	end
	while coromap[coro] do
		coro = coromap[coro]
	end
	if coro == 'mainthread' then return nil end
	return coro
end

-------------------------------------------------------------------------------
-- Implements pcall with coroutines
-------------------------------------------------------------------------------

local function copcall(f, ...)
	return coxpcall(f, id, ...)
end

M.pcall   = copcall
M.xpcall  = coxpcall
M.running = corunning

return M
