-- fibers.utils.time
--
-- Top-level time provider shim.
--
-- Backends (priority order):
--   1. fibers.utils.time.ffi      - clock_gettime + nanosleep (via ffi_compat)
--   2. fibers.utils.time.luaposix - luaposix clock_gettime/nanosleep
--   3. fibers.utils.time.nixio    - nixio gettime, nanosleep + /proc/uptime
--   4. fibers.utils.time.linux    - /proc/uptime or os.time + os.execute("sleep")
--
---@module 'fibers.utils.time'

local candidates = {
	'fibers.utils.time.ffi',
	'fibers.utils.time.luaposix',
	'fibers.utils.time.nixio',
	'fibers.utils.time.linux',
}

local chosen

for _, name in ipairs(candidates) do
	local ok, mod = pcall(require, name)
	if ok and type(mod) == 'table' and mod.is_supported and mod.is_supported() then
		chosen = mod
		break
	end
end

if not chosen then
	error('fibers.utils.time: no suitable time backend available on this platform')
end

return chosen
