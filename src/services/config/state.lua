-- services/config/state.lua
--
-- State helpers for the config service.

local codec = require 'services.config.codec'

local M = {}

local function copy_record(rec)
	return {
		rev  = rec.rev,
		data = codec.deepcopy_plain(rec.data),
	}
end

function M.publish_all_retained(conn, svc, current)
	local n = 0
	for sname, rec in pairs(current) do
		n = n + 1
		conn:retain({ 'config', sname }, copy_record(rec))
	end
	if svc and svc.obs_event then
		svc:obs_event('publish_all', { services = n })
	end
end

function M.set_service(current, conn, svc, mark_dirty, service, payload, msg)
	if type(service) ~= 'string' or service == '' then
		return nil, 'invalid service'
	end
	if not codec.is_plain_table(payload) or not codec.is_plain_table(payload.data) then
		return nil, 'payload must be { data = table }'
	end

	local settings = payload.data

	if type(settings.schema) ~= 'string' or settings.schema == '' then
		return nil, 'payload.data.schema must be a non-empty string'
	end

	local old = current[service]
	local next_rev = (old and type(old.rev) == 'number') and (math.floor(old.rev) + 1) or 1
	local stored_data = codec.deepcopy_plain(settings)

	current[service] = {
		rev  = next_rev,
		data = stored_data,
	}

	conn:retain({ 'config', service }, {
		rev  = next_rev,
		data = codec.deepcopy_plain(stored_data),
	})

	if svc and svc.obs_event then
		svc:obs_event('set_applied', { service = service, rev = next_rev, id = msg and msg.id or nil })
	end
	if mark_dirty then
		mark_dirty('set ' .. service)
	end

	return true, nil
end

return M
