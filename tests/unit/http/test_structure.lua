local M = {}

local function ok(v, msg)
	if not v then error(msg or 'assertion failed', 2) end
end

local function read_file(path)
	local f = assert(io.open(path, 'r'))
	local s = f:read('*a')
	f:close()
	return s
end

function M.test_only_http_transport_requires_lua_http_or_cqueues()
	local p = io.popen("find ../src/services/http -name '*.lua' | sort")
	for file in p:lines() do
		local s = read_file(file)
		local has_backend_require = s:find("require 'cqueues", 1, true)
			or s:find("require 'http.", 1, true)
			or s:find("pcall(require, 'cqueues", 1, true)
			or s:find("pcall(require, 'http.", 1, true)
		if has_backend_require then
			ok(file:find('/transport/', 1, true), 'backend require outside transport: ' .. file)
		end
	end
	p:close()
end


function M.test_http_sources_use_termination_vocabulary()
	local cmd = [[find ../src/services/http ../src/services/ui \( -name '*.lua' -o -name '*.md' \) | sort]]
	local p = assert(io.popen(cmd))

	for file in p:lines() do
		local s = read_file(file)
		local old_terminate = 'terminate' .. '_now'
		local old_close = 'close' .. '_now'

		ok(not s:find(old_terminate, 1, true), old_terminate .. ' used in ' .. file)
		ok(not s:find(old_close, 1, true), old_close .. ' used in ' .. file)
	end

	p:close()
end


function M.test_http_service_wires_components_with_service_event_ports()
	local service = read_file('../src/services/http/service.lua')
	ok(service:find('devicecode.support.service_events', 1, true), 'http service does not use service event helper')
	ok(service:find('_event_port', 1, true), 'http service lacks event-port helper')
	ok(service:find('events_port = self:_event_port', 1, true), 'http backend/registry are not wired through event ports')

	local ops = read_file('../src/services/http/operations.lua')
	ok(ops:find('events_port = service_events.port', 1, true), 'http listener operation does not pass event port')
	ok(not ops:find('on_context_admitted = function', 1, true), 'http operation still passes context admission callback')
	ok(not ops:find('on_context_transferred = function', 1, true), 'http operation still passes context transfer callback')
	ok(not ops:find('on_server_websocket = function', 1, true), 'http operation still passes server websocket callback')
end

function M.test_http_public_service_entrypoint_is_long_lived()
	local entry = read_file('../src/services/http.lua')
	ok(entry:find("local service = require 'services.http.service'", 1, true), 'http entrypoint should wrap HTTP service module')
	ok(entry:find('service.start(conn, opts)', 1, true), 'http entrypoint should start the HTTP service')
	ok(entry:find('fibers.perform(fibers.never())', 1, true), 'top-level http service entrypoint must not return to main supervisor')
end

function M.test_http_service_code_does_not_use_perform_raw()
	local p = io.popen("find ../src/services/http -name '*.lua' | sort")
	for file in p:lines() do
		local s = read_file(file)
		ok(not s:find('perform_raw', 1, true), 'perform_raw used in ' .. file)
	end
	p:close()
end


function M.test_http_service_and_support_do_not_use_private_op_internals()
	local files = {}
	local p1 = io.popen("find ../src/services/http -name '*.lua' | sort")
	for file in p1:lines() do
		if not file:find('/transport/', 1, true) then files[#files + 1] = file end
	end
	p1:close()
	files[#files + 1] = '../src/devicecode/support/queue.lua'
	files[#files + 1] = '../src/devicecode/support/priority_event.lua'

	local forbidden = {
		'try_fn',
		'wait_fn',
		'new_primitive',
	}

	for _, file in ipairs(files) do
		local s = read_file(file)
		for _, needle in ipairs(forbidden) do
			ok(not s:find(needle, 1, true), ('private Op internals %s used in %s'):format(needle, file))
		end
	end
end

return M
