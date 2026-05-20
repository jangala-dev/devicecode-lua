-- devicecode/support/dependency_slot.lua
--
-- Small owner-side helper for replacing, terminating and projecting a single
-- capability dependency manager field.  It owns boilerplate only; service
-- coordinators still own admission policy.

local cap_deps = require 'devicecode.support.capability_dependencies'

local M = {}

local function field_name(field)
	if type(field) ~= 'string' or field == '' then
		error('dependency_slot: field must be a non-empty string', 3)
	end
	return field
end

function M.terminate(owner, field, reason)
	field = field_name(field)
	local deps = owner and owner[field] or nil
	if deps and type(deps.terminate) == 'function' then
		deps:terminate(reason or (field .. '_closed'))
	end
	if owner then owner[field] = nil end
	return true, nil
end

function M.open(owner, field, conn, specs, opts)
	field = field_name(field)
	M.terminate(owner, field, (opts and opts.replace_reason) or (field .. '_replaced'))
	if not specs or #specs == 0 then return true, nil, nil end
	local deps, err = cap_deps.open(conn, specs, opts or {})
	if not deps then return nil, err end
	owner[field] = deps
	return true, nil, deps
end

function M.replace(owner, field, conn, specs, opts)
	return M.open(owner, field, conn, specs, opts)
end

function M.snapshot(owner, field)
	local deps = owner and owner[field] or nil
	if deps and type(deps.snapshot) == 'function' then return deps:snapshot() end
	return {}
end

function M.event_source(owner, field, opts)
	local deps = owner and owner[field] or nil
	if deps and type(deps.event_source) == 'function' then return deps:event_source(opts or {}) end
	return nil
end

function M.available(owner, field, key)
	local deps = owner and owner[field] or nil
	return deps ~= nil and deps:available(key) == true
end

function M.all_available(owner, field, specs)
	local deps = owner and owner[field] or nil
	if deps == nil then return true end
	for _, spec in ipairs(specs or {}) do
		if deps:available(spec.key) ~= true then return false end
	end
	return true
end

return M
