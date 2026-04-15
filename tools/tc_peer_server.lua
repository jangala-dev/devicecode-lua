-- tc_peer_server.lua
-- Lua 5.1 / LuaJIT
--
-- Simple TCP servers used by the shaper bench.
--
-- Modes:
--   sink  : read and discard (for upload tests from root -> netns)
--   flood : continuously write bytes (for download tests netns -> root)
--   echo  : echo request/response (for latency/jitter checks)
--
-- Usage:
--   luajit tc_peer_server.lua sink  0.0.0.0 5001
--   luajit tc_peer_server.lua flood 0.0.0.0 5002
--   luajit tc_peer_server.lua echo  0.0.0.0 5003

package.path = '../src/?.lua;' .. package.path

local fibers = require 'fibers'
local socket = require 'fibers.io.socket'

local MODE = tostring(arg[1] or '')
local HOST = tostring(arg[2] or '0.0.0.0')
local PORT = tonumber(arg[3] or '0')

if MODE == '' or not PORT then
	io.stderr:write('usage: luajit tc_peer_server.lua <sink|flood|echo> <host> <port>\n')
	os.exit(2)
end

local function log(...)
	local t = {}
	local i
	for i = 1, select('#', ...) do t[#t + 1] = tostring(select(i, ...)) end
	io.stdout:write(table.concat(t, ' ') .. '\n')
	io.stdout:flush()
end

local function handle_sink(cli)
	while true do
		local s, err = cli:read_some(64 * 1024)
		if not s then break end
	end
	cli:close()
end

local function handle_flood(cli)
	cli:setvbuf('no') -- push immediately; rely on kernel/qdisc shaping
	local chunk = string.rep('X', 16 * 1024)
	while true do
		local n, err = cli:write(chunk)
		if not n then break end
	end
	cli:close()
end

local function handle_echo(cli)
	cli:setvbuf('no')
	while true do
		local line, err = cli:read_line()
		if not line then break end
		local ok, werr = cli:write(line, '\n')
		if not ok then break end
	end
	cli:close()
end

local function serve()
	local srv, err = socket.listen_inet(HOST, PORT)
	assert(srv, 'listen failed: ' .. tostring(err))
	log('listening', MODE, HOST, PORT)

	while true do
		local cli, aerr = srv:accept()
		if not cli then
			log('accept error', tostring(aerr))
		else
			fibers.spawn(function()
				if MODE == 'sink' then
					handle_sink(cli)
				elseif MODE == 'flood' then
					handle_flood(cli)
				elseif MODE == 'echo' then
					handle_echo(cli)
				else
					cli:close()
				end
			end)
		end
	end
end

fibers.run(serve)
