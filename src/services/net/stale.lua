-- services/net/stale.lua
-- Uniform stale-completion checks for NET coordinator work.

local M = {}

local function bump(state)
	if state and state.model then
		state.model:update(function (s)
			s.stats = s.stats or {}
			s.stats.stale_completions = (s.stats.stale_completions or 0) + 1
			return s
		end)
	end
end

function M.reject(state, _ev)
	bump(state)
	return true, nil
end

function M.apply_current(state, ev)
	return state.active_apply
		and ev
		and state.active_apply.generation == ev.generation
		and state.active_apply.apply_id == ev.apply_id
end

function M.speedtest_current(state, ev)
	if not state or not ev then return false end
	local rec = state.active_speedtests and state.active_speedtests[ev.uplink_id]
	return rec
		and rec.generation == ev.generation
		and rec.speedtest_id == ev.speedtest_id
end

function M.live_weights_current(state, ev)
	return state.active_weight_apply
		and ev
		and state.active_weight_apply.generation == ev.generation
		and state.active_weight_apply.weight_apply_id == ev.weight_apply_id
end

return M
