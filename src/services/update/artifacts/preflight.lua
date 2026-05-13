-- services/update/artifacts/preflight.lua
--
-- Scoped artifact preflight around explicit lifetime ownership.

local fibers   = require 'fibers'
local resolver = require 'services.update.artifacts.resolver'
local model    = require 'services.update.model'

local M = {}
local function copy(v) return model.deep_copy(v) end

local function run_check(check, artifact, params)
	if check == nil then return { ok = true }, nil end
	if type(check) ~= 'function' then return nil, 'preflight check must be a function' end
	local result, err = check(artifact, params)
	if result == nil or result == false then return nil, err or 'preflight_failed' end
	return result == true and { ok = true } or result, nil
end

function M.run(scope, params)
	params = params or {}
	local resolved = resolver.resolve_worker(scope, params)
	local check = params.check or params.preflight
	local checked, err = run_check(check, resolved.artifact, params)
	if not checked then error(err or 'preflight_failed', 0) end

	if params.transfer == true then
		local ok, terr = resolved.owned:handoff(function () return true end)
		if ok == nil then error(terr or 'artifact_transfer_failed', 0) end
	end

	return {
		tag = 'artifact_preflighted',
		component = params.component,
		artifact = copy(resolved.artifact),
		preflight = copy(checked),
		transferred = params.transfer == true,
	}
end

return M
