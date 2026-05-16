-- services/net/backpressure.lua
-- Explicit NET queue/backpressure policy.

local M = {}

M.policy = {
	config = {
		queue_len = 4,
		full = 'reject_newest',
	},

	completions = {
		queue_len = 32,
		full = 'reject_newest',
	},

	observations = {
		queue_len = 64,
		full = 'drop_oldest', -- latest observed state wins; terminal apply completions never use this queue.
	},

	requests = {
		queue_len = 16,
		full = 'reject_newest',
	},
}

return M
