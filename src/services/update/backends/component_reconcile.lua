-- services/update/backends/component_reconcile.lua
--
-- Shared retained component-state reconcile helper.

local M = {}

function M.evaluate_component_state(component_state, job, opts)
	opts = opts or {}

	local sw = type(component_state) == 'table' and component_state.software or nil
	local upd = type(component_state) == 'table' and component_state.updater or nil

	local version = type(sw) == 'table' and sw.version or nil
	local build = type(sw) == 'table' and sw.build or nil
	local boot_id = type(sw) == 'table' and sw.boot_id or nil
	local phase = type(upd) == 'table' and upd.state or nil
	local last_error = type(upd) == 'table' and upd.last_error or nil

	if phase == 'failed' or phase == 'rollback_detected' then
		return {
			done = true,
			success = false,
			version = version,
			build = build,
			boot_id = boot_id,
			error = tostring(last_error or phase),
			raw = component_state,
		}
	end

	if job.expected_version and version == job.expected_version then
		local boot_changed = (
			opts.require_boot_change == true
			and job.pre_commit_boot_id ~= nil
			and boot_id ~= nil
			and boot_id ~= job.pre_commit_boot_id
		)
		if boot_changed or phase == nil or phase == 'running' or phase == 'idle' or phase == 'ready' then
			return {
				done = true,
				success = true,
				version = version,
				build = build,
				boot_id = boot_id,
				raw = component_state,
			}
		end
	end

	return {
		done = false,
		version = version,
		build = build,
		boot_id = boot_id,
		raw = component_state,
	}
end

return M
