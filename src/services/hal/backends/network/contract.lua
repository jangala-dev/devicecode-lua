-- services/hal/backends/network/contract.lua
-- Semantic network backend contract used by the strict HAL network manager.
--
-- Provider operations are Op-first.  The manager is infrastructure and may
-- perform these Ops; service code must never call provider methods directly.

local M = {}

local REQUIRED_OPS = {
	'validate_op',
	'plan_op',
	'apply_op',
	'snapshot_op',
	'watch_op',
	'probe_link_op',
	'read_counters_op',
	'apply_live_weights_op',
	'apply_shaping_op',
	'speedtest_op',
}

function M.validate_provider(provider)
	if type(provider) ~= 'table' then
		return nil, 'network provider must be a table'
	end
	for _, name in ipairs(REQUIRED_OPS) do
		if type(provider[name]) ~= 'function' then
			return nil, 'network provider missing ' .. name
		end
	end
	if type(provider.terminate) ~= 'function' then
		return nil, 'network provider missing terminate'
	end
	return true, nil
end

return M
