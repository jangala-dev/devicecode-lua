local stdlib = require 'posix.stdlib'
local process = require 'onbox.support.process'
local util = require 'onbox.support.util'
local stream = require 'onbox.support.stream'
local quote = process.quote

local M = {}
local MAX_AT_RECOVERY_RESETS = 2
local SNAPSHOT_INTERVAL = 2

---@class OnboxModemInfo
---@field id string
---@field imei string
---@field device string
---@field state string
---@field failed_reason string?
---@field plugin string
---@field model string
---@field at_port string?
---@field net_ports string[]?
---@field name string?

---@class OnboxModems
---@field box OnboxSession
---@field probe_uploaded boolean?
local Modems = {}
Modems.__index = Modems

---@param box OnboxSession
---@return OnboxModems
function M.new(box)
	return setmetatable({ box = box }, Modems)
end

---@param strict boolean? Reject incomplete enumeration when a test needs every listed modem.
---@return table<string, OnboxModemInfo>
function Modems:inventory(strict)
	local listing = self.box.ssh:run('mmcli -L', { timeout = 20 }).stdout
	local result = {}
	for id in listing:gmatch('/Modem/(%d+)') do
		local reply = self.box.ssh:run('mmcli -m ' .. id .. ' -J', { check = false, timeout = 20 })
		assert(not strict or reply.code == 0, 'Cannot inspect listed ModemManager object ' .. id)
		if reply.code == 0 then
			local generic = util.decode(reply.stdout).modem.generic
			local imei, ports, net_ports = tostring(generic['equipment-identifier'] or ''), {}, {}
			if strict then
				assert(imei:match('^%d+$'), 'Listed ModemManager object ' .. id .. ' has no usable IMEI')
				assert(not result[imei], 'ModemManager reported a duplicate IMEI')
			end
			for _, port in ipairs(generic.ports or {}) do
				local name = port:match('^(.*) %(at%)$')
				if name then ports[#ports + 1] = name end
				local dev = port:match('^(.*) %(net%)$')
				if dev then net_ports[#net_ports + 1] = dev end
			end
			if imei ~= '' then
				local at_port = ports[2] or ports[1]
				result[imei] = { id = id, imei = imei, device = generic.device or '', state = generic.state,
					failed_reason = generic['state-failed-reason'], plugin = generic.plugin or '',
					model = generic.model or '', at_port = at_port and '/dev/' .. at_port or nil, net_ports = net_ports }
			end
		end -- Objects can disappear between list and query during reset.
	end
	return result
end

-- The kernel alarm survives exec and bounds the same process even when
-- the SSH connection drops. LuaJIT is already required on the test box.
local function mmcli_watch_command(seconds, args)
	local argv = { "'mmcli'" }
	for _, value in ipairs(args) do argv[#argv + 1] = string.format('%q', value) end
	local script = ([=[
local ffi = require 'ffi'
ffi.cdef[[
	unsigned int alarm(unsigned int seconds);
	int execvp(const char *file, const char *const argv[]);
]]
local argv = ffi.new('const char *[%d]', { %s })
ffi.C.alarm(%d)
ffi.C.execvp(argv[0], argv)
io.stderr:write('Cannot start mmcli monitor (errno ', ffi.errno(), ')\n')
os.exit(127)
]=]):format(#argv + 1, table.concat(argv, ', '), math.ceil(seconds))
	return 'exec luajit -e ' .. quote(script)
end

function M.inventory_watch_command(seconds)
	return mmcli_watch_command(seconds, { '-M' })
end

function M.parse_state_watch(line)
	local id, message = line:match('^%s*/org/freedesktop/ModemManager1/Modem/(%d+): (.*)$')
	if not id then return end
	local initial = message:match("^Initial state, '([%w_-]+)'%s*$")
	if initial then return { kind = 'initial', state = initial, object_id = id } end
	local from, state = message:match("^State changed, '([%w_-]+)' %-%-> '([%w_-]+)' %(")
	if state then return { kind = 'transition', from = from, state = state, object_id = id } end
	if message:match('^Removed%s*$') then return { kind = 'removed', state = 'absent', object_id = id } end
end

function M.parse_state_syslog(line)
	local id, from, state = line:match('%]: <%w+>%s+%[modem(%d+)%] state changed %(([%w_-]+) %-> ([%w_-]+)%)')
	if id then return { kind = 'daemon', from = from, state = state, object_id = id } end
end

function Modems:watch_state(id, seconds, observe)
	assert(id:match('^%d+$'), 'Invalid ModemManager ID')
	local path = self.box.artifacts .. '/modem-state-' .. id .. '.log'
	local ssh = self.box.ssh
	local pid_path = quote(self.box.remote .. '/modem-state-' .. id .. '.pid')
	local marker = 'onbox-modem-watch-end ' .. util.trim(util.read('/proc/sys/kernel/random/uuid'))
	-- Wait for mmcli to exit before appending the marker to the same stdout.
	-- The reader must consume every earlier line before it can acknowledge it.
	local command = [[
umask 077
finish_watch() {
	kill -KILL "$onbox_watch_child" 2>/dev/null || exit 1
	wait "$onbox_watch_child" 2>/dev/null
	[ "$?" -eq 137 ] || exit 1
	printf '%s\n' ]] .. quote(marker) .. '\n' .. [[
	exit 0
}
trap finish_watch USR1
]] .. mmcli_watch_command(seconds, { '-m', id, '-w' }) .. [[ &
onbox_watch_child=$!
printf '%s\n' "$$" > ]] .. pid_path .. [[

wait "$onbox_watch_child"
exit 1
]]
	local drained = false
	local capture = stream.open(ssh, self.box.process, command, path, function(line)
		if line == marker then drained = true; return true end
		if line:match('^%s*$') then return false end
		local event = assert(M.parse_state_watch(line), 'Unrecognised ModemManager state line: ' .. line)
		assert(event.object_id == id, 'ModemManager state monitor reported a different object')
		observe(event)
		return true
	end)
	function capture.finish(watch)
		watch:assert_open()
		local signal = 'onbox_watch_pid=$(cat ' .. pid_path .. [[)
case "$onbox_watch_pid" in ''|*[!0-9]*) exit 1;; esac
tr '\000' '\n' < "/proc/$onbox_watch_pid/cmdline" | grep -Fq ]] .. quote(marker) .. [[ || exit 1
kill -USR1 "$onbox_watch_pid"
]]
		local deadline = process.now() + 15
		ssh:run(signal, { timeout = 15 })
		watch:wait_for('end marker from ModemManager object ' .. id, deadline, function() return drained end)
		watch:close()
	end
	return capture
end

---@param targets table<string, OnboxModemInfo> Stable IMEI keys, not mmcli IDs.
---@param state string? Omit to accept any unlocked, non-failed state.
---@param old_ids table<string, string>?
---@param require_at boolean? Immediately reset a modem without an AT port, up to twice per modem.
---@return table<string, OnboxModemInfo>
function Modems:wait(targets, state, old_ids, require_at)
	-- Keep the recovery path independent of the normal process manager.
	if not self.watch_inventory or self.box.recovering then
		return self:_wait(targets, state, old_ids, require_at)
	end
	self.watch_number = (self.watch_number or 0) + 1
	local path = self.box.artifacts .. '/modem-watch-' .. self.watch_number .. '.log'
	local capture = stream.open(self.box.ssh, self.box.process,
		M.inventory_watch_command(self.box.args.timeout + 10), path,
		function(line) return line:match('/Modem/%d+') ~= nil end)
	local ok, result = pcall(self._wait, self, targets, state, old_ids, require_at, capture)
	local closed, close_err = pcall(function() capture:close() end)
	if not ok then
		if not closed then io.stderr:write('Modem monitor cleanup failed: ', tostring(close_err), '\n') end
		error(result, 0)
	end
	assert(closed, close_err)
	return result
end

function Modems:_wait(targets, state, old_ids, require_at, capture)
	local deadline, last_status = process.now() + self.box.args.timeout, ''
	local excluded_ids, resets = {}, {}
	for imei, id in pairs(old_ids or {}) do excluded_ids[imei] = { [id] = true } end
	local description = state or 'AT ports'
	while process.now() < deadline do
		local seen = capture and capture:version()
		local ok, current = pcall(function() return self:inventory() end)
		if ok then
			local statuses, matched, result = {}, true, {}
			for _, imei in ipairs(util.keys(targets)) do
				local modem = current[imei]
				statuses[#statuses + 1] = (targets[imei].name or imei:sub(-4))
					.. '=' .. (modem and modem.state or 'absent')
					.. (modem and not modem.at_port and ' (no AT port)' or '')
				if modem then
					assert(modem.state == state or (modem.state ~= 'failed' and modem.state ~= 'locked'),
						('Modem …%s became %s: %s'):format(imei:sub(-4), modem.state, modem.failed_reason or ''))
					result[imei] = modem
				end
				local fresh = modem and not (excluded_ids[imei] and excluded_ids[imei][modem.id])
				if not modem or (state and modem.state ~= state) or not fresh then matched = false end
				if require_at and modem and not modem.at_port then
					matched = false
					if fresh then
						local count = resets[imei] or 0
						assert(count < MAX_AT_RECOVERY_RESETS,
							('Modem %s (…%s) still has no AT port after %d recovery resets'):format(
								targets[imei].name or imei:sub(-4), imei:sub(-4), count))
						print(('  Resetting %s (…%s): no AT port, recovery %d/%d'):format(
							targets[imei].name or imei:sub(-4), imei:sub(-4), count + 1, MAX_AT_RECOVERY_RESETS))
						self.box.ssh:run('mmcli -m ' .. modem.id .. ' --reset', { timeout = 45 })
						excluded_ids[imei] = excluded_ids[imei] or {}
						excluded_ids[imei][modem.id], resets[imei] = true, count + 1
					end
				end
			end
			local status = table.concat(statuses, ', ')
			if status ~= last_status then
				print('  Waiting for ' .. description .. ': ' .. status)
				last_status = status
			end
			if matched then return result end
		elseif self.box.interrupted and not self.box.recovering then error('Interrupted', 0) end
		if capture then
			-- Object changes wake immediately. State and AT ports can change on
			-- the same object, so periodically recheck those fields.
			local next_check = math.min(deadline, process.now() + SNAPSHOT_INTERVAL)
			local _, err = capture:wait_change(seen, next_check)
			if err then
				io.stderr:write('Modem monitor unavailable, using snapshots: ', tostring(err), '\n')
				capture = nil
			end
		else
			process.pause(math.max(0, math.min(SNAPSHOT_INTERVAL, deadline - process.now())))
		end
	end
	error(('Timed out after %ss waiting for %s: %s'):format(self.box.args.timeout, description, last_status), 0)
end

---@param targets table<string, OnboxModemInfo>
---@return table<string, OnboxModemInfo>
function Modems:ensure_at_ports(targets)
	return self:wait(targets, nil, nil, true)
end

---@param targets table<string, OnboxModemInfo>
---@param require_at boolean? Reset/recovery itself does not require an AT port.
---@return table<string, OnboxModemInfo>
---@return table<string, string> Old object IDs by IMEI.
function Modems:clean_boot(targets, require_at)
	local current, old_ids = self:inventory(), {}
	for _, imei in ipairs(util.keys(targets)) do
		old_ids[imei] = assert(current[imei], 'Target modem missing before reset: ' .. imei).id
	end
	for _, imei in ipairs(util.keys(old_ids)) do
		self.box.ssh:run('mmcli -m ' .. old_ids[imei] .. ' --reset', { timeout = 45 })
	end
	return self:wait(targets, 'disabled', old_ids, require_at), old_ids
end

---Run AT commands with ModemManager paused; a remote watchdog always resumes it.
---@param modem OnboxModemInfo
---@param commands string[]
---@return OnboxCommandResult
function Modems:probe(modem, commands)
	assert(#commands > 0, 'AT probe requires at least one command')
	assert(modem.at_port and modem.at_port ~= '',
		'No AT port reported by ModemManager for modem …' .. (modem.imei or ''):sub(-4))
	if not self.probe_uploaded then
		local module_path = assert(package.searchpath('onbox.support.modem', package.path))
		local directory = assert(stdlib.realpath(module_path)):match('^(.*)/[^/]+$')
		self.box.ssh:upload(directory .. '/at_probe.lua', self.box.remote .. '/at_probe.lua')
		self.probe_uploaded = true
	end
	local watchdog = #commands * 4 + 12
	local remote = [[
        onbox_mm_pid=$(pidof ModemManager)
        [ -n "$onbox_mm_pid" ] || exit 1
        trap 'kill -CONT "$onbox_mm_pid" 2>/dev/null; kill "$onbox_guard" 2>/dev/null || true' EXIT HUP INT TERM
        (sleep ]] .. watchdog .. [[; kill -CONT "$onbox_mm_pid" 2>/dev/null) >/dev/null 2>&1 & onbox_guard=$!
        kill -STOP "$onbox_mm_pid" || exit 1
        luajit ]] .. quote(self.box.remote .. '/at_probe.lua') .. ' ' .. quote(self.box.args.runtime)
		.. ' ' .. quote(modem.at_port)
	for _, command in ipairs(commands) do remote = remote .. ' ' .. quote(command) end
	return self.box.ssh:run(remote, { timeout = watchdog + 5, check = false })
end

---@return nil
function Modems:resume_manager()
	self.box.ssh:run('kill -CONT $(pidof ModemManager) 2>/dev/null || true')
end

---@return table<string, string>
function Modems:diagnostic_commands()
	return { modems = [[mmcli -L; for id in $(mmcli -L | sed -n 's@.*Modem/\([0-9]*\).*@\1@p'); do
        mmcli -m "$id" -J; done]] }
end

return M
