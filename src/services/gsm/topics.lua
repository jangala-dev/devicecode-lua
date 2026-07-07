-- services/gsm/topics.lua
--
-- Topic helpers for GSM-owned state and capability surfaces.

local M = {}

local function t(...) return { ... } end

function M.config(name)
	return t('cfg', name or 'gsm')
end

function M.modem_state(name, field)
	return t('state', 'gsm', 'modem', name, field)
end

function M.uplink(name)
	return t('state', 'gsm', 'uplink', name)
end

function M.custom_apns_state()
	return t('state', 'gsm', 'apns', 'custom')
end

function M.apns_status_state()
	return t('state', 'gsm', 'apns', 'status')
end

function M.rpc(method, id)
	return t('cap', 'gsm', id or 'main', 'rpc', method)
end

function M.cap_status(id)
	return t('cap', 'gsm', id or 'main', 'status')
end

function M.cap_meta(id)
	return t('cap', 'gsm', id or 'main', 'meta')
end

function M.apn_methods()
	return {
		'list-custom-apns',
		'replace-custom-apns',
		'add-custom-apn',
		'delete-custom-apn',
	}
end

return M
