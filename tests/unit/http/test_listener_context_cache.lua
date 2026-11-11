-- tests/unit/http/test_listener_context_cache.lua
--
-- services.http.listener caches one public context per transport context. The
-- public context holds its transport context (`_raw`), so the cache must not
-- keep entries alive once nothing else uses them: LuaJIT's weak-keyed tables
-- are not ephemerons, and a value that refers to its own key keeps the entry
-- (and the request's stream and connection) forever.
--
-- The transport is stubbed, so this runs without lua-http.

local tests = {}

local function eq(a, b, msg)
	if a ~= b then error((msg or 'assertion failed') .. ': expected ' .. tostring(b) .. ', got ' .. tostring(a), 2) end
end

local function count(t)
	local n = 0
	for _ in pairs(t) do n = n + 1 end
	return n
end

local function with_stub_transport(fn)
	local saved_transport = package.loaded['services.http.transport.lua_http']
	local saved_listener = package.loaded['services.http.listener']
	package.loaded['services.http.transport.lua_http'] = {
		listen = function () return { terminate = function () return true end } end,
	}
	package.loaded['services.http.listener'] = nil
	local ok, err = pcall(fn, require 'services.http.listener')
	package.loaded['services.http.transport.lua_http'] = saved_transport
	package.loaded['services.http.listener'] = saved_listener
	if not ok then error(err, 0) end
end

local next_id = 0
local function fake_raw_context()
	next_id = next_id + 1
	local id = next_id
	return { id = function () return id end, is_closed = function () return false end }
end

local function full_gc()
	collectgarbage('collect')
	collectgarbage('collect')
end

function tests.test_finished_contexts_leave_the_cache()
	with_stub_transport(function (listener_mod)
		local listener = assert(listener_mod.listen({}))
		for _ = 1, 200 do
			listener:_wrap_context(fake_raw_context())
		end
		full_gc()
		eq(count(listener._contexts), 0, 'contexts nothing else refers to are released')
	end)
end

function tests.test_a_context_in_use_keeps_its_public_handle()
	with_stub_transport(function (listener_mod)
		local listener = assert(listener_mod.listen({}))
		local raw = fake_raw_context()
		local first = listener:_wrap_context(raw)
		first = tostring(first)
		full_gc()
		-- Only the transport context is still referenced; its public handle
		-- must be the same one, not a new wrapper without the listener hooks.
		eq(tostring(listener:_wrap_context(raw)), first, 'same public context while the transport context lives')
		eq(count(listener._contexts), 1)
	end)
end

return tests
