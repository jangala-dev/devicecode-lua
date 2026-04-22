-- services/device/observers.lua
--
-- Provider boundary and lifetime management for device observers.
--
-- Provider contract:
--   * a provider module exports `run(ctx)`
--   * provider code emits raw observation events only
--   * provider code does not own its outer scope boundary
--
-- Ownership split:
--   * observers.lua owns:
--       - provider lookup
--       - child scope creation
--       - scoped provider outcome handling
--   * providers/* own:
--       - source-specific watching/fetch logic
--       - emission of raw_changed / source_down events as appropriate

local fibers = require 'fibers'
local status_watch = require 'services.device.providers.status_watch'

local M = {}

local PROVIDERS = {
	status_watch = status_watch,
}

local function provider_for(rec)
	local name = (type(rec) == 'table'
		and type(rec.provider) == 'string'
		and rec.provider ~= '')
		and rec.provider
		or 'status_watch'

	return PROVIDERS[name], name
end

local function provider_context(conn, name, rec, tx)
	return {
		conn = conn,
		component = name,
		rec = rec,
		tx = tx,
		emit = function(ev)
			tx:send(ev)
		end,
	}
end

local function provider_outcome_op(ctx, provider)
	return fibers.run_scope_op(function()
		return provider.run(ctx)
	end):wrap(function(st, _rep, primary)
		return st, primary
	end)
end

local function run_provider(ctx, provider)
	local st, primary = fibers.perform(provider_outcome_op(ctx, provider))

	if st == 'failed' then
		ctx.emit({
			tag = 'source_down',
			component = ctx.component,
			reason = tostring(primary or 'provider_failed'),
		})
		error(primary or 'provider_failed', 0)
	elseif st == 'cancelled' then
		ctx.emit({
			tag = 'source_down',
			component = ctx.component,
			reason = tostring(primary or 'cancelled'),
		})
	end
end

function M.spawn_component(scope_obj, conn, name, rec, tx)
	local provider, provider_name = provider_for(rec)
	if not provider or type(provider.run) ~= 'function' then
		return nil, 'unknown_provider:' .. tostring(provider_name)
	end

	local child, err = scope_obj:child()
	if not child then
		return nil, err
	end

	local ok, spawn_err = child:spawn(function()
		return run_provider(provider_context(conn, name, rec, tx), provider)
	end)
	if not ok then
		return nil, spawn_err
	end

	return child, nil
end

return M
