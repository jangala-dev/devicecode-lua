local process = require 'onbox.support.process'
local stream = require 'onbox.support.stream'
local util = require 'onbox.support.util'

local M = {}

function M.decoder(on_event)
	local data, size = {}, 0
	return function(line)
		if line == '' then
			if #data == 0 then return false end
			local event = util.decode(table.concat(data, '\n'))
			data, size = {}, 0
			return on_event(event)
		end
		local value = line:match('^data: ?(.*)$')
		if not value then return false end
		size = size + #value + 1
		assert(size <= 1024 * 1024, 'UI log event exceeds 1 MiB')
		data[#data + 1] = value
		return false
	end
end

local function read_snapshot(box, url, path, deadline, accept)
	local remaining = math.max(1, math.ceil(deadline - process.now()))
	local result = box.ssh:run('curl -fsS --max-time ' .. math.min(10, remaining) .. ' --url '
		.. process.quote(url), { timeout = math.min(15, remaining), check = false })
	util.write(path, result.stdout)
	if result.stderr ~= '' then util.write(path .. '.stderr', result.stderr) end
	if result.code ~= 0 then return end
	local decoded, reply = pcall(util.decode, result.stdout)
	if decoded and reply.ok == true then
		for _, record in ipairs(reply.records or {}) do accept(record) end
	end
end

-- The service has just restarted. Snapshots cover records that predate
-- the listener and are missing from the replay, which can be truncated
-- when the monitor queues more records than its follower mailbox can hold.
function M.follow(box, url, label, deadline, accept, complete, expected)
	local ready
	local path = box.artifacts .. '/' .. label .. '-ui-logs.sse'
	local timeout = math.max(1, math.ceil(deadline - process.now()))
	local capture = stream.open(box.ssh, box.process,
		'curl -fsSN --connect-timeout 5 --max-time ' .. timeout
			.. ' --retry 20 --retry-connrefused --retry-max-time ' .. timeout
			.. ' --url ' .. process.quote(url .. '/api/logs/follow'), path,
		M.decoder(function(event)
			if event.kind == 'ready' then ready = true; return true end
			if event.kind == 'log' then
				assert(type(event.record) == 'table', 'Missing UI log record')
				return accept(event.record)
			end
			return false
		end))
	local ok, result = pcall(function()
		capture:wait_for(label .. ' UI log subscription', deadline, function() return ready end)
		local prefix = box.artifacts .. '/' .. label
		if not complete() and process.now() < deadline then
			read_snapshot(box, url .. '/api/logs', prefix .. '-ui-recent-logs.json', deadline, accept)
		end
		if not complete() and process.now() < deadline then
			read_snapshot(box, url .. '/api/logs?boot=true', prefix .. '-ui-boot-logs.json', deadline, accept)
		end
		return capture:wait_for(expected, deadline, complete)
	end)
	local closed, close_err = pcall(function() capture:close() end)
	if not ok then
		if not closed then io.stderr:write('UI log stream cleanup failed: ', tostring(close_err), '\n') end
		error(result, 0)
	end
	assert(closed, close_err)
	return result
end

return M
