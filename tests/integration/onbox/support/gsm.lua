local logs = require 'onbox.support.logs'

local M = {}

function M.modem_config(config, modem)
	local modems = assert(config.gsm and config.gsm.data and config.gsm.data.modems, 'Missing GSM modem config')
	local result = {}
	for key, value in pairs(modems.default or {}) do result[key] = value end
	for _, entry in ipairs(modems.known or {}) do
		if type(entry) == 'table' and ((entry.id_field == 'device' and modem.device and modem.device ~= ''
			and entry.device == modem.device) or (entry.id_field ~= 'device' and entry.imei == modem.imei)) then
			for key, value in pairs(entry) do result[key] = value end
			return result, result.name
		end
	end
	return result
end

function M.log_label(imei, name)
	if not name or name == '' then name = imei end
	local suffix = #imei > 4 and '…' .. imei:sub(-4) or imei
	return name == suffix and name or name .. ' ' .. suffix
end

-- The role and IMEI suffix stay stable when a modem gets a new object ID.
function M.parse_transition(line, label)
	local event, summary = line:match('%f[%w]LOG%s+gsm%s+%S+%s+(%S+)%s+(.+)$')
	if event ~= 'modem_state_changed' and event ~= 'modem_failed' then return end
	local identity, state = summary:match('^(.-) modem state %-> ([%w_-]+)%s*$')
	if identity ~= label then return end
	return { source = 'gsm', state = state, monotonic_s = tonumber(line:match('%(mono=([%d.]+)%)')),
		event_monotonic_s = logs.event_time(line) }
end

function M.parse_removal(line, imei, device)
	local suffix, port = line:match('%f[%w]LOG%s+gsm%s+%S+%s+modem_removed%s+imei_suffix=(%d+) device=(%S+)%s*$')
	if suffix == imei:sub(-4) and port == device:match('[^/]+$') then
		return { source = 'gsm', state = 'absent', monotonic_s = tonumber(line:match('%(mono=([%d.]+)%)')) }
	end
end

function M.monitor_pid(line)
	return line:match('%[(%d+)%]: %d%d%d%d%-%d%d%-%d%d%s+%d%d:%d%d:%d%d%s+%(mono=')
end

return M
