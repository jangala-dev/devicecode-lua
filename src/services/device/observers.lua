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
--       - observer generation stamping for stale-event suppression
--   * providers/* own:
--       - source-specific watching/fetch logic
--       - emission of raw_changed / source_down events as appropriate
--
-- Lifecycle notes:
--   * each observer runs in its own child scope
--   * retirement is explicit: cancel, then join
--   * outer cancellation does not emit source_down; only provider failure does

local fibers = require 'fibers'
local status_watch = require 'services.device.providers.status_watch'

local M = {}

local PROVIDERS = {
	status_watch = status_watch,
}

local function send_required(tx, value, what)
	local ok, reason = tx:send(value)
	if ok ~= true then
		error((what or 'observer_event_send_failed') .. ': ' .. tostring(reason or 'closed'), 0)
	end
end

local function provider_for(rec)
	local name = (type(rec) == 'table'
		and type(rec.provider) == 'string'
		and rec.provider ~= '')
		and rec.provider
		or 'status_watch'

	return PROVIDERS[name], name
end

local function provider_context(conn, name, rec, tx, generation)
	return {
		conn = conn,
		component = name,
		rec = rec,
		generation = generation,

		-- Providers emit raw logical events only.
		-- The boundary layer stamps component/generation so the shell can drop
		-- stale events from retired observers.
		emit = function(ev)
			assert(type(ev) == 'table', 'observer emit expects table event')
			if ev.component == nil then
				ev.component = name
			end
			ev.generation = generation
			send_required(tx, ev, 'observer_event_overflow')
		end,
	}
end

local function run_provider(ctx, provider)
	local st, _report, primary = fibers.run_scope(function()
		return provider.run(ctx)
	end)

	if st == 'failed' then
		ctx.emit({
			tag = 'source_down',
			reason = tostring(primary or 'provider_failed'),
		})
		error(primary or 'provider_failed', 0)
	end

	-- Outer cancellation is lifecycle control, not a source failure.
	-- Retired observers should exit quietly.
	if st == 'cancelled' then
		return
	end
end

-- Returned observer slot:
--   {
--     component = <name>,
--     generation = <observer generation>,
--     scope = <child scope>,
--   }
function M.spawn_component(scope_obj, conn, name, rec, tx, generation)
	local provider, provider_name = provider_for(rec)
	if not provider or type(provider.run) ~= 'function' then
		return nil, 'unknown_provider:' .. tostring(provider_name)
	end

	local child, err = scope_obj:child()
	if not child then
		return nil, err
	end

	local ok, spawn_err = child:spawn(function()
		return run_provider(provider_context(conn, name, rec, tx, generation), provider)
	end)
	if not ok then
		return nil, spawn_err
	end

	return {
		component = name,
		generation = generation,
		scope = child,
	}, nil
end

return M
