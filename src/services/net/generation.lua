-- services/net/generation.lua
-- Generation records for NET config/application lifetimes.

local tablex = require 'shared.table'

local M = {}

local function copy(v) return tablex.deep_copy(v) end

function M.new(id, intent, reason, opts)
	opts = opts or {}
	return {
		generation = id,
		intent = copy(intent),
		reason = reason or 'config_changed',
		state = 'accepted',
		accepted_at = opts.now,
		apply = nil,
		runtime = {},
	}
end

function M.start_apply(gen, apply_id, opts)
	if not gen then return nil, 'generation required' end
	gen.state = 'applying'
	gen.apply = {
		apply_id = apply_id,
		state = 'running',
		started_at = opts and opts.now or nil,
	}
	return gen
end

function M.mark_applied(gen, result, opts)
	if not gen then return nil, 'generation required' end
	gen.state = 'applied'
	gen.apply = gen.apply or {}
	gen.apply.state = 'applied'
	gen.apply.completed_at = opts and opts.now or nil
	gen.apply.result = copy(result)
	return gen
end

function M.mark_failed(gen, reason, result, opts)
	if not gen then return nil, 'generation required' end
	gen.state = 'failed'
	gen.reason = reason or gen.reason
	gen.apply = gen.apply or {}
	gen.apply.state = 'failed'
	gen.apply.completed_at = opts and opts.now or nil
	gen.apply.reason = reason
	gen.apply.result = copy(result)
	return gen
end

function M.snapshot(gen)
	if not gen then return nil end
	return {
		generation = gen.generation,
		reason = gen.reason,
		state = gen.state,
		intent_rev = gen.intent and gen.intent.rev or nil,
		accepted_at = gen.accepted_at,
		apply = copy(gen.apply),
		runtime = copy(gen.runtime),
	}
end

function M.cancel(gen, reason)
	if not gen then return true, nil end
	gen.state = 'cancelled'
	gen.reason = reason or gen.reason
	if gen.apply then gen.apply.state = 'cancelled'; gen.apply.reason = gen.reason end
	if gen.apply_handle and type(gen.apply_handle.cancel) == 'function' then
		return gen.apply_handle:cancel(reason or 'generation_cancelled')
	end
	return true, nil
end

return M
