-- services/update/reconcile.lua
--
-- Small seam around persisted-job normalisation.
--
-- This exists so reconcile/adoption policy has a named module boundary even
-- though the current implementation is intentionally tiny.

local M = {}

function M.normalise_persisted(state, now_mono, service_run_id, model)
	return model.adopt_persisted_jobs(state, now_mono, service_run_id)
end

return M
