local gsm = require 'onbox.support.gsm'
local net = require 'onbox.support.net'
local util = require 'onbox.support.util'

local M = {}
local Timing = {}
Timing.__index = Timing

function M.new(config, targets, inventory, args)
	local members = net.members(config)
	local by_member = {}
	for imei, target in pairs(targets) do
		local cfg, role = gsm.modem_config(config, inventory[imei])
		local label = gsm.log_label(imei, role)
		assert(cfg.autoconnect, label .. ' needs autoconnect for recovery timing')
		role = role and role ~= '' and role or imei
		local match
		for id, member in pairs(members) do
			if member.source and member.source.kind == 'gsm-uplink' and member.source.id == role
				and member.enabled ~= false and member.disabled ~= true then
				assert(not match, label .. ' has multiple WAN members')
				match = id
			end
		end
		assert(match, label .. ' has no WAN member')
		assert(not by_member[match], 'WAN member ' .. match .. ' matches more than one modem')
		target.recovery = { label = label, role = role, member = match, interface = members[match].interface or match }
		by_member[match] = imei
	end
	return setmetatable({ targets = targets, by_member = by_member, statuses = {}, args = args }, Timing)
end

function Timing:observe_net(line)
	local status = net.status_event(line)
	local imei = status and self.by_member[status.member]
	if not imei or status.interface ~= self.targets[imei].recovery.interface then return end
	self.statuses[imei] = status
	return imei, status
end

function Timing:online(imei)
	local status = self.statuses[imei]
	return status and status.state == 'online' and status.device ~= nil and status.alias ~= nil
end

function Timing:observe_reset(imei, line, lifecycle, replacement, gsm_reappeared, status)
	local result = self.targets[imei].recovery
	if lifecycle and lifecycle.source == 'hal' and lifecycle.state == 'removed'
		and lifecycle.object_id == self.targets[imei].before_object_id then
		result.old_object_removed = true
	end
	if result.old_object_removed and not result.uplink_lost then
		local role = line:match('%f[%w]LOG%s+net%s+%S+%s+gsm_uplink_changed%s+cellular uplink (%S+) unavailable%f[%W]')
		if role == result.role or (status and status.state == 'offline') then result.uplink_lost = true end
	end
	if lifecycle and lifecycle.source == 'hal' and lifecycle.state == 'added' and replacement == lifecycle.object_id
		and not result.reappeared_s then
		result.reappeared_s = assert(lifecycle.event_monotonic_s, 'HAL reappearance has no producer monotonic timestamp')
	end
	if not result.reappeared_s then return false end
	local state = gsm_reappeared and gsm.parse_transition(line, result.label)
	if state then
		result.gsm_state = state.state
		if state.state == 'connected' and not result.connected_s then
			result.connected_s = assert(state.event_monotonic_s, 'GSM connected has no producer monotonic timestamp')
			assert(result.connected_s >= result.reappeared_s, 'GSM connected timestamp precedes HAL reappearance')
		end
	end
	if status then
		result.status_version = (result.status_version or 0) + 1
		result.online_device = status.state == 'online' and status.device or nil
		result.online_alias = status.state == 'online' and status.alias or nil
		if result.uplink_lost and result.online_device and result.online_alias
			and result.gsm_state == 'connected' and not result.online_s then
			result.online_s = assert(status.event_monotonic_s, 'NET online has no producer monotonic timestamp')
			assert(result.online_s >= result.connected_s, 'NET online timestamp precedes GSM connected')
			result.device, result.alias = status.device, status.alias
		end
	end
	return not not (state or status)
end

function Timing:complete(imei)
	local result = self.targets[imei].recovery
	return result.online_s and result.gsm_state == 'connected' and result.online_device == result.device
		and result.online_alias == result.alias
end

function Timing:verify_live(box, imei)
	local result = self.targets[imei].recovery
	local mwan, interfaces = net.snapshot(box)
	local live, err = net.online_binding(result.alias, mwan, interfaces)
	if not live then return nil, err end
	assert(live.device == result.device, result.label .. ' changed Linux device after NET reported online')
	return true
end

function Timing:status_version(imei)
	return self.targets[imei].recovery.status_version
end

local function milliseconds(first, last)
	return math.floor((last - first) * 1000 + 0.5)
end

local function within_limit(first, last, limit)
	local elapsed_us = math.floor((last - first) * 1000000 + 0.5)
	return elapsed_us <= limit * 1000000
end

function Timing:verify(imei, modem)
	local result = self.targets[imei].recovery
	assert(self:complete(imei) and modem.state == 'connected', result.label .. ' did not stay connected')
	local matched_device = false
	for _, name in ipairs(modem.net_ports or {}) do if name == result.device then matched_device = true end end
	assert(matched_device, result.label .. ' NET online device does not belong to the recovered ModemManager object')
	result.reappearance_to_connected_ms = milliseconds(result.reappeared_s, result.connected_s)
	result.connected_to_online_ms = milliseconds(result.connected_s, result.online_s)
	result.reappearance_to_online_ms = milliseconds(result.reappeared_s, result.online_s)
	print(('[modem-recovery] %s (%s) reappeared → connected %d ms, connected → online %d ms, total %d ms'):format(
		result.label, result.device, result.reappearance_to_connected_ms, result.connected_to_online_ms,
		result.reappearance_to_online_ms))
	if self.args.max_connected_s then
		result.connected_limit_met = within_limit(result.reappeared_s, result.connected_s, self.args.max_connected_s)
	end
	if self.args.max_online_s then
		result.online_limit_met = within_limit(result.reappeared_s, result.online_s, self.args.max_online_s)
	end
end

function Timing:check_limits()
	local errors = {}
	for _, imei in ipairs(util.keys(self.targets)) do
		local result = self.targets[imei].recovery
		if result.connected_limit_met == false then
			errors[#errors + 1] = result.label .. ' exceeded --max-connected-seconds'
		end
		if result.online_limit_met == false then
			errors[#errors + 1] = result.label .. ' exceeded --max-online-seconds'
		end
	end
	assert(#errors == 0, table.concat(errors, '\n'))
end

return M
