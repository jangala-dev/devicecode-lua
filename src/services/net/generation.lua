-- services/net/generation.lua
-- Generation record helpers for NET.

local tablex = require 'shared.table'

local M = {}

function M.new(id, intent, reason)
	return {
		generation = id,
		intent = tablex.deep_copy(intent),
		reason = reason or 'config_changed',
		state = 'running',
	}
end

function M.snapshot(gen)
	if not gen then return nil end
	return {
		generation = gen.generation,
		reason = gen.reason,
		state = gen.state,
		intent_rev = gen.intent and gen.intent.rev or nil,
	}
end

function M.cancel(gen, reason)
	if not gen then return true, nil end
	gen.state = 'cancelled'
	gen.reason = reason or gen.reason
	if gen.apply_handle and type(gen.apply_handle.cancel) == 'function' then
		return gen.apply_handle:cancel(reason or 'generation_cancelled')
	end
	return true, nil
end

return M
