-- tests/unit/support/test_config_watch_architecture.lua
--
-- Guardrails for the retained cfg/<service> bootstrap path used by modern
-- Devicecode services.  Service code should consume configuration through
-- devicecode.support.config_watch, which relies on lua-bus subscription replay
-- for retained cfg bootstrap.

local tests = {}

local modern_services = {
	fabric = '../src/services/fabric/service.lua',
	device = '../src/services/device/service.lua',
	update = '../src/services/update/service.lua',
	http   = '../src/services/http/service.lua',
	ui     = '../src/services/ui/service.lua',
	net    = '../src/services/net/service.lua',
	wired  = '../src/services/wired/service.lua',
}

local modern_roots = {
	'../src/services/fabric',
	'../src/services/device',
	'../src/services/update',
	'../src/services/http',
	'../src/services/ui',
	'../src/services/net',
	'../src/services/wired',
}

local function fail(msg) error(msg or 'assertion failed', 2) end

local function read_file(path)
	local f = assert(io.open(path, 'r'))
	local s = f:read('*a')
	f:close()
	return s
end

local function scan_files(root)
	local p = assert(io.popen(('find %s -type f -name "*.lua" | sort'):format(root)))
	local out = {}
	for line in p:lines() do out[#out + 1] = line end
	p:close()
	return out
end

local function split_lines(s)
	local lines = {}
	for line in (s .. '\n'):gmatch('([^\n]*)\n') do
		lines[#lines + 1] = line
	end
	return lines
end

local function line_window(lines, i, before, after)
	local out = {}
	local first = math.max(1, i - before)
	local last = math.min(#lines, i + after)
	for n = first, last do out[#out + 1] = lines[n] end
	return table.concat(out, '\n')
end

local function looks_like_service_cfg_reference(window)
	local needles = {
		"{ 'cfg'",
		'{ "cfg"',
		"'cfg'",
		'"cfg"',
		'topics.config()',
		'topics.cfg()',
		"config_topic",
		"cfg_topic",
	}
	for _, needle in ipairs(needles) do
		if window:find(needle, 1, true) then return true end
	end
	return false
end

function tests.test_modern_service_shells_use_shared_config_watch_helper()
	for service, path in pairs(modern_services) do
		local s = read_file(path)
		if not s:find("devicecode.support.config_watch", 1, true) then
			fail(service .. ' service shell does not require devicecode.support.config_watch')
		end
		if not s:find('config_watch.open', 1, true) then
			fail(service .. ' service shell does not open configuration through config_watch.open')
		end
	end
end

function tests.test_modern_service_shells_do_not_subscribe_to_cfg_directly()
	for service, path in pairs(modern_services) do
		local s = read_file(path)
		if s:find('conn:subscribe', 1, true) or s:find('bus_cleanup.subscribe', 1, true) then
			fail(service .. ' service shell subscribes directly instead of using config_watch')
		end
	end
end

function tests.test_modern_services_do_not_add_direct_cfg_subscription_regressions()
	for _, root in ipairs(modern_roots) do
		for _, path in ipairs(scan_files(root)) do
			local lines = split_lines(read_file(path))
			for i, line in ipairs(lines) do
				if line:find(':subscribe%s*%(') or line:find('bus_cleanup%.subscribe%s*%(') then
					local window = line_window(lines, i, 4, 6)
					if looks_like_service_cfg_reference(window) then
						fail(path .. ':' .. tostring(i) .. ' appears to subscribe to cfg directly; use config_watch.open')
					end
				end
			end
		end
	end
end

function tests.test_config_watch_helper_is_the_only_shared_helper_that_subscribes_to_cfg_service_directly()
	local helper = read_file('../src/devicecode/support/config_watch.lua')
	if not helper:find('bus_cleanup.subscribe', 1, true) then
		fail('config_watch helper should own the local bus subscription')
	end
	if not helper:find("{ 'cfg', service }", 1, true) then
		fail('config_watch helper should own cfg/<service> topic construction')
	end
end

return tests
